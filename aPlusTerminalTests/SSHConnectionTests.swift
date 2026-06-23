import XCTest
import Citadel
import CryptoKit
import NIOCore
import NIOSSH
@testable import aPlusTerminal

/// Accepts public-key auth for exactly one allowed key.
final class SingleKeyAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    static let acceptedPassword = "open-sesame" // lastgate-ignore (in-process test server fixture)

    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password]
    let allowedKey: NIOSSHPublicKey

    init(allowedKey: NIOSSHPublicKey) {
        self.allowedKey = allowedKey
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case .publicKey(let key) where key.publicKey == allowedKey:
            responsePromise.succeed(.success)
        case .password(let password) where password.password == Self.acceptedPassword:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// Shell that announces readiness and echoes stdin back, prefixed so tests can
/// tell echo from banner.
struct EchoShell: ShellDelegate {
    func startShell(
        inbound: AsyncStream<ShellClientEvent>,
        outbound: ShellOutboundWriter,
        context: SSHShellContext
    ) async throws {
        outbound.write("APLUSTERMINAL-TEST-READY\n")
        for await event in inbound {
            if case .stdin(let buffer) = event {
                var reply = ByteBuffer(string: "echo:")
                var copy = buffer
                reply.writeBuffer(&copy)
                outbound.write(reply)
            }
        }
    }
}

final class SSHConnectionTests: XCTestCase {
    var server: SSHServer!
    var hostKey: Curve25519.Signing.PrivateKey!
    var clientKey: Curve25519.Signing.PrivateKey!
    var port: Int!

    var hostKeyLine: String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: hostKey).publicKey)
    }

    override func setUp() async throws {
        try await super.setUp()
        hostKey = Curve25519.Signing.PrivateKey()
        clientKey = Curve25519.Signing.PrivateKey()

        // Bind retry: random high ports until one is free.
        for attempt in 0..<5 {
            let candidate = Int.random(in: 30000..<60000)
            do {
                server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: candidate,
                    hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
                    authenticationDelegate: SingleKeyAuthDelegate(
                        allowedKey: NIOSSHPrivateKey(ed25519Key: clientKey).publicKey
                    )
                )
                server.enableShell(withDelegate: EchoShell())
                port = candidate
                break
            } catch {
                if attempt == 4 { throw error }
            }
        }
    }

    override func tearDown() async throws {
        try? await server?.close()
        try await super.tearDown()
    }

    private func makeConfig(knownHostKey: String? = nil) -> SSHConnection.Configuration {
        SSHConnection.Configuration(
            host: "127.0.0.1",
            port: port,
            username: "aplusterminal-test",
            auth: .privateKey(clientKey),
            knownHostKey: knownHostKey
        )
    }

    /// Reads from the connection's output stream until `marker` appears or the
    /// timeout elapses.
    private func collectOutput(
        _ connection: SSHConnection,
        until marker: String,
        timeout: TimeInterval = 10
    ) async -> String {
        let task = Task { () -> String in
            var collected = ""
            for await chunk in await connection.output {
                collected += String(decoding: chunk, as: UTF8.self)
                if collected.contains(marker) { break }
            }
            return collected
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            task.cancel()
        }
        let result = await task.value
        timeoutTask.cancel()
        return result
    }

    func testConnectShellRoundTripAndDisconnect() async throws {
        let connection = SSHConnection()
        try await connection.connect(makeConfig())

        let recordedHostKey = await connection.serverHostKey
        XCTAssertEqual(recordedHostKey, hostKeyLine, "TOFU should record the server's host key")

        try await connection.send("hello\n")
        let output = await collectOutput(connection, until: "echo:hello")
        XCTAssertTrue(output.contains("APLUSTERMINAL-TEST-READY"), "shell banner missing in: \(output)")
        XCTAssertTrue(output.contains("echo:hello"), "echo missing in: \(output)")

        await connection.disconnect()
        if case .disconnected = await connection.state {} else {
            XCTFail("expected disconnected state")
        }
    }

    func testPinnedHostKeyAccepted() async throws {
        let connection = SSHConnection()
        try await connection.connect(makeConfig(knownHostKey: hostKeyLine))
        await connection.disconnect()
    }

    func testHostKeyMismatchHardFails() async throws {
        let impostorKey = String(
            openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        )

        let connection = SSHConnection()
        do {
            try await connection.connect(makeConfig(knownHostKey: impostorKey))
            XCTFail("connect should have failed on host key mismatch")
        } catch let error as SSHConnectionError {
            guard case .hostKeyMismatch(let expected, let presented) = error else {
                return XCTFail("expected hostKeyMismatch, got \(error)")
            }
            XCTAssertTrue(expected.hasPrefix("SHA256:"))
            XCTAssertTrue(presented.hasPrefix("SHA256:"))
            XCTAssertNotEqual(expected, presented, "fingerprint diff must show both keys")
            XCTAssertEqual(presented, HostKeyFingerprint.fingerprint(ofOpenSSHKey: hostKeyLine))
        }
    }

    func testWrongClientKeyRejected() async throws {
        let connection = SSHConnection()
        do {
            try await connection.connect(makeConfig().with(privateKey: Curve25519.Signing.PrivateKey()))
            XCTFail("connect should have failed with an unauthorized key")
        } catch {
            // Must not be a host-key mismatch. The hermetic test server accepts
            // connections (see testPasswordAuthConnects), so reaching
            // .disconnected(error) means auth was attempted and rejected — not a
            // transport/bind problem that would also satisfy a looser check.
            XCTAssertFalse(error is SSHConnectionError, "expected an auth failure, not a host-key mismatch")
            guard case .disconnected(let err) = await connection.state, err != nil else {
                return XCTFail("expected .disconnected(error) after auth rejection")
            }
        }
    }

    func testPasswordAuthConnects() async throws {
        let connection = SSHConnection()
        try await connection.connect(makeConfig().with(password: SingleKeyAuthDelegate.acceptedPassword))
        try await connection.send("hello\n")
        let output = await collectOutput(connection, until: "echo:hello")
        XCTAssertTrue(output.contains("echo:hello"), "echo missing in: \(output)")
        await connection.disconnect()
    }

    func testWrongPasswordRejected() async throws {
        let connection = SSHConnection()
        do {
            try await connection.connect(makeConfig().with(password: "wrong"))
            XCTFail("connect should have failed with a wrong password")
        } catch {
            XCTAssertFalse(error is SSHConnectionError, "expected an auth failure, not a host-key mismatch")
            guard case .disconnected(let err) = await connection.state, err != nil else {
                return XCTFail("expected .disconnected(error) after auth rejection")
            }
        }
    }

    func testSendBeforeConnectThrows() async throws {
        let connection = SSHConnection()
        do {
            try await connection.send("nope\n")
            XCTFail("send should throw before connect")
        } catch let error as SSHConnectionError {
            guard case .notConnected = error else {
                return XCTFail("expected notConnected, got \(error)")
            }
        }
    }
}

private extension SSHConnection.Configuration {
    func with(privateKey: Curve25519.Signing.PrivateKey) -> Self {
        var copy = self
        copy.auth = .privateKey(privateKey)
        return copy
    }

    func with(password: String) -> Self {
        var copy = self
        copy.auth = .password(password)
        return copy
    }
}

final class HostKeyFingerprintTests: XCTestCase {
    func testFingerprintMatchesOpenSSHFormat() {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let line = String(openSSHPublicKey: key.publicKey)
        let fingerprint = HostKeyFingerprint.fingerprint(ofOpenSSHKey: line)
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(fingerprint.hasSuffix("="), "OpenSSH fingerprints strip base64 padding")
        XCTAssertEqual(fingerprint, HostKeyFingerprint.fingerprint(ofOpenSSHKey: line), "deterministic")
    }

    func testInvalidLineDoesNotCrash() {
        XCTAssertEqual(HostKeyFingerprint.fingerprint(ofOpenSSHKey: "garbage"), "(invalid key)")
    }
}
