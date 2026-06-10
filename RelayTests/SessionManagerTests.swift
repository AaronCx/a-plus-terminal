import XCTest
import Citadel
import CryptoKit
import NIOCore
import NIOSSH
@testable import Relay

final class TmuxIntegrationTests: XCTestCase {
    func testAttachCommandQuotesTarget() {
        XCTAssertEqual(TmuxIntegration.attachCommand(target: "main"), "tmux attach -t 'main'\n")
        XCTAssertEqual(
            TmuxIntegration.attachCommand(target: "it's"),
            "tmux attach -t 'it'\\''s'\n",
            "single quotes must be escaped for the shell"
        )
    }

    func testAttachedSessionParsing() {
        XCTAssertNil(TmuxIntegration.attachedSession(fromList: ""))
        XCTAssertNil(TmuxIntegration.attachedSession(fromList: "main\t0\nwork\t0\n"))
        XCTAssertEqual(TmuxIntegration.attachedSession(fromList: "main\t0\nwork\t1\n"), "work")
        XCTAssertEqual(TmuxIntegration.attachedSession(fromList: "main\t2\n"), "main")
        XCTAssertNil(TmuxIntegration.attachedSession(fromList: "garbage with no tabs"))
    }
}

/// Shell that records everything it receives, so tests can assert on what the
/// app sent after (re)connecting.
final class RecordingShell: ShellDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _received = ""
    private var _windowSizes: [(cols: Int, rows: Int)] = []

    var received: String {
        lock.withLock { _received }
    }

    var windowSizes: [(cols: Int, rows: Int)] {
        lock.withLock { _windowSizes }
    }

    func startShell(
        inbound: AsyncStream<ShellClientEvent>,
        outbound: ShellOutboundWriter,
        context: SSHShellContext
    ) async throws {
        outbound.write("RELAY-TEST-READY\n")
        let windowTask = Task { [lock] in
            for await size in context.windowSize {
                lock.withLock { self._windowSizes.append((size.columns, size.rows)) }
            }
        }
        defer { windowTask.cancel() }
        for await event in inbound {
            if case .stdin(let buffer) = event {
                let text = String(buffer: buffer)
                lock.withLock { _received += text }
                // Simulates the remote end dying mid-session (network drop).
                if text.contains("DROP-CHANNEL") { return }
                outbound.write(ByteBuffer(string: text))
            }
        }
    }
}

@MainActor
final class SessionManagerTests: XCTestCase {
    private var server: SSHServer!
    private var shell: RecordingShell!
    private var hostKey: Curve25519.Signing.PrivateKey!
    private var clientKey: Curve25519.Signing.PrivateKey!
    private var port: Int!

    private var keyStore: KeyStore!
    private var serverStore: ServerStore!
    private var settings: AppSettings!
    private var manager: SessionManager!
    private var storedKey: SSHKey!

    override func setUp() async throws {
        try await super.setUp()
        hostKey = Curve25519.Signing.PrivateKey()
        clientKey = Curve25519.Signing.PrivateKey()
        shell = RecordingShell()
        try await startServer()

        let suffix = UUID().uuidString
        keyStore = KeyStore(
            secrets: InMemorySecretStore(),
            metadataURL: FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(suffix).json")
        )
        serverStore = ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("servers-\(suffix).json")
        )
        let defaults = UserDefaults(suiteName: "SessionManagerTests-\(suffix)")!
        settings = AppSettings(defaults: defaults)
        manager = SessionManager(keyStore: keyStore, serverStore: serverStore, settings: settings)

        // Seed a key whose private bytes are the test client key.
        storedKey = try keyStore.importKey(
            named: "test",
            openSSHPrivateKey: OpenSSHFixture.privateKeyPEM(for: clientKey)
        )
    }

    override func tearDown() async throws {
        manager?.closeAll()
        try? await server?.close()
        try await super.tearDown()
    }

    private func startServer() async throws {
        for attempt in 0..<5 {
            let candidate = port ?? Int.random(in: 30000..<60000)
            do {
                server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: candidate,
                    hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
                    authenticationDelegate: SingleKeyAuthDelegate(
                        allowedKey: NIOSSHPrivateKey(ed25519Key: clientKey).publicKey
                    )
                )
                server.enableShell(withDelegate: shell)
                port = candidate
                return
            } catch {
                port = nil
                if attempt == 4 { throw error }
            }
        }
    }

    private func makeServer(lastTmuxTarget: String? = nil) -> Server {
        var entry = Server(name: "test", host: "127.0.0.1", port: port, username: "relay-test", keyID: storedKey.id)
        entry.lastTmuxTarget = lastTmuxTarget
        serverStore.add(entry)
        return entry
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 15,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(description)")
    }

    func testOpenSessionConnects() async throws {
        let session = manager.open(server: makeServer())
        XCTAssertEqual(manager.sessions.count, 1)
        try await waitFor("session to connect") { session.state == .connected }
        XCTAssertNotNil(session.server.knownHostKey, "host key should be pinned after first connect")
    }

    func testTOFUPinsHostKeyInStore() async throws {
        let entry = makeServer()
        let session = manager.open(server: entry)
        try await waitFor("session to connect") { session.state == .connected }
        let pinned = serverStore.server(for: entry.id)?.knownHostKey
        XCTAssertEqual(pinned, String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: hostKey).publicKey))
    }

    func testCloseAllRemovesSessions() async throws {
        let session = manager.open(server: makeServer())
        try await waitFor("session to connect") { session.state == .connected }
        manager.closeAll()
        XCTAssertTrue(manager.sessions.isEmpty)
        try await waitFor("session to close") { session.state == .closed }
    }

    func testDropReconnectsAndReattachesTmux() async throws {
        settings.autoReattachTmux = true
        let session = manager.open(server: makeServer(lastTmuxTarget: "main"))
        try await waitFor("session to connect") { session.state == .connected }
        // The reconnect contract sends `tmux attach` on every (re)connect
        // when a target is recorded — including this first connect.
        try await waitFor("attach after connect") { shell.received.contains("tmux attach -t 'main'") }

        // Drop the channel mid-session: the session must notice, reconnect on
        // its own, and re-attach tmux (Wi-Fi-loss acceptance test, §4.1).
        session.sendInput(Data("DROP-CHANNEL\n".utf8))
        try await waitFor("session to reconnect without user input", timeout: 30) {
            session.state == .connected && shell.received.components(separatedBy: "tmux attach -t 'main'").count > 2
        }
    }

    func testWindowSizeReplayedAfterConnect() async throws {
        // Regression: a resize that lands before the PTY exists must not be
        // lost — the server otherwise renders at the 80x25 default and the
        // phone shows wrapped/doubled lines.
        let session = manager.open(server: makeServer())
        session.resize(cols: 101, rows: 42)
        try await waitFor("session to connect") { session.state == .connected }
        try await waitFor("window size to reach the shell") {
            self.shell.windowSizes.contains { $0.cols == 101 && $0.rows == 42 }
        }
    }

    func testForegroundReconnectFromSuspended() async throws {
        let session = manager.open(server: makeServer())
        try await waitFor("session to connect") { session.state == .connected }

        await session.suspend()
        XCTAssertEqual(session.state, .suspended)

        manager.appWillEnterForeground()
        try await waitFor("foreground reconnect") { session.state == .connected }
    }
}
