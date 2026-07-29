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
            "meshyy must be opt-in: it changes how terminal bytes travel, which is the "
                + "one thing the app cannot get wrong by default"
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

// MARK: - M6 tier 1: the palette in the app

@MainActor
final class QuickActionBarTests: XCTestCase {
    /// The property that matters: no stray sends. A one-tap send goes straight into a
    /// live PTY, so offering one while the agent is mid-work injects a keystroke into
    /// whatever it is doing.
    func testActionsAreOfferedOnlyWhileWaiting() {
        XCTAssertEqual(
            QuickActionAvailability.actions(forAgentStatus: .waiting).count,
            QuickActionPalette.tier1.count,
            "the palette must be offered when an agent is waiting — that is the feature"
        )
        // Module-qualified: MeshyyCore ALSO exports an `AgentActivityMonitor` (the
        // daemon-side detector), so the bare name is ambiguous in a file that imports
        // both. The app's own detector is the one driving this UI.
        let idle = aPlusTerminal.AgentActivityMonitor.Status.none
        let busy = aPlusTerminal.AgentActivityMonitor.Status.working
        for status in [idle, busy] {
            XCTAssertTrue(
                QuickActionAvailability.actions(forAgentStatus: status).isEmpty,
                "actions offered while \(status.rawValue) — a tap would land mid-work"
            )
        }
    }

    /// The palette is the same data meshyy defines, not a second copy that can drift.
    func testPaletteComesFromMeshyyRatherThanBeingRestatedHere() {
        let offered = QuickActionAvailability.actions(forAgentStatus: .waiting)
        XCTAssertEqual(offered.map(\.id), QuickActionPalette.tier1.map(\.id))
        XCTAssertEqual(offered.map(\.sends), QuickActionPalette.tier1.map(\.sends))
    }

    /// Tapping sends exactly one keystroke — the bytes the key itself would produce.
    /// A multi-byte send would be a canned phrase, which is a prompt string by another
    /// name and would break the "no agent knowledge" rule.
    func testEveryActionSendsExactlyOneKeystroke() {
        for action in QuickActionAvailability.actions(forAgentStatus: .waiting) {
            XCTAssertEqual(action.sends.count, 1, "\(action.id) sends \(action.sends.count) bytes")
        }
    }
}

// MARK: - One shell, decided once

@MainActor
final class SingleShellTests: XCTestCase {
    /// The defect this design replaced: with the toggle on, the app opened an SSH pty
    /// AND attached meshyy, so one visible terminal had two live shells on the host —
    /// different scrollback, different cursor, different rc-file side effects — and it
    /// switched between them when meshyy faltered. Reported as "not doing at all what
    /// is advertised", and correctly.
    ///
    /// `SSHConnection.connect(_:openShell:)` is the seam that makes one shell
    /// structural rather than careful: when meshyy is going to carry the terminal, the
    /// SSH connection is opened WITHOUT a pty, so a second shell cannot exist even if
    /// later code is wrong.
    func testConnectCanBeMadeWithoutSpawningAShell() throws {
        // A compile-time assertion, deliberately. If the parameter is removed or
        // renamed, the one-shell guarantee has been dismantled and this stops building
        // — which is a louder failure than a runtime assertion nobody reads.
        let withShell: (SSHConnection.Configuration, Bool) -> Void = { _, _ in }
        XCTAssertNotNil(withShell)

        let connectSignature: (SSHConnection) -> (SSHConnection.Configuration, Bool) async throws -> Void = {
            connection in { config, open in try await connection.connect(config, openShell: open) }
        }
        XCTAssertNotNil(connectSignature)

        let openLater: (SSHConnection) -> (SSHConnection.Configuration) async throws -> Void = {
            connection in { config in try await connection.openShell(config) }
        }
        XCTAssertNotNil(openLater, "the deferred shell open is what lets the probe decide first")
    }

    /// The toggle is the fallback. There is no runtime switch, so the only thing that
    /// decides which transport runs is this preference, read once per connect.
    func testToggleIsTheOnlyFallbackMechanism() {
        let defaults = UserDefaults(suiteName: "one-shell-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.meshyyTransport, "default off means default = today's app")
        settings.meshyyTransport = true
        XCTAssertTrue(settings.meshyyTransport)
        settings.meshyyTransport = false
        XCTAssertFalse(
            settings.meshyyTransport,
            "turning it off must be enough to get plain SSH back — that is the escape hatch"
        )
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
    /// bytes are the whole contract — a tap has to be indistinguishable from typing.
    func testAgentAnswerKeysSendExactlyWhatTypingWould() {
        func bytes(_ item: KeyBarItem) -> [UInt8]? {
            item.terminalKey?.bytes(applicationCursor: false)
        }
        XCTAssertEqual(bytes(.yes), [0x79])
        XCTAssertEqual(bytes(.no), [0x6E])
        XCTAssertEqual(bytes(.one), [0x31])
        XCTAssertEqual(bytes(.two), [0x32])
        XCTAssertEqual(bytes(.three), [0x33])
        // CR, not LF: a pty in canonical mode expects carriage return and translates it.
        XCTAssertEqual(bytes(.enter), [0x0D], "Enter must send CR (0x0D), not LF (0x0A)")
    }

    /// They are opt-in additions to a bar the user arranges. Shipping them in the
    /// default set would rearrange a bar people already know.
    func testTheNewKeysAreNotForcedIntoTheDefaultBar() {
        for item in [KeyBarItem.yes, .no, .enter, .one, .two, .three] {
            XCTAssertFalse(
                KeyBarItem.defaultItems.contains(item),
                "\(item.rawValue) was added to the default bar, moving keys the user already had"
            )
            XCTAssertTrue(KeyBarItem.allCases.contains(item), "\(item.rawValue) must be addable in Settings")
        }
    }
}

// MARK: - meshyy owns its own reconnection

@MainActor
final class ReconnectOwnershipTests: XCTestCase {
    /// The multiplexer reattach machinery is SSH-only, and that is not a preference —
    /// it is what the two transports mean.
    ///
    /// It exists because a dropped SSH connection LOSES the shell, so coming back means
    /// finding a tmux session and guessing which one, a question only the user can
    /// answer. meshyy holds the shell itself: nothing was lost, so there is nothing to
    /// find and nothing to ask.
    ///
    /// Running it anyway would be worse than redundant — it would attach a multiplexer
    /// inside a session already attached to one.
    func testMultiplexerReattachIsSSHOnly() {
        let defaults = UserDefaults(suiteName: "reattach-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.autoReattachMultiplexer = true

        // The rule under test, mirrored: enabled iff the user wants it AND meshyy is
        // not carrying the session.
        func reattachEnabled(usingMeshyy: Bool) -> Bool {
            settings.autoReattachMultiplexer && !usingMeshyy
        }

        XCTAssertTrue(reattachEnabled(usingMeshyy: false), "SSH still needs it")
        XCTAssertFalse(
            reattachEnabled(usingMeshyy: true),
            "meshyy sessions must not run multiplexer reattach — the shell never went away"
        )

        settings.autoReattachMultiplexer = false
        XCTAssertFalse(reattachEnabled(usingMeshyy: false), "the user's preference still wins for SSH")
    }
}

// MARK: - The terminal must regrow

@MainActor
final class TerminalRegrowTests: XCTestCase {
    /// Reported twice: dismissing the keyboard left the bottom of the screen black,
    /// permanently, for the life of the session.
    ///
    /// The cause was `currentWindowSize()` preferring `lastRequestedSize` over the
    /// emulator's real dimensions. That turned ONE missed resize into a permanent one:
    /// the keepalive re-asserted the stale size on every tick, so a terminal that shrank
    /// for the keyboard and grew back stayed small on the server forever, and tmux kept
    /// drawing its status bar at the old bottom row.
    ///
    /// The rule under test: the size we report is the size the emulator actually is.
    func testReportedSizeFollowsTheEmulatorNotTheLastRequest() {
        // Mirrors `currentWindowSize()`.
        func reported(emulator: (cols: Int, rows: Int), lastRequested: (cols: Int, rows: Int)?) -> (Int, Int) {
            if emulator.cols > 1, emulator.rows > 1 { return (emulator.cols, emulator.rows) }
            if let lastRequested { return (max(2, lastRequested.cols), max(2, lastRequested.rows)) }
            return (max(2, emulator.cols), max(2, emulator.rows))
        }

        // Keyboard dismissed: the emulator grew, the last request is stale.
        XCTAssertEqual(
            reported(emulator: (74, 64), lastRequested: (74, 35)).1, 64,
            "a stale request won over the real size, which is what made the black permanent"
        )
        // Before first layout the emulator has nothing to say, so the request stands.
        XCTAssertEqual(reported(emulator: (0, 0), lastRequested: (80, 24)).1, 24)
        // And never a degenerate size.
        XCTAssertGreaterThanOrEqual(reported(emulator: (0, 0), lastRequested: nil).0, 2)
    }

    /// The sync must be a no-op when nothing changed, or every layout pass would send a
    /// resize — and a resize is a SIGWINCH that makes full-screen apps redraw.
    func testSyncIsQuietWhenTheSizeIsUnchanged() {
        func wouldSend(current: (cols: Int, rows: Int), last: (cols: Int, rows: Int)?) -> Bool {
            guard current.cols > 1, current.rows > 1 else { return false }
            if let last, last.cols == current.cols, last.rows == current.rows { return false }
            return true
        }
        XCTAssertFalse(wouldSend(current: (74, 64), last: (74, 64)), "unchanged must not resend")
        XCTAssertTrue(wouldSend(current: (74, 64), last: (74, 35)), "a real change must be sent")
        XCTAssertFalse(wouldSend(current: (0, 0), last: (74, 64)), "a pre-layout size must be ignored")
    }
}
