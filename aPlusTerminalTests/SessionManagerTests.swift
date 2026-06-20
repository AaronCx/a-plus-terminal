import XCTest
import Citadel
import CryptoKit
import NIOCore
import NIOSSH
@testable import aPlusTerminal

final class MultiplexerControllerTests: XCTestCase {
    private let tmux = MultiplexerProfile(
        id: "tmux", displayName: "tmux",
        listSessionsCommand: "tmux list-sessions -F '#S'",
        attachTemplate: "tmux attach -t {target} || tmux new -s {target}",
        currentTargetCommand: "tmux list-sessions -F '#{session_attached} #{session_activity} #{session_name}' | sort -rnk2 | awk '$1>0{print $3; exit}'",
        mouseHintCommand: "tmux set -g mouse on")

    func testAttachCommandTemplatingClearsThenAttaches() {
        // A leading `clear` wipes the login banner/MOTD before the multiplexer
        // redraws (prevents bleed-in), then runs the templated attach.
        XCTAssertEqual(
            MultiplexerController.attachCommand(tmux, target: "main"),
            "clear 2>/dev/null; tmux attach -t main || tmux new -s main\n")
        let zellij = MultiplexerProfile(id: "zellij", displayName: "zellij", attachTemplate: "zellij attach {target}")
        XCTAssertEqual(MultiplexerController.attachCommand(zellij, target: "work"), "clear 2>/dev/null; zellij attach work\n")
    }

    func testNoneProfileHasNoAttach() {
        let none = MultiplexerProfile(id: "none", displayName: "None")
        XCTAssertNil(MultiplexerController.attachCommand(none, target: "x"))
        XCTAssertNil(none.attachCommand(target: "x"))
    }

    func testFirstTargetParsing() {
        XCTAssertNil(MultiplexerController.firstTarget(fromOutput: ""))
        XCTAssertNil(MultiplexerController.firstTarget(fromOutput: "\n   \n"))
        XCTAssertEqual(MultiplexerController.firstTarget(fromOutput: "main\nwork\n"), "main")
        XCTAssertEqual(MultiplexerController.firstTarget(fromOutput: "  spaced  \n"), "spaced")
    }

    func testDiscoveryCommandAugmentsPathForNonLoginExec() {
        // Regression: target discovery runs over a non-interactive SSH exec
        // channel whose PATH omits Homebrew/Nix/per-user bins, so a bare `tmux`
        // is "command not found" → no target → reattach silently falls back to
        // a fresh shell. The discovery command must prepend a PATH covering the
        // usual multiplexer locations and suppress the binary's stderr.
        let c = try! XCTUnwrap(MultiplexerController.discoveryCommand(tmux))
        XCTAssertTrue(c.contains("/opt/homebrew/bin"), "Apple-Silicon Homebrew path must be on PATH")
        XCTAssertTrue(c.contains("/usr/local/bin"), "Intel Homebrew / common path must be on PATH")
        XCTAssertTrue(c.contains("$HOME/bin"), "per-user bin must be on PATH")
        XCTAssertTrue(c.contains("session_attached"), "must run the profile's attached-session selector")
        XCTAssertTrue(c.contains("2>/dev/null"), "must suppress 'no server' stderr so it can't pollute the target")
        XCTAssertTrue(c.contains("|| true"), "must stay exit-0 when no server/session")

        // A profile with no target command discovers nothing.
        let none = MultiplexerProfile(id: "none", displayName: "None")
        XCTAssertNil(MultiplexerController.discoveryCommand(none))
    }

    func testDiscoverySelectsAttachedNotMostRecent() {
        // The tmux selector picks an *attached* session (col1>0), so a detached
        // session spun up later (higher activity) is ignored — the "reattached
        // to session 4 instead of my session 1" fix. Emulate the pipeline:
        //   `awk '$1>0'` (keep attached) → `sort -rnk2` (newest first) → first name.
        struct Row { let attached: Int; let activity: Int; let name: String }
        let rows = [
            Row(attached: 1, activity: 100, name: "work"),     // attached, older
            Row(attached: 0, activity: 200, name: "scratch"),  // detached, newer (the "session 4")
        ]
        let attachedRows = rows.filter { $0.attached > 0 }
        let sorted = attachedRows.sorted { $0.activity > $1.activity }
        XCTAssertEqual(sorted.first?.name, "work",
                       "must pick the attached session, not the newer detached one")
    }
}

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testUserProfilesOverrideBuiltInsByID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let userURL = dir.appendingPathComponent("profiles.json")
        // A user file that overrides claude-code's name and adds a new agent.
        let json = """
        {"agents":[
          {"id":"claude-code","displayName":"My Claude","detectionMarkers":["claude code"],"attachTemplate":"{path} "},
          {"id":"my-bot","displayName":"My Bot","detectionMarkers":["my-bot"],"attachTemplate":"{path} "}
        ],"multiplexers":[]}
        """
        try json.data(using: .utf8)!.write(to: userURL)

        let store = ProfileStore(userFileURL: userURL)
        XCTAssertEqual(store.agent(id: "claude-code")?.displayName, "My Claude", "user entry overrides built-in by id")
        XCTAssertEqual(store.agent(id: "claude-code")?.builtIn, false)
        XCTAssertNotNil(store.agent(id: "my-bot"), "user entry adds a new agent")
        XCTAssertNotNil(store.multiplexer(id: "tmux"), "bundled tmux still present")
    }

    func testAttachTemplatePerAgent() {
        let aider = AgentProfile(id: "aider", displayName: "aider", detectionMarkers: ["aider"], attachTemplate: "/add {path}\n")
        XCTAssertEqual(aider.formatAttachment(path: "/x/y.png"), "/add /x/y.png\n")
        let generic = AgentProfile(id: "generic", displayName: "Agent", detectionMarkers: [], attachTemplate: "{path} ")
        XCTAssertEqual(generic.formatAttachment(path: "/x/y.png"), "/x/y.png ")
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
        outbound.write("aplusterminal-TEST-READY\n")
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
    private var profiles: ProfileStore!
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
        // Deterministic profiles: tmux multiplexer + generic/claude-code agents.
        profiles = ProfileStore(
            agents: [
                AgentProfile(id: "generic", displayName: "Agent", detectionMarkers: [], attachTemplate: "{path} "),
                AgentProfile(id: "claude-code", displayName: "Claude Code", detectionMarkers: ["claude code"], attachTemplate: "{path} ")
            ],
            multiplexers: [
                MultiplexerProfile(id: "tmux", displayName: "tmux",
                                   attachTemplate: "tmux attach -t {target} || tmux new -s {target}",
                                   currentTargetCommand: "tmux list-sessions -F '#{session_attached} #{session_activity} #{session_name}' | sort -rnk2 | awk '$1>0{print $3; exit}'",
                                   mouseHintCommand: "tmux set -g mouse on"),
                MultiplexerProfile(id: "none", displayName: "None (raw shell)")
            ]
        )
        manager = SessionManager(
            keyStore: keyStore,
            serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: profiles
        )

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

    private func makeServer(lastMultiplexerTarget: String? = nil) -> Server {
        var entry = Server(name: "test", host: "127.0.0.1", port: port, username: "aplusterminal-test", keyID: storedKey.id)
        entry.lastMultiplexerTarget = lastMultiplexerTarget
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

    func testShellExitClosesSessionInsteadOfReconnecting() async throws {
        settings.autoReattachMultiplexer = true
        let session = manager.open(server: makeServer(lastMultiplexerTarget: "main"))
        try await waitFor("session to connect") { session.state == .connected }
        // The reconnect contract sends the multiplexer attach on every
        // (re)connect when a target is recorded — including this first connect.
        try await waitFor("attach after connect") { shell.received.contains("tmux attach -t main") }

        // The shell ending cleanly (the user typed `exit`) must close the
        // session — not resurrect it. (Transport errors still reconnect;
        // that path is covered by the suspend/foreground test, since the
        // in-process server can only end channels cleanly.)
        session.sendInput(Data("DROP-CHANNEL\n".utf8))
        try await waitFor("session to close after shell exit", timeout: 15) {
            session.state == .closed && self.manager.sessions.isEmpty
        }
        XCTAssertEqual(
            shell.received.components(separatedBy: "tmux attach -t main").count, 2,
            "no reconnect attach may follow a clean shell exit"
        )
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

    func testForegroundDoesNotAutoReconnectSuspendedSession() async throws {
        // New contract: a session paused in the background is NOT auto-revived
        // on foreground — the user is offered a reattach-vs-fresh choice (the
        // paused card), so it must stay suspended until they pick.
        let session = manager.open(server: makeServer())
        try await waitFor("session to connect") { session.state == .connected }

        await session.suspend()
        XCTAssertEqual(session.state, .suspended)

        manager.appWillEnterForeground()
        // Give any (incorrect) auto-reconnect a chance to fire, then assert it didn't.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(session.state, .suspended, "must wait for the user's reconnect choice")

        // Explicitly choosing reconnect brings it back.
        await session.reconnect(reattachMultiplexer: false, maxAttempts: 1)
        XCTAssertEqual(session.state, .connected)
    }

    func testReconnectFreshShellSkipsReattach() async throws {
        settings.autoReattachMultiplexer = true
        let session = manager.open(server: makeServer(lastMultiplexerTarget: "main"))
        try await waitFor("session to connect") { session.state == .connected }
        try await waitFor("initial attach") { self.shell.received.contains("tmux attach -t main") }
        let attachesBefore = self.shell.received.components(separatedBy: "tmux attach -t main").count

        await session.suspend()
        // "Fresh shell" must reconnect WITHOUT sending another attach.
        await session.reconnect(reattachMultiplexer: false, maxAttempts: 1)
        XCTAssertEqual(session.state, .connected)
        let attachesAfter = self.shell.received.components(separatedBy: "tmux attach -t main").count
        XCTAssertEqual(attachesAfter, attachesBefore, "fresh-shell reconnect must not reattach the multiplexer")
    }

    func testKeepaliveEmitsPeriodicWindowChangesWhileIdle() async throws {
        // The drop-at-~3min regression: with no typing, the keepalive must keep
        // putting real packets on the *live PTY channel* (a no-op window-change)
        // so NAT and the server's ClientAlive timer never fire. Set fast,
        // deterministic timing before the async connect completes.
        let session = manager.open(server: makeServer())
        session.firstKeepaliveDelay = 0.1
        session.keepaliveInterval = 0.2
        try await waitFor("session to connect") { session.state == .connected }

        // Go idle (send nothing) and watch window-change events accumulate at
        // the server purely from the keepalive ping.
        let baseline = shell.windowSizes.count
        try await waitFor("keepalive window-changes to accumulate while idle", timeout: 5) {
            self.shell.windowSizes.count >= baseline + 3
        }
    }

    func testKeepaliveStopsAfterSuspend() async throws {
        let session = manager.open(server: makeServer())
        session.firstKeepaliveDelay = 0.1
        session.keepaliveInterval = 0.2
        try await waitFor("session to connect") { session.state == .connected }
        try await waitFor("at least one keepalive ping") { self.shell.windowSizes.count >= 1 }

        await session.suspend()
        let afterSuspend = shell.windowSizes.count
        // Give the (now-cancelled) keepalive several intervals to prove it is
        // quiescent — a leaked task would keep pinging a dead channel.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(shell.windowSizes.count, afterSuspend, "keepalive must stop once suspended")
    }
}
