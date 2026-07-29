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

    /// THE REGRESSION TEST. Attaching the same tab twice must leave ONE session.
    ///
    /// It used to leave two, because the session name was keyed on the tab's UUID and a
    /// relaunch minted a new one. Six accumulated on a real device in an evening.
    func testReattachingTheSameTabDoesNotSpawnASecondShell() async throws {
        let server = UUID()
        let name = MeshyyTransport.sessionName(serverID: server, slot: 0)
        addTeardownBlock { await self.killSession(named: name) }

        for attempt in 1...3 {
            let ssh = try await connectSSH(openShell: false)
            let result = await MeshyyTransport.bootstrap(
                over: ssh, serverID: server, slot: 0, sshHost: "127.0.0.1", cols: 80, rows: 40
            )
            switch result {
            case .success(let transport):
                await transport.detach()   // the app's suspend path
            case .failure(let reason):
                await ssh.disconnect()
                throw XCTSkip("meshyy unavailable locally: \(reason.errorDescription ?? "?")")
            }
            await ssh.disconnect()

            let count = try await liveSessions(withPrefix: name).count
            XCTAssertEqual(
                count, 1,
                "after \(attempt) attach(es) the daemon holds \(count) sessions for one tab — "
                    + "each extra one is another shell, and on a host that auto-attaches a "
                    + "multiplexer, another client clamping everyone's terminal size"
            )
        }
    }

    /// Two tabs on one server must get two shells — the bug this replaced was the
    /// opposite, where every tab landed in the first tab's shell.
    func testTwoTabsGetTwoShells() async throws {
        let server = UUID()
        let names = [0, 1].map { MeshyyTransport.sessionName(serverID: server, slot: $0) }
        addTeardownBlock { for name in names { await self.killSession(named: name) } }

        for slot in [0, 1] {
            let ssh = try await connectSSH(openShell: false)
            let result = await MeshyyTransport.bootstrap(
                over: ssh, serverID: server, slot: slot, sshHost: "127.0.0.1", cols: 80, rows: 40
            )
            guard case .success(let transport) = result else {
                await ssh.disconnect()
                throw XCTSkip("meshyy unavailable locally")
            }
            await transport.detach()
            await ssh.disconnect()
        }

        for name in names {
            // Hoisted: XCTAssert's autoclosure cannot be async.
            let count = try await liveSessions(withPrefix: name).count
            XCTAssertEqual(count, 1, "\(name) should own exactly one shell")
        }
    }

    // MARK: - Asking the daemon what it is holding

    /// Runs `meshyyd list` on the host over SSH and returns the lines for `prefix`.
    ///
    /// The count comes from the DAEMON, not from this test's idea of what it did. The
    /// whole failure being reproduced here is a mismatch between the two.
    private func liveSessions(withPrefix prefix: String) async throws -> [String] {
        let ssh = try await connectSSH(openShell: false)
        defer { Task { await ssh.disconnect() } }
        let output = (try? await ssh.runCommand(MeshyyTransport.daemonCommand("list"))) ?? ""
        return output.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }
    }

    private func killSession(named name: String) async {
        guard let ssh = try? await connectSSH(openShell: false) else { return }
        _ = try? await ssh.runCommand(MeshyyTransport.daemonCommand("kill \(name)"))
        await ssh.disconnect()
    }
}
