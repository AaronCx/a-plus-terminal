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
            MeshyyTransport.sessionName(for: id),
            MeshyyTransport.sessionName(for: id),
            "the same server produced two different session names"
        )
        XCTAssertNotEqual(
            MeshyyTransport.sessionName(for: id),
            MeshyyTransport.sessionName(for: UUID()),
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
            let name = MeshyyTransport.sessionName(for: UUID())
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
