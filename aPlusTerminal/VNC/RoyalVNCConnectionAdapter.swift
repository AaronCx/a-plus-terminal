import CoreGraphics
import Foundation
import RoyalVNCKit

/// Thread-safe frame pacing for the adapter's background delegate callbacks.
private final class FrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func shouldEmit(force: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard force || now.timeIntervalSince(last) >= minInterval else { return false }
        last = now
        return true
    }
}

/// Real RoyalVNCKit-backed implementation of `VNCConnecting`. Bridges the
/// SDK's background-queue delegate callbacks onto the main actor, converts
/// credential types, and caps whole-frame image extraction (~30 fps —
/// protocol-level update-request pacing is not public in RoyalVNCKit 1.1.0,
/// so decode cost still tracks the server's update rate; known limitation).
@MainActor
final class RoyalVNCConnectionAdapter: NSObject, VNCConnecting {
    weak var delegate: VNCConnectingDelegate?

    private let connection: VNCConnection
    private let throttle: FrameThrottle

    init(server: Server, minFrameInterval: TimeInterval = 1.0 / 30.0) {
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: server.host,
            port: UInt16(clamping: server.port),
            isShared: true,               // never kick the console session
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .none,             // view-only: no input, ever (§1)
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        self.connection = VNCConnection(settings: settings)
        self.throttle = FrameThrottle(minInterval: minFrameInterval)
        super.init()
        connection.delegate = self
    }

    func connect() {
        connection.connect()
    }

    func disconnect() {
        connection.disconnect()
    }
}

// RoyalVNCKit delivers these on its own background queues; every body hops
// to the main actor before touching the session.
extension RoyalVNCConnectionAdapter: VNCConnectionDelegate {
    nonisolated func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let error = connectionState.error
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wire: VNCWireState
            switch status {
            case .connecting: wire = .connecting
            case .connected: wire = .connected
            case .disconnecting: wire = .disconnecting
            case .disconnected: wire = .disconnected(error)
            @unknown default: wire = .disconnected(error)
            }
            self.delegate?.vncConnection(self, didChangeState: wire)
        }
    }

    nonisolated func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType, completion: @escaping (VNCCredential?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, let delegate = self.delegate else {
                completion(nil)
                return
            }
            delegate.vncConnection(self, credentialFor: authenticationType) { supplied in
                switch supplied {
                case .password(let password):
                    completion(VNCPasswordCredential(password: password))
                case .usernamePassword(let username, let password):
                    completion(VNCUsernamePasswordCredential(username: username, password: password))
                case nil:
                    completion(nil)
                }
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        publishFrame(framebuffer, force: true)
    }

    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        publishFrame(framebuffer, force: true)
    }

    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        // Dirty rects are ignored: the monitor redraws the whole image at a
        // capped rate (the vendor's iOS demo does the same).
        publishFrame(framebuffer, force: false)
    }

    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        // View-only monitor: the remote cursor is not rendered.
    }

    private nonisolated func publishFrame(_ framebuffer: VNCFramebuffer, force: Bool) {
        guard throttle.shouldEmit(force: force) else { return }
        // CGImage conversion happens here on the SDK's queue, off the main
        // thread; only the finished image hops over.
        guard let image = framebuffer.cgImage else { return }
        let size = framebuffer.cgSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.vncConnection(self, didUpdateFrame: image, size: size)
        }
    }
}
