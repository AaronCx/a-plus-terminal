import Crypto
import MeshyyCore
import XCTest
@testable import aPlusTerminal

/// Drives the app's REAL meshyy path over a REAL SSH connection to this Mac, and
/// counts what it leaves behind on the daemon.
///
/// **Why this exists.** Five builds were shipped to a device to chase two symptoms — a
/// terminal that stopped filling the screen and constant flicker — and every one of
/// them looked like a rendering bug. It was not. Sessions were accumulating on the
/// daemon, each becoming another tmux client, and tmux sizes a session to its SMALLEST
/// client: one stale attachment clamps the terminal for every other. Nothing about
/// either symptom pointed there, and no unit test could see it, because the thing that
/// went wrong was a COUNT on the far side of a real connection.
///
/// So this counts. It is the test that should have existed before the first of those
/// builds.
///
/// Needs a local `meshyyd` and an SSH key this Mac accepts. Skips cleanly without them:
///
///     ./scripts/meshyy-repro-setup.sh && make test-meshyy-live
@MainActor
final class MeshyySessionPileUpTests: XCTestCase {
    private static let seedPath = "/tmp/aplus-probe-seed.b64"

    /// The host's login name, written by the setup script.
    ///
    /// `NSUserName()` inside the simulator is not reliably this Mac's login name, and
    /// the username is what sshd matches the key against — so it is stated rather than
    /// guessed.
    private static var probeUser: String {
        (try? String(contentsOfFile: "/tmp/aplus-probe-user.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? NSUserName()
    }

    private func probeAuth() throws -> SSHConnection.AuthMethod {
        guard let encoded = try? String(contentsOfFile: Self.seedPath, encoding: .utf8),
              let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else {
            throw XCTSkip("no probe key at \(Self.seedPath) — run ./scripts/meshyy-repro-setup.sh")
        }
        return .key(.ed25519(key))
    }

    private func connectSSH(openShell: Bool) async throws -> SSHConnection {
        let connection = SSHConnection()
        var config = SSHConnection.Configuration(
            host: "127.0.0.1",
            port: 22,
            username: Self.probeUser,
            auth: try probeAuth(),
            cols: 80,
            rows: 24
        )
        config.connectTimeout = 10
        try await connection.connect(config, openShell: openShell)
        return connection
    }

    /// Opens a NEW session the way the app now does — the daemon allocates — and
    /// returns the transport.
    ///
    /// Skips ONLY when no daemon is installed on this Mac. Every other failure —
    /// a malformed handshake, a missing name echo, a refused attach — is a real
    /// regression on a machine that HAS the daemon, and converting those into
    /// skips would let the whole suite read green while guarding nothing (a
    /// skipped test is not a passing one; see the repo's Xcode-gotchas notes).
    private func openNew(
        serverID: UUID, over ssh: SSHConnection
    ) async throws -> MeshyyTransport {
        let result = await MeshyyTransport.bootstrapNew(
            over: ssh, serverID: serverID, sshHost: "127.0.0.1", cols: 80, rows: 40
        )
        switch result {
        case .success(let transport):
            return transport
        case .failure(.daemonAbsent):
            await ssh.disconnect()
            throw XCTSkip("no meshyyd on this Mac — run ./scripts/meshyy-repro-setup.sh")
        case .failure(let reason):
            await ssh.disconnect()
            throw ProbeFailure.bootstrap(reason.errorDescription ?? "\(reason)")
        }
    }

    private enum ProbeFailure: Error, CustomStringConvertible {
        case bootstrap(String)
        var description: String {
            switch self {
            case .bootstrap(let detail):
                "meshyyd is installed but the bootstrap failed: \(detail)"
            }
        }
    }

    /// THE REGRESSION TEST for the wormhole: a NEW session must never land in a
    /// detached survivor.
    ///
    /// The app used to compute the "free" slot from its own open tabs. Force-quit the
    /// app with sessions alive and every slot looked free again, so the next new tab
    /// bootstrapped straight into the previous shell — one old session per new tab,
    /// which the user experienced as being randomly booted into other sessions. The
    /// daemon allocates now, from the only table that knows.
    func testNewSessionNeverAdoptsADetachedSurvivor() async throws {
        let server = UUID()
        let prefix = MeshyyTransport.groupPrefix(serverID: server)
        addTeardownBlock { await self.killSessions(withPrefix: prefix) }

        // A tab is opened, then the app dies without cleanup (force-quit): the
        // daemon keeps the shell, nothing local remembers it.
        let first = try await connectSSH(openShell: false)
        let survivorTransport = try await openNew(serverID: server, over: first)
        let survivorName = survivorTransport.sessionName
        await survivorTransport.detach()
        await first.disconnect()

        // A fresh launch opens a "new session" on the same server.
        let second = try await connectSSH(openShell: false)
        let fresh = try await openNew(serverID: server, over: second)
        XCTAssertNotEqual(
            fresh.sessionName, survivorName,
            "a NEW session resolved to the detached survivor — the wormhole is back"
        )
        await fresh.disconnect()
        await second.disconnect()

        let held = try await liveSessions(withPrefix: prefix)
        XCTAssertTrue(
            held.contains { $0.name == survivorName },
            "the survivor must be left alone for the user to resume, not absorbed or killed"
        )
    }

    /// The other half of the fix: the survivor IS resumable, by name, and resuming
    /// leaves exactly one session rather than minting another.
    func testResumingASurvivorReattachesRatherThanSpawns() async throws {
        let server = UUID()
        let prefix = MeshyyTransport.groupPrefix(serverID: server)
        addTeardownBlock { await self.killSessions(withPrefix: prefix) }

        let first = try await connectSSH(openShell: false)
        let original = try await openNew(serverID: server, over: first)
        let name = original.sessionName
        await original.detach()
        await first.disconnect()

        // The picker's data: the daemon must report the survivor as detached. The
        // count is the daemon's reaction to the transport teardown, which lands a
        // beat after the client's detach returns — so poll briefly rather than
        // demanding instantaneous agreement over two different channels.
        var row: MeshyyTransport.RemoteSession?
        let deadline = Date().addingTimeInterval(8)
        repeat {
            row = try await liveSessions(withPrefix: prefix).first { $0.name == name }
            if row?.isResumable == true { break }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        guard let row else { return XCTFail("the daemon lost the detached session") }
        XCTAssertTrue(row.isResumable,
                      "a detached, running session must be offered back: \(row)")

        // Resume it — the choice the user makes on the picker.
        let second = try await connectSSH(openShell: false)
        let result = await MeshyyTransport.bootstrap(
            resuming: name, over: second, sshHost: "127.0.0.1", cols: 80, rows: 40
        )
        guard case .success(let resumed) = result else {
            await second.disconnect()
            return XCTFail("could not resume \(name): \(result)")
        }
        XCTAssertEqual(resumed.sessionName, name)
        await resumed.detach()
        await second.disconnect()

        let count = try await liveSessions(withPrefix: prefix).count
        XCTAssertEqual(count, 1, "resuming must reattach, not spawn a sibling")
    }

    /// Two tabs opened as "new" get two shells — allocation is the daemon's and is
    /// race-free there, so names never collide.
    func testTwoTabsGetTwoShells() async throws {
        let server = UUID()
        let prefix = MeshyyTransport.groupPrefix(serverID: server)
        addTeardownBlock { await self.killSessions(withPrefix: prefix) }

        var names: Set<String> = []
        for _ in 0..<2 {
            let ssh = try await connectSSH(openShell: false)
            let transport = try await openNew(serverID: server, over: ssh)
            names.insert(transport.sessionName)
            await transport.detach()
            await ssh.disconnect()
        }
        XCTAssertEqual(names.count, 2, "two 'new' tabs shared a shell: \(names)")
    }

    // MARK: - Asking the daemon what it is holding

    /// The daemon's own table for `prefix`, over a fresh SSH connection.
    ///
    /// The count comes from the DAEMON, not from this test's idea of what it did. The
    /// whole failure being reproduced here is a mismatch between the two.
    private func liveSessions(withPrefix prefix: String) async throws
        -> [MeshyyTransport.RemoteSession]
    {
        let ssh = try await connectSSH(openShell: false)
        defer { Task { await ssh.disconnect() } }
        let output = (try? await ssh.runCommand(MeshyyTransport.listCommand())) ?? ""
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = envelope["sessions"] as? [[String: Any]]
            else { continue }
            return rows.compactMap { row in
                guard let name = row["name"] as? String, name.hasPrefix(prefix),
                      let slotText = name.split(separator: "-").last,
                      let slot = Int(slotText)
                else { return nil }
                return MeshyyTransport.RemoteSession(
                    name: name,
                    slot: slot,
                    alive: row["alive"] as? Bool ?? false,
                    attachedClients: row["attached_clients"] as? Int ?? .max,
                    cols: row["cols"] as? Int ?? 0,
                    rows: row["rows"] as? Int ?? 0,
                    bufferedBytes: 0,
                    lastOutputAt: nil
                )
            }
        }
        return []
    }

    private func killSessions(withPrefix prefix: String) async {
        guard let listed = try? await liveSessions(withPrefix: prefix) else { return }
        guard let ssh = try? await connectSSH(openShell: false) else { return }
        for session in listed {
            _ = try? await ssh.runCommand(MeshyyTransport.daemonCommand("kill \(session.name)"))
        }
        await ssh.disconnect()
    }
}
