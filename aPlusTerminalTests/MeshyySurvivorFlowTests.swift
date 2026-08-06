import Crypto
import MeshyyCore
import XCTest
@testable import aPlusTerminal

/// Drives the whole survivor-picker flow through a real TerminalSession over real
/// SSH to this Mac: park on the picker, then take each exit.
///
/// The exits are where the bugs live. Closing the tab mid-picker used to be able to
/// resurrect the connect through attemptLoop's retries — a "closed" tab opening a
/// real shell on the server — and the resume path is the feature itself: the one
/// way a surviving session may be entered is the user choosing it.
///
/// Needs a local `meshyyd` and the probe key; skips cleanly without them:
///
///     ./scripts/meshyy-repro-setup.sh && make test-meshyy-live
@MainActor
final class MeshyySurvivorFlowTests: XCTestCase {

    func testClosingTheTabMidPickerLeavesNoStrayShellAndNoZombie() async throws {
        let (session, server) = try makeMeshyySession()
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock { await self.killSessions(withPrefix: prefix) }

        let survivor = try await plantSurvivor(serverID: server.id)

        let connecting = Task { await session.connect() }
        try await poll(deadline: 20, "the connect never parked on the survivor picker") {
            session.meshyySurvivors != nil
        }

        // The user closes the tab while the picker is up.
        await session.close()
        // The parked connect must resolve — CancellationError through attemptLoop —
        // rather than retrying, falling back to an SSH shell, or parking forever.
        await connecting.value

        XCTAssertEqual(session.state, .closed, "close() lost to the connect it aborted")
        XCTAssertNil(session.meshyy, "a closed tab holds no transport")
        XCTAssertNil(session.meshyySurvivors, "the picker outlived its tab")

        // The daemon's view is the one that cannot be argued with: the survivor is
        // untouched, and the aborted connect created NOTHING — no adopted session,
        // no daemon-allocated sibling, no fallback shell's side effects.
        let held = try await liveGroupNames(withPrefix: prefix)
        XCTAssertEqual(held, [survivor],
                       "an aborted connect changed the daemon's table: \(held)")
    }

    func testChoosingResumeEntersExactlyTheChosenSurvivor() async throws {
        let (session, server) = try makeMeshyySession()
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock {
            await session.close()
            await self.killSessions(withPrefix: prefix)
        }

        let survivor = try await plantSurvivor(serverID: server.id)

        let connecting = Task { await session.connect() }
        try await poll(deadline: 20, "the connect never parked on the survivor picker") {
            session.meshyySurvivors != nil
        }
        XCTAssertEqual(session.meshyySurvivors?.map(\.name), [survivor],
                       "the picker must offer exactly the planted survivor")

        session.chooseMeshyySession(.resume(survivor))
        await connecting.value

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.meshyy?.sessionName, survivor,
                       "resume entered a different session than the user chose")
        let held = try await liveGroupNames(withPrefix: prefix)
        XCTAssertEqual(held, [survivor], "resuming must reattach, not mint a sibling")
    }

    func testChoosingNewLeavesTheSurvivorAloneAndMintsAFreshSlot() async throws {
        let (session, server) = try makeMeshyySession()
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock {
            await session.close()
            await self.killSessions(withPrefix: prefix)
        }

        let survivor = try await plantSurvivor(serverID: server.id)

        let connecting = Task { await session.connect() }
        try await poll(deadline: 20, "the connect never parked on the survivor picker") {
            session.meshyySurvivors != nil
        }
        session.chooseMeshyySession(.new)
        await connecting.value

        XCTAssertEqual(session.state, .connected)
        let opened = try XCTUnwrap(session.meshyy?.sessionName)
        XCTAssertNotEqual(opened, survivor, "'New Session' adopted the survivor")
        let held = try await liveGroupNames(withPrefix: prefix)
        XCTAssertEqual(Set(held), Set([survivor, opened]),
                       "expected the survivor plus one fresh session, got \(held)")
    }

    /// THE resume regression: after a clean suspend and reconnect, the terminal
    /// must still paint.
    ///
    /// A detach seals the transport's streams (`.ended` finishes the event pump and
    /// the single-use output stream). Reattaching the SEALED transport succeeded on
    /// the daemon's side — attach accepted, replay sent — while every byte landed in
    /// a stream with no consumer: the tab said connected, keystrokes went out, and
    /// the screen never changed again. The fix rebuilds the transport around the
    /// same session (same consumedOffset, fresh plumbing); this drives the exact
    /// user path — background past the grace window, foreground, reconnect.
    func testOutputStillPaintsAfterSuspendAndReconnect() async throws {
        let (session, server) = try makeMeshyySession()
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock {
            await session.close()
            await self.killSessions(withPrefix: prefix)
        }

        await session.connect()   // fresh group: no survivors, no picker
        guard session.state == .connected, session.meshyy != nil else {
            throw XCTSkip("no local meshyy session: \(session.meshyyUnavailable ?? "not connected")")
        }

        // The pipeline paints before — otherwise the later assertion proves nothing.
        let before = try await ask(session, marker: "PAINT1")
        XCTAssertEqual(before, "ok", "the session never painted at all: harness problem")

        // The app's clean background path, then the paused-card reconnect.
        await session.suspend()
        XCTAssertEqual(session.state, .suspended)
        await session.reconnect(maxAttempts: 1)
        XCTAssertEqual(session.state, .connected, "reconnect failed: \(session.lastError ?? "?")")
        XCTAssertNotNil(session.meshyy, "the reconnect fell back to SSH")

        let after = try await ask(session, marker: "PAINT2")
        XCTAssertEqual(after, "ok",
                       "the reattached session went blind — replay and live output are "
                           + "landing in a sealed stream with no consumer")
    }

    /// THE ASK: with meshyy on, coming back to the app puts you back in your
    /// session — no card, no tap.
    ///
    /// The paused card asks a question that only exists over SSH, where the shell
    /// died with the connection and the user must choose between reattaching a
    /// multiplexer and starting fresh. Under meshyy the daemon held their shell
    /// the whole time, so the question has one answer and asking it is friction.
    func testForegroundAutomaticallyResumesAMeshyySession() async throws {
        let (manager, session, server, _) = try makeManagedMeshyySession()
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock {
            await session.close()
            await self.killSessions(withPrefix: prefix)
        }

        // `manager.open` already started a connect. Calling connect() again here
        // ran a SECOND one concurrently and the daemon allocated two sessions —
        // a harness bug that reads exactly like the wormhole this suite exists to
        // guard against. Wait for the manager's own connect instead.
        try await poll(deadline: 25, "the manager's connect never completed") {
            session.state == .connected
        }
        guard session.usesMeshyy else {
            throw XCTSkip("no local meshyy session: \(session.meshyyUnavailable ?? "not connected")")
        }
        let name = try XCTUnwrap(session.meshyy?.sessionName)

        // The app goes to the background long enough for iOS to freeze it.
        await session.suspend()
        XCTAssertEqual(session.state, .suspended)

        manager.appWillEnterForeground()

        try await poll(deadline: 25, "foregrounding never brought the session back") {
            session.state == .connected
        }
        XCTAssertEqual(session.meshyy?.sessionName, name,
                       "resumed a different session than the one the user was in")
        let held = try await liveGroupNames(withPrefix: prefix)
        XCTAssertEqual(held, [name],
                       "resuming minted an extra session instead of returning to the old one: \(held)")
    }

    /// And after a RELAUNCH, where the tab itself is gone: the server remembers
    /// which session was its terminal, so a single survivor that matches goes
    /// straight back rather than through the picker.
    func testARelaunchReturnsToTheRememberedSessionWithoutAsking() async throws {
        let (_, first, server, store) = try makeManagedMeshyySession()
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock { await self.killSessions(withPrefix: prefix) }

        try await poll(deadline: 25, "the manager's connect never completed") {
            first.state == .connected
        }
        guard first.usesMeshyy else {
            throw XCTSkip("no local meshyy session: \(first.meshyyUnavailable ?? "not connected")")
        }
        let name = try XCTUnwrap(first.meshyy?.sessionName)
        await first.suspend()          // app is force-quit: detached, nothing local left

        // Wait for the daemon to report it detached, or the next connect would
        // (correctly) treat it as someone else's live screen. `poll` takes a
        // synchronous predicate, so the async lookup happens here.
        var detached = false
        let detachBy = Date().addingTimeInterval(15)
        while Date() < detachBy, !detached {
            let ssh = try await connectSSH()
            if case .success(let rows) = await MeshyyTransport.listGroup(
                over: ssh, serverID: server.id
            ) {
                detached = rows.contains { $0.name == name && $0.isResumable }
            }
            await ssh.disconnect()
            if !detached { try await Task.sleep(for: .milliseconds(300)) }
        }
        XCTAssertTrue(detached, "the daemon never reported the session detached")

        // A fresh launch: a new session object on the SAME stored server.
        let (_, second, _, _) = try makeManagedMeshyySession(
            reusing: (store: store, id: server.id))
        addTeardownBlock { await second.close() }
        var settled = false
        let by = Date().addingTimeInterval(25)
        while Date() < by, !settled {
            settled = second.state == .connected || second.meshyySurvivors != nil
            if !settled { try await Task.sleep(for: .milliseconds(200)) }
        }
        XCTAssertTrue(settled, """
            the relaunched session never connected — state=\(second.state), \
            meshyy=\(second.meshyy?.sessionName ?? "nil"), \
            unavailable=\(second.meshyyUnavailable ?? "nil"), \
            error=\(second.lastError ?? "nil"), \
            remembered=\(second.server.lastMeshyySession ?? "nil")
            """)
        guard settled else { return }

        if let offered = second.meshyySurvivors {
            second.chooseMeshyySession(.new)   // unpark, or the suite hangs here
            XCTFail("""
                the picker appeared for a session the server already remembered \
                (offered \(offered.map(\.name)), remembered \(name))
                """)
        }
        XCTAssertEqual(second.meshyy?.sessionName, name,
                       "a relaunch did not return to the remembered session")
    }

    // MARK: - Harness (same probe plumbing as MeshyyResizeAtConnectTests)

    /// Runs a marker print in the session's shell and reads it back off the
    /// rendered grid — the byte path the user actually sees. The marker is
    /// assembled by printf so the echoed command cannot satisfy the scan.
    private func ask(_ session: TerminalSession, marker: String) async throws -> String {
        let head = String(marker.prefix(3)), tail = String(marker.dropFirst(3))
        session.sendInput(Data("printf '%s%s:ok\\n' '\(head)' '\(tail)'\n".utf8))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let value = Self.value(after: marker + ":", in: session.terminalView) {
                return value
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        return ""
    }

    /// Scans the rendered grid for `prefix` and returns the rest of that row.
    private static func value(after prefix: String, in view: TerminalEmulatorView) -> String? {
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            var text = ""
            for column in 0..<terminal.cols { text.append(line[column].getCharacter()) }
            text = text.replacingOccurrences(of: "\0", with: " ")
            guard let range = text.range(of: prefix) else { continue }
            let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func poll(
        deadline seconds: TimeInterval, _ message: String,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(message)
        throw XCTSkip("harness condition never held: \(message)")
    }

    /// A detached session on the daemon for this server — what a force-quit leaves.
    ///
    /// Waits until the daemon actually REPORTS it detached: the count is the
    /// daemon's reaction to the transport teardown and lands a beat after the
    /// client's detach returns. A connect racing that beat sees attachedClients=1,
    /// filters the survivor out, and never parks — which is the app behaving
    /// correctly against a fresh count, and the test asking its question too soon.
    /// (A real user reconnects seconds later, not milliseconds.)
    private func plantSurvivor(serverID: UUID) async throws -> String {
        let ssh = try await connectSSH()
        defer { Task { await ssh.disconnect() } }
        let result = await MeshyyTransport.bootstrapNew(
            over: ssh, serverID: serverID, sshHost: "127.0.0.1", cols: 80, rows: 40
        )
        let name: String
        switch result {
        case .success(let transport):
            name = transport.sessionName
            await transport.detach()
        case .failure(.daemonAbsent):
            throw XCTSkip("no meshyyd on this Mac — run ./scripts/meshyy-repro-setup.sh")
        case .failure(let reason):
            throw XCTSkip("meshyy bootstrap failed: \(reason.errorDescription ?? "?")")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .success(let rows) = await MeshyyTransport.listGroup(
                over: ssh, serverID: serverID
            ), rows.contains(where: { $0.name == name && $0.isResumable }) {
                return name
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw XCTSkip("the daemon never reported the planted survivor as detached")
    }

    private func liveGroupNames(withPrefix prefix: String) async throws -> [String] {
        let ssh = try await connectSSH()
        defer { Task { await ssh.disconnect() } }
        let output = (try? await ssh.runCommand(MeshyyTransport.listCommand())) ?? ""
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = envelope["sessions"] as? [[String: Any]]
            else { continue }
            return rows.compactMap { $0["name"] as? String }
                .filter { $0.hasPrefix(prefix) }
                .sorted()
        }
        return []
    }

    private func killSessions(withPrefix prefix: String) async {
        guard let names = try? await liveGroupNames(withPrefix: prefix),
              let ssh = try? await connectSSH() else { return }
        for name in names {
            _ = try? await ssh.runCommand(MeshyyTransport.daemonCommand("kill \(name)"))
        }
        await ssh.disconnect()
    }

    private func connectSSH() async throws -> SSHConnection {
        let connection = SSHConnection()
        var config = SSHConnection.Configuration(
            host: "127.0.0.1", port: 22, username: Self.probeUser,
            auth: try probeAuth(), cols: 80, rows: 24
        )
        config.connectTimeout = 10
        try await connection.connect(config, openShell: false)
        return connection
    }

    private func probeAuth() throws -> SSHConnection.AuthMethod {
        guard let encoded = try? String(
                contentsOfFile: "/tmp/aplus-probe-seed.b64", encoding: .utf8),
              let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else {
            throw XCTSkip("no probe key — run ./scripts/meshyy-repro-setup.sh")
        }
        return .key(.ed25519(key))
    }

    private static var probeUser: String {
        (try? String(contentsOfFile: "/tmp/aplus-probe-user.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? NSUserName()
    }

    /// The same probe session, but owned by a real `SessionManager` — needed for
    /// anything that goes through the app-lifecycle path rather than the session
    /// alone. `reusing` models a relaunch: same stored server, new session object.
    private func makeManagedMeshyySession(
        reusing existing: (store: ServerStore, id: UUID)? = nil
    ) throws -> (SessionManager, TerminalSession, Server, ServerStore) {
        let pem = try probeKeyPEM()
        let suffix = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory

        let keyStore = KeyStore(
            secrets: InMemorySecretStore(),
            metadataURL: temporary.appendingPathComponent("mk-\(suffix).json")
        )
        let key = try keyStore.importKey(named: "probe", openSSHPrivateKey: pem)
        // A relaunch must read the SAME store the previous run wrote to, or the
        // remembered session name is not actually being tested — the first version
        // of this harness built a fresh store per call and the "relaunch" parked on
        // a picker forever, which is a harness bug that reads exactly like a
        // product one.
        let serverStore: ServerStore
        var entry: Server
        if let existing {
            serverStore = existing.store
            guard var stored = serverStore.servers.first(where: { $0.id == existing.id }) else {
                throw XCTSkip("the stored server vanished between launches")
            }
            // A relaunch gets a fresh in-memory keychain, so the stored key id
            // points at a key this process does not have — re-point it at the one
            // just imported. Everything else about the stored server, including
            // the remembered meshyy session under test, is left exactly as the
            // previous launch wrote it.
            stored.keyID = key.id
            serverStore.update(stored)
            entry = stored
        } else {
            serverStore = ServerStore(
                fileURL: temporary.appendingPathComponent("ms-\(suffix).json")
            )
            entry = Server(name: "probe", host: "127.0.0.1", username: Self.probeUser)
            entry.keyID = key.id
            serverStore.add(entry)
        }

        let settings = AppSettings(defaults: UserDefaults(suiteName: "MeshyyManaged-\(suffix)")!)
        settings.meshyyTransport = true

        let manager = SessionManager(
            keyStore: keyStore, serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: ProfileStore(
                agents: [],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
        let session = manager.open(server: entry)
        session.terminalView.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        session.terminalView.layoutIfNeeded()
        return (manager, session, entry, serverStore)
    }

    private func probeKeyPEM() throws -> String {
        guard let pem = try? String(contentsOfFile: "/tmp/aplus-probe-key.pem", encoding: .utf8),
              pem.contains("PRIVATE KEY")
        else {
            throw XCTSkip("no probe key PEM — run ./scripts/meshyy-repro-setup.sh")
        }
        return pem
    }

    private func makeMeshyySession() throws -> (TerminalSession, Server) {
        guard let pem = try? String(contentsOfFile: "/tmp/aplus-probe-key.pem", encoding: .utf8),
              pem.contains("PRIVATE KEY")
        else {
            throw XCTSkip("no probe key PEM — run ./scripts/meshyy-repro-setup.sh")
        }
        let suffix = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory

        let keyStore = KeyStore(
            secrets: InMemorySecretStore(),
            metadataURL: temporary.appendingPathComponent("keys-\(suffix).json")
        )
        let key = try keyStore.importKey(named: "probe", openSSHPrivateKey: pem)

        let serverStore = ServerStore(
            fileURL: temporary.appendingPathComponent("servers-\(suffix).json")
        )
        var entry = Server(name: "probe", host: "127.0.0.1", username: Self.probeUser)
        entry.keyID = key.id
        serverStore.add(entry)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "MeshyySurvivorFlow-\(suffix)")!)
        settings.meshyyTransport = true

        let session = TerminalSession(
            server: entry,
            keyStore: keyStore,
            serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: ProfileStore(
                agents: [],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
        // See MeshyyResizeAtConnectTests: an unlaid-out terminal is a 2x1 grid.
        session.terminalView.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        session.terminalView.layoutIfNeeded()
        return (session, entry)
    }
}
