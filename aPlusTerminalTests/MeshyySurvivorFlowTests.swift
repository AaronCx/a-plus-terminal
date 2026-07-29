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

    // MARK: - Harness (same probe plumbing as MeshyyResizeAtConnectTests)

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
