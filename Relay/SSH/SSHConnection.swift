import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

enum SSHConnectionError: LocalizedError {
    /// The server presented a host key that doesn't match the pinned one.
    /// There is deliberately no "accept anyway" path (§4.1 — MITM protection).
    case hostKeyMismatch(expectedFingerprint: String, presentedFingerprint: String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .hostKeyMismatch(let expected, let presented):
            return "Host key mismatch — possible man-in-the-middle attack. Expected \(expected) but the server presented \(presented). If the server was legitimately reinstalled, remove it in Relay and add it again."
        case .notConnected:
            return "Not connected."
        }
    }
}

enum HostKeyFingerprint {
    /// OpenSSH-style fingerprint (`SHA256:` + unpadded base64) of an
    /// `algorithm base64blob` public key line.
    static func fingerprint(ofOpenSSHKey line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return "(invalid key)"
        }
        let base64 = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Trust-on-first-use host key validation. With no pinned key it accepts and
/// records whatever the server presents; with a pinned key it hard-fails on
/// any mismatch.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let pinnedKey: String?
    private let lock = NSLock()
    private var _presentedKey: String?

    /// OpenSSH line (`ssh-ed25519 AAAA…`) the server presented, recorded
    /// during the handshake.
    var presentedKey: String? {
        lock.withLock { _presentedKey }
    }

    init(pinnedKey: String?) {
        self.pinnedKey = pinnedKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        lock.withLock { _presentedKey = presented }

        guard let pinnedKey else {
            validationCompletePromise.succeed(())
            return
        }
        if let pinned = try? NIOSSHPublicKey(openSSHPublicKey: pinnedKey), pinned == hostKey {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SSHConnectionError.hostKeyMismatch(
                expectedFingerprint: HostKeyFingerprint.fingerprint(ofOpenSSHKey: pinnedKey),
                presentedFingerprint: HostKeyFingerprint.fingerprint(ofOpenSSHKey: presented)
            ))
        }
    }
}

/// One SSH connection with an interactive PTY shell: async connect →
/// public-key auth → PTY (`xterm-256color`) → shell. Output is delivered on
/// `output`; input goes through `send`.
actor SSHConnection {
    struct Configuration {
        var host: String
        var port: Int = 22
        var username: String
        var privateKey: Curve25519.Signing.PrivateKey
        /// Pinned host key (OpenSSH line) from a previous connection, nil on first use.
        var knownHostKey: String?
        var terminal: String = "xterm-256color"
        var cols: Int = 80
        var rows: Int = 24
    }

    enum State {
        case idle
        case connecting
        case connected
        case disconnected(Error?)
    }

    private(set) var state: State = .idle
    /// OpenSSH line the server presented; persist this after first connect (TOFU).
    private(set) var serverHostKey: String?

    let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var ptyTask: Task<Void, Never>?

    init() {
        (output, outputContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    func connect(_ config: Configuration) async throws {
        state = .connecting
        let validator = TOFUHostKeyValidator(pinnedKey: config.knownHostKey)
        let settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: { [privateKey = config.privateKey, username = config.username] in
                .ed25519(username: username, privateKey: privateKey)
            },
            hostKeyValidator: .custom(validator)
        )

        do {
            let client = try await SSHClient.connect(to: settings)
            self.client = client
            self.serverHostKey = validator.presentedKey
        } catch {
            // NIOSSH may wrap our validator error; resurface the mismatch directly.
            let resolved = (error as? SSHConnectionError) ?? Self.mismatch(in: validator, pinned: config.knownHostKey) ?? error
            state = .disconnected(resolved)
            throw resolved
        }

        do {
            try await openPTY(config)
        } catch {
            state = .disconnected(error)
            await closeClient()
            throw error
        }
        state = .connected
    }

    func send(_ data: Data) async throws {
        guard let writer else { throw SSHConnectionError.notConnected }
        try await writer.write(ByteBuffer(bytes: data))
    }

    func send(_ text: String) async throws {
        try await send(Data(text.utf8))
    }

    /// Runs a one-off command on a separate exec channel; the PTY shell is
    /// untouched. Used for tmux session discovery (§4.1).
    func runCommand(_ command: String) async throws -> String {
        guard let client else { throw SSHConnectionError.notConnected }
        let buffer = try await client.executeCommand(command)
        return String(buffer: buffer)
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let writer else { throw SSHConnectionError.notConnected }
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func disconnect() async {
        ptyTask?.cancel()
        ptyTask = nil
        writer = nil
        await closeClient()
        if case .disconnected = state {} else {
            state = .disconnected(nil)
        }
        outputContinuation.finish()
    }

    private static func mismatch(in validator: TOFUHostKeyValidator, pinned: String?) -> SSHConnectionError? {
        guard let pinned, let presented = validator.presentedKey,
              let pinnedKey = try? NIOSSHPublicKey(openSSHPublicKey: pinned),
              let presentedKey = try? NIOSSHPublicKey(openSSHPublicKey: presented),
              pinnedKey != presentedKey else {
            return nil
        }
        return .hostKeyMismatch(
            expectedFingerprint: HostKeyFingerprint.fingerprint(ofOpenSSHKey: pinned),
            presentedFingerprint: HostKeyFingerprint.fingerprint(ofOpenSSHKey: presented)
        )
    }

    private func openPTY(_ config: Configuration) async throws {
        guard let client else { throw SSHConnectionError.notConnected }

        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let readyOnce = OnceFlag()
            ptyTask = Task { [outputContinuation] in
                do {
                    try await client.withPTY(SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: config.terminal,
                        terminalCharacterWidth: config.cols,
                        terminalRowHeight: config.rows,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: .init([:])
                    )) { inbound, outbound in
                        await self.adopt(writer: outbound)
                        if readyOnce.trySet() { ready.resume() }
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                outputContinuation.yield(Data(buffer.readableBytesView))
                            }
                        }
                    }
                    await self.channelEnded(nil)
                } catch {
                    if readyOnce.trySet() {
                        ready.resume(throwing: error)
                    } else {
                        await self.channelEnded(error)
                    }
                }
            }
        }
    }

    private func adopt(writer: TTYStdinWriter) {
        self.writer = writer
    }

    private func channelEnded(_ error: Error?) async {
        writer = nil
        state = .disconnected(error)
        await closeClient()
        outputContinuation.finish()
    }

    private func closeClient() async {
        guard let client else { return }
        self.client = nil
        try? await client.close()
    }
}

/// Set-once flag, safe across concurrent contexts.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns true exactly once.
    func trySet() -> Bool {
        lock.withLock {
            if isSet { return false }
            isSet = true
            return true
        }
    }
}
