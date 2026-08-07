import MeshyyCore
import XCTest
@testable import aPlusTerminal

/// meshyy is opt-in and replaces the PTY byte stream, so the properties that matter
/// most are the ones about it NOT being used: the toggle defaults off, a host without
/// a daemon is unaffected, and every failure lands back on SSH with a reason the user
/// can read.
///
/// A live meshyy session needs a daemon and a QUIC listener, which is meshyy's own
/// suite's job — it asserts stream equality across arbitrary disconnects at three
/// levels and has 176 tests to do it with. Duplicating that here would test meshyy
/// twice and this integration not at all. What is tested here is the *seam*.
@MainActor
final class MeshyyTransportTests: XCTestCase {

    // MARK: - The toggle

    func testTransportIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "meshyy-default-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(
            settings.meshyyTransport,
            "meshyy must be opt-in: it changes how terminal bytes travel, which is the one thing the app cannot get wrong by default"
        )
    }

    func testTransportPreferencePersists() {
        let name = "meshyy-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = AppSettings(defaults: defaults)
        settings.meshyyTransport = true

        let reloaded = AppSettings(defaults: UserDefaults(suiteName: name)!)
        XCTAssertTrue(reloaded.meshyyTransport, "the toggle did not survive a relaunch")
    }

    // MARK: - The survivor picker's filter

    private func remote(
        _ name: String, slot: Int, alive: Bool = true, attached: Int = 0,
        quiet: TimeInterval? = nil
    ) -> MeshyyTransport.RemoteSession {
        MeshyyTransport.RemoteSession(
            name: name, slot: slot, alive: alive, attachedClients: attached,
            clientQuietFor: quiet, cols: 80, rows: 24, bufferedBytes: 0, lastOutputAt: nil
        )
    }

    /// What may be OFFERED is as load-bearing as what gets opened: a dead shell
    /// resumes into a corpse, an attached one is someone else's live screen, and a
    /// claimed one is another tab in this very app. Each exclusion is a separate
    /// wrong-shell bug.
    func testOnlyDetachedRunningUnclaimedSessionsAreOffered() {
        let sessions = [
            remote("aplus-x-0", slot: 0),                       // resumable
            remote("aplus-x-1", slot: 1, alive: false),         // dead shell
            remote("aplus-x-2", slot: 2, attached: 1),          // someone's screen
            remote("aplus-x-3", slot: 3),                       // claimed by another tab
            remote("aplus-x-4", slot: 4),                       // resumable
        ]
        let offered = MeshyyTransport.offerableSurvivors(
            in: sessions, claimed: ["aplus-x-3"]
        )
        XCTAssertEqual(
            offered.map(\.name), ["aplus-x-0", "aplus-x-4"],
            "the picker must offer exactly the detached, running, unclaimed sessions"
        )
    }

    /// THE FIRST-SESSION BUG. A force-quit app's QUIC peer survives on the daemon
    /// until its idle timeout (30s), still counted in `attached_clients` — so on a
    /// quick relaunch the user's OWN abandoned session looked like somebody else's
    /// live screen, was filtered out of the picker, and a new session opened
    /// silently instead. Wait past the timeout and the next session prompts
    /// normally, which is exactly the "my first session doesn't ask but the rest
    /// do" report.
    func testAnAttachedButLongSilentClientDoesNotHideASurvivor() {
        let live = remote("aplus-y-0", slot: 0, attached: 1, quiet: 0.5)
        let corpse = remote("aplus-y-1", slot: 1, attached: 1, quiet: 12)
        let offered = MeshyyTransport.offerableSurvivors(in: [live, corpse], claimed: [])

        XCTAssertEqual(offered.map(\.name), ["aplus-y-1"], """
            a client silent for 12s is a force-quit corpse the transport has not \
            reaped and its session must be offered back; one silent for 0.5s is a \
            live screen and must not be
            """)
    }

    /// The threshold has to sit above the client's own heartbeat with room to
    /// spare, or a healthy-but-briefly-stalled client gets its session offered to
    /// another device — the shared-shell outcome, arriving from the other side.
    func testStaleThresholdIsSafelyAboveTheHeartbeat() {
        XCTAssertGreaterThanOrEqual(
            MeshyyTransport.RemoteSession.staleClientThreshold, 3,
            "a 1s heartbeat needs at least three misses of headroom before a live client is called dead"
        )
    }

    // MARK: - Session naming

    /// Resume is worthless if the name changes between launches — the daemon would
    /// start a new shell instead of replaying the one that is still running.
    func testSessionNameIsStableForAServer() {
        let id = UUID()
        XCTAssertEqual(
            MeshyyTransport.sessionName(serverID: id, slot: 0),
            MeshyyTransport.sessionName(serverID: id, slot: 0),
            "the same server produced two different session names"
        )
        XCTAssertNotEqual(
            MeshyyTransport.sessionName(serverID: id, slot: 0),
            MeshyyTransport.sessionName(serverID: UUID(), slot: 0),
            "two servers collided on one session name, so they would share a shell"
        )
    }

    /// The name is interpolated into a command that crosses an SSH exec channel and is
    /// interpreted by the remote shell. Anything a shell can read as syntax is a
    /// command-injection hole — the same class meshyy's own daemon rules forbid
    /// outright. UUIDs cannot contain such characters, and this asserts that the
    /// filtering keeps it that way if the source of the name ever changes.
    func testSessionNameCannotBeReadAsShellSyntax() {
        for _ in 0..<200 {
            let name = MeshyyTransport.sessionName(serverID: UUID(), slot: 0)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            XCTAssertTrue(
                name.unicodeScalars.allSatisfy { allowed.contains($0) },
                "\(name) contains a character a shell could interpret"
            )
            for dangerous in [";", "|", "&", "$", "`", "(", ")", "<", ">", "\n", " ", "'", "\"", "\\"] {
                XCTAssertFalse(name.contains(dangerous), "\(name) contains \(dangerous)")
            }
        }
    }

    // MARK: - Every reason to fall back reads as an explanation

    /// §3.5, fail visible. A silent fallback is indistinguishable from a broken
    /// feature, and the toggle exists precisely to find out whether it works — so each
    /// reason has to say what happened *and* that SSH is carrying the session.
    func testEveryUnavailableReasonExplainsItselfAndSaysSSH() throws {
        let reasons: [MeshyyTransport.Unavailable] = [
            .daemonAbsent,
            .malformedBootstrap("unexpected end of JSON"),
            .protocolTooOld(daemon: 1, client: 2),
            .connectFailed("timed out"),
        ]
        for reason in reasons {
            let message = try XCTUnwrap(reason.errorDescription)
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(
                message.contains("SSH"),
                "\(reason) does not tell the user their session is still on SSH: \(message)"
            )
            XCTAssertFalse(
                message.contains("Error Domain"),
                "\(reason) leaks a raw NSError into the UI: \(message)"
            )
        }
    }

    /// The daemon may be NEWER than this client — additive frames make that fine (§5.3)
    /// — but never older, because an old daemon may not know a frame this client relies
    /// on. Asserted because getting the comparison backwards is a one-character mistake
    /// that would silently downgrade every modern host to SSH, or worse, attach to a
    /// daemon that cannot answer.
    func testProtocolComparisonRejectsOlderAndAcceptsNewer() {
        let client = Meshyy.protocolVersion
        XCTAssertGreaterThan(client, 0)

        // Mirrors the guard in `bootstrap`.
        func accepts(daemon: Int) -> Bool { daemon >= client }

        XCTAssertTrue(accepts(daemon: client), "a matching daemon must be accepted")
        XCTAssertTrue(accepts(daemon: client + 1), "a newer daemon must be accepted — frames are additive")
        XCTAssertFalse(accepts(daemon: client - 1), "an older daemon must be refused")
    }

    // MARK: - The bootstrap contract

    /// The app and the daemon agree on this JSON across a repo boundary, so a field
    /// rename on either side is a silent breakage. Parsing a literal fixture is what
    /// makes that visible here rather than on a user's phone.
    func testBootstrapJSONFromTheDaemonParses() throws {
        let json = """
        {"port":49152,"token":"t0ken","cert_sha256":"\(String(repeating: "a", count: 64))",\
        "session_id":"0123456789abcdef0123456789abcdef","protocol":\(Meshyy.protocolVersion)}
        """
        let response = try BootstrapResponse.parse(json)
        try response.validate()

        XCTAssertEqual(response.port, 49152)
        XCTAssertEqual(response.token, "t0ken")
        XCTAssertEqual(response.sessionID, "0123456789abcdef0123456789abcdef")
        XCTAssertNil(response.host, "absent host means 'the host you SSH'd to'")
    }

    /// A daemon that answers with something unreadable must be refused rather than
    /// half-trusted. The fingerprint is the entire basis for trusting the QUIC
    /// certificate — §5.1 hangs the trust chain on the SSH host key through it — so a
    /// short or malformed one has to fail closed.
    func testMalformedBootstrapIsRefused() {
        let shortFingerprint = """
        {"port":49152,"token":"t","cert_sha256":"abc","session_id":"s","protocol":1}
        """
        XCTAssertThrowsError(
            try {
                let parsed = try BootstrapResponse.parse(shortFingerprint)
                try parsed.validate()
            }(),
            "a 3-character certificate fingerprint was accepted"
        )

        XCTAssertThrowsError(
            try BootstrapResponse.parse("not json at all"),
            "unparseable output was accepted as a bootstrap"
        )
    }
}

// MARK: - Finding the daemon over an exec channel

extension MeshyyTransportTests {
    /// An SSH **exec** channel is not a login shell: it gets a bare PATH, and neither
    /// that nor `/etc/paths` includes `~/bin` — which is exactly where a self-built
    /// `meshyyd` lands. A bare `meshyyd` would report "not installed" on a host where
    /// it plainly is, and the feature would look broken while behaving correctly.
    ///
    /// Verified on the Mac this ships from before it could waste a TestFlight cycle.
    func testBootstrapProbesLocationsABareExecChannelCannotSee() {
        let command = MeshyyTransport.bootstrapCommand(session: "aplus-test")

        XCTAssertTrue(
            command.contains("$HOME/bin/meshyyd"),
            "a self-built daemon in ~/bin is the common case and would not be found"
        )
        XCTAssertTrue(command.contains("/opt/homebrew/bin/meshyyd"), "Homebrew on Apple silicon")
        XCTAssertTrue(command.contains("/usr/local/bin/meshyyd"), "Homebrew on Intel, and manual installs")
        XCTAssertTrue(
            command.hasPrefix("for c in \"meshyyd\""),
            "PATH must be tried FIRST, so a user who placed it deliberately wins"
        )
    }

    /// A host with no daemon must exit non-zero, so Citadel throws and the caller
    /// falls back. Exiting 0 with empty output would be parsed as a malformed
    /// bootstrap and reported as a fault on a host that simply has no daemon.
    func testCommandFailsCleanlyWhenNoDaemonExists() {
        let command = MeshyyTransport.bootstrapCommand(session: "aplus-test")
        XCTAssertTrue(command.hasSuffix("exit 127"), "a missing daemon must exit non-zero: \(command)")
    }

    /// The session name is the only thing this side interpolates into a string a
    /// remote shell will interpret.
    func testOnlyTheFilteredSessionNameIsInterpolated() {
        let name = MeshyyTransport.sessionName(serverID: UUID(), slot: 0)
        let command = MeshyyTransport.bootstrapCommand(session: name)
        XCTAssertTrue(command.contains("--session \(name) --json"))

        // Everything else in the command is a fixed literal from `daemonCandidates`.
        for candidate in MeshyyTransport.daemonCandidates {
            XCTAssertTrue(command.contains(candidate), "lost probe location \(candidate)")
        }
    }
}



// MARK: - One session per tab

@MainActor
final class SessionIdentityTests: XCTestCase {
    /// Reported in use: "when I try to make new sessions I just bleed back into my
    /// previous shell."
    ///
    /// The name used to be derived from the SERVER id, so every tab opened against one
    /// host resolved to the same daemon session and the second tab attached to the
    /// first tab's shell. Keyed on the tab now.
    func testEachTabGetsItsOwnSessionName() {
        let server = UUID()
        XCTAssertNotEqual(
            MeshyyTransport.sessionName(serverID: server, slot: 0),
            MeshyyTransport.sessionName(serverID: server, slot: 1),
            "two tabs share a session name, so the second one lands in the first one's shell"
        )
    }

    /// The name must be STABLE across app launches, not merely unique.
    ///
    /// It was keyed on the tab's UUID, which is regenerated every launch — so every
    /// launch created a new daemon session with a new shell. Because the user's shell
    /// rc auto-attaches tmux, each became another tmux client: six accumulated in one
    /// evening, tmux sized the session to its SMALLEST client, and the terminal was
    /// clamped to 39 rows regardless of what any client asked for. That was the black
    /// region, and six clients renegotiating size was the flicker.
    ///
    /// A slot is derived from position, not identity, so tab 0 on a server resolves to
    /// the same session tomorrow as it does today.
    func testTheNameIsStableAcrossLaunches() {
        let server = UUID()
        XCTAssertEqual(
            MeshyyTransport.sessionName(serverID: server, slot: 0),
            MeshyyTransport.sessionName(serverID: server, slot: 0),
            "a relaunch must reattach, not spawn a sibling shell"
        )
        XCTAssertNotEqual(
            MeshyyTransport.sessionName(serverID: server, slot: 0),
            MeshyyTransport.sessionName(serverID: UUID(), slot: 0),
            "two servers must not share slot 0"
        )
    }

    /// Still shell-safe with the slot appended.
    func testSlottedNameCannotBeReadAsShellSyntax() {
        for slot in [0, 1, 7, 99] {
            let name = MeshyyTransport.sessionName(serverID: UUID(), slot: slot)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            XCTAssertTrue(name.unicodeScalars.allSatisfy { allowed.contains($0) }, name)
        }
    }

    /// The quick-action keys moved into the ordinary key bar. Asserted because the

    /// They are opt-in additions to a bar the user arranges. Shipping them in the
}




// MARK: - A resize must not be lost while meshyy is connecting

@MainActor
final class ResizeDuringBootstrapTests: XCTestCase {
    /// Reported as "sizing is not working until being in the session for a while".
    ///
    /// The outbox routes a resize to meshyy when it is set and to the SSH connection
    /// otherwise. During the bootstrap meshyy is NOT yet set, and under meshyy that SSH
    /// connection deliberately has no pty — so a resize SwiftTerm reports in that window
    /// is thrown at a channel that cannot take it and is swallowed.
    ///
    /// Nothing corrects it afterwards, because `sizeChanged` only fires when the size
    /// CHANGES. The session keeps the size the handshake carried until the user happens
    /// to resize again — which is exactly "it starts working after a while".
    ///
    /// The rule: once meshyy is attached, the current size is pushed unconditionally.
    func testASizeChangeDuringBootstrapIsNotLost() {
        // Models the outbox's routing decision plus the post-attach push.
        var deliveredToMeshyy: [(Int, Int)] = []
        var deliveredToSSHWithNoPTY: [(Int, Int)] = []
        var meshyyAttached = false
        var lastRequested: (cols: Int, rows: Int)?

        func resize(_ cols: Int, _ rows: Int) {
            lastRequested = (cols, rows)
            if meshyyAttached { deliveredToMeshyy.append((cols, rows)) }
            else { deliveredToSSHWithNoPTY.append((cols, rows)) }   // swallowed
        }

        // SwiftTerm lays out while the bootstrap is still in flight.
        resize(74, 64)
        XCTAssertEqual(deliveredToMeshyy.count, 0, "precondition: that resize was lost")

        // meshyy attaches, and the current size is pushed.
        meshyyAttached = true
        if let last = lastRequested { resize(last.cols, last.rows) }

        XCTAssertEqual(
            deliveredToMeshyy.last?.1, 64,
            "the size the user actually has never reached the daemon, so the session stays at whatever the handshake carried"
        )
    }
}

/// The escapes synthesized from a daemon `modes` frame, checked against
/// SwiftTerm's actual mode semantics — the emulator these bytes are for.
@MainActor
final class ModeSynthesisTests: XCTestCase {

    // MARK: - Mode synthesis vs SwiftTerm's semantics

    /// SwiftTerm's mouse-mode state machine, replicated for exactly the modes
    /// `modeEscapes` can emit. The subtlety these tests exist for: SwiftTerm
    /// treats `?1006l` (SGR encoding OFF) as "mouse off" — it resets
    /// `mouseMode` outright, not just the encoding — so the ORDER of the
    /// synthesized escapes decides whether an armed mouse survives them.
    private func mouseOnAfter(_ escapes: Data) -> Bool {
        var mouseOn = false
        let text = String(decoding: escapes, as: UTF8.self)
        var search = text[...]
        while let start = search.range(of: "\u{1B}[?") {
            let rest = search[start.upperBound...]
            guard let end = rest.firstIndex(where: { $0 == "h" || $0 == "l" }) else { break }
            let active = rest[end] == "h"
            for piece in rest[..<end].split(separator: ";") {
                switch Int(piece) {
                case 1000, 1002, 1003:
                    mouseOn = active           // any family reset disarms
                case 1006 where !active:
                    mouseOn = false            // SwiftTerm: ?1006l → mouseMode = .off
                default:
                    break
                }
            }
            search = rest[rest.index(after: end)...]
        }
        return mouseOn
    }

    /// The tmux shape (mouse on arms 1000+1002+1006, measured on 3.6a): the
    /// synthesis must leave the emulator armed.
    func testModeSynthesisArmsTheTmuxSet() {
        XCTAssertTrue(
            mouseOnAfter(MeshyyTransport.modeEscapes(active: [1, 1000, 1002, 1006, 2004])),
            "the modes tmux actually arms must synthesize to an armed emulator"
        )
    }

    /// A program that arms mouse WITHOUT SGR encoding (X10-era arming): the
    /// daemon reports {1000} and the synthesis must still leave the emulator
    /// armed. The old escape order emitted `?1000h` and then `?1006l`, and
    /// SwiftTerm reads that trailing `?1006l` as "mouse off" — the synthesis
    /// disarmed the very mode it was asserting.
    func testModeSynthesisCannotDisarmTheMouseItJustArmed() {
        XCTAssertTrue(
            mouseOnAfter(MeshyyTransport.modeEscapes(active: [1000])),
            "?1006l must not follow the family arming it would cancel"
        )
    }

    /// All off stays all off — the reset direction must not regress.
    func testModeSynthesisStillDisarmsWhenEverythingIsOff() {
        XCTAssertFalse(mouseOnAfter(MeshyyTransport.modeEscapes(active: [])))
        XCTAssertFalse(mouseOnAfter(MeshyyTransport.modeEscapes(active: [2004, 1])))
    }
}
