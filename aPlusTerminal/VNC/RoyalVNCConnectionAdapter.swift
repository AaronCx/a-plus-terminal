import CoreGraphics
import CoreImage
import Foundation
import RoyalVNCKit

/// Thread-safe frame pacing with a trailing edge: frames inside the window
/// are suppressed, but the FIRST suppression asks the caller to schedule one
/// trailing re-emit so a burst never leaves a stale frame on screen (the
/// build-31 "very laggy" review finding: leading-edge-only dropping).
final class VNCFrameThrottle: @unchecked Sendable {
    enum Decision: Equatable {
        case emit
        case suppressed(scheduleTrailing: Bool)
    }

    private let lock = NSLock()
    private var last = Date.distantPast
    private var trailingScheduled = false
    let minInterval: TimeInterval

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func decide(force: Bool) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if force || now.timeIntervalSince(last) >= minInterval {
            last = now
            return .emit
        }
        if trailingScheduled {
            return .suppressed(scheduleTrailing: false)
        }
        trailingScheduled = true
        return .suppressed(scheduleTrailing: true)
    }

    /// The scheduled trailing emit fired: true = go ahead and emit now
    /// (an intervening regular emit makes the trailing pass redundant).
    func trailingGate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        trailingScheduled = false
        let now = Date()
        guard now.timeIntervalSince(last) >= minInterval else { return false }
        last = now
        return true
    }
}

/// Single-slot main-actor delivery: only the NEWEST frame ever hops, and
/// only one hop is in flight — a slow 5K commit can no longer back up a
/// queue of SwiftUI passes (one Task per frame, the build-31 behavior).
final class VNCLatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (image: CGImage, size: CGSize)?
    private var inFlight = false

    /// Stores the frame as latest. Returns true when the caller should start
    /// a delivery hop (none is currently in flight).
    func submit(_ image: CGImage, size: CGSize) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        latest = (image, size)
        if inFlight { return false }
        inFlight = true
        return true
    }

    /// Next frame to deliver, or nil when drained (clears the in-flight flag).
    func take() -> (image: CGImage, size: CGSize)? {
        lock.lock()
        defer { lock.unlock() }
        if let value = latest {
            latest = nil
            return value
        }
        inFlight = false
        return nil
    }
}

/// Weak, lock-guarded reference usable from the SDK's background queues.
private final class WeakFramebufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var framebuffer: VNCFramebuffer?

    func set(_ framebuffer: VNCFramebuffer?) {
        lock.lock()
        defer { lock.unlock() }
        self.framebuffer = framebuffer
    }

    func get() -> VNCFramebuffer? {
        lock.lock()
        defer { lock.unlock() }
        return framebuffer
    }
}

/// Real RoyalVNCKit-backed implementation of `VNCConnecting`. Bridges the
/// SDK's background-queue delegate callbacks onto the main actor, converts
/// credential types, and materializes DOWNSCALED frame snapshots off-main:
/// a 5K desktop is rendered once per emitted frame at ≤`maxImageEdge` via a
/// cached CIContext under the framebuffer's read lock — no deferred
/// CoreImage render on the main thread, no tearing against the live
/// IOSurface, ~75% less per-frame memory than full-resolution (the build-31
/// lag package). Protocol-level update-request pacing is still not public
/// in RoyalVNCKit 1.1.0, so decode cost tracks the server's update rate —
/// known limitation.
@MainActor
final class RoyalVNCConnectionAdapter: NSObject, VNCConnecting {
    weak var delegate: VNCConnectingDelegate?

    private let connection: VNCConnection
    private let throttle: VNCFrameThrottle
    private let deliveryBox = VNCLatestFrameBox()
    private let framebufferBox = WeakFramebufferBox()
    /// Cached (CIContext is expensive to create and thread-safe to use).
    private let ciContext = CIContext()
    /// Longest edge of the images handed to the UI. ~2× iPhone points:
    /// enough for fit-to-screen and moderate zoom; a 5120×2880 desktop drops
    /// from 59 MB to ~15 MB per frame. Deep zoom trades sharpness — noted
    /// in the PR as a beta limitation.
    private let maxImageEdge: CGFloat

    init(server: Server, minFrameInterval: TimeInterval = 1.0 / 15.0, maxImageEdge: CGFloat = 2560) {
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: server.host,
            port: UInt16(clamping: server.port),
            isShared: true,               // never kick the console session
            isScalingEnabled: false,
            useDisplayLink: false,
            // Governs the SDK's macOS-client keyboard-shortcut capture, not
            // the pointer/key APIs below — the app gates those on Control
            // mode itself (VNCMonitorSession).
            inputMode: .none,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        self.connection = VNCConnection(settings: settings)
        self.throttle = VNCFrameThrottle(minInterval: minFrameInterval)
        self.maxImageEdge = maxImageEdge
        super.init()
        connection.delegate = self
    }

    func connect() {
        connection.connect()
    }

    func disconnect() {
        connection.disconnect()
    }

    func sendPointer(_ action: VNCPointerAction, x: UInt16, y: UInt16) {
        switch action {
        case .move:
            connection.mouseMove(x: x, y: y)
        case .leftDown:
            connection.mouseButtonDown(.left, x: x, y: y)
        case .leftUp:
            connection.mouseButtonUp(.left, x: x, y: y)
        case .rightClick:
            connection.mouseButtonDown(.right, x: x, y: y)
            connection.mouseButtonUp(.right, x: x, y: y)
        }
    }

    func sendText(_ text: String) {
        for key in VNCKeyCode.keyCodesFrom(characters: text) {
            connection.keyDown(key)
            connection.keyUp(key)
        }
    }

    func sendSpecialKey(_ key: VNCSpecialKey) {
        let code: VNCKeyCode
        switch key {
        case .return: code = .return
        case .escape: code = .escape
        case .tab: code = .tab
        case .delete: code = .delete
        }
        connection.keyDown(code)
        connection.keyUp(code)
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
                    // ARD requires the username+password credential type —
                    // a password-only credential aborts the handshake.
                    completion(VNCUsernamePasswordCredential(username: username, password: password))
                case nil:
                    completion(nil)
                }
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        framebufferBox.set(framebuffer)
        publishFrame(framebuffer, force: true)
    }

    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        framebufferBox.set(framebuffer)
        publishFrame(framebuffer, force: true)
    }

    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        // Dirty rects are ignored: the monitor redraws the whole image at a
        // capped rate (the vendor's iOS demo does the same).
        publishFrame(framebuffer, force: false)
    }

    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        let shape = cursor.isEmpty ? nil : cursor.cgImage
        let hotspot = cursor.cgHotspot
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.vncConnection(self, didUpdateCursorShape: shape, hotspot: hotspot)
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didMovePointerToX x: UInt16, y: UInt16) {
        // PointerPos (vendored patch). macOS Screen Sharing never sends it
        // (probe-verified 2026-07-24); other servers may.
        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.vncConnection(self, didMovePointerTo: position)
        }
    }

    private nonisolated func publishFrame(_ framebuffer: VNCFramebuffer, force: Bool) {
        switch throttle.decide(force: force) {
        case .emit:
            renderAndDeliver(framebuffer)
        case .suppressed(let scheduleTrailing):
            guard scheduleTrailing else { return }
            // One trailing pass per window: after the interval, re-extract
            // whatever the framebuffer holds THEN, so the last burst frame
            // always lands on screen.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + throttle.minInterval) { [weak self] in
                guard let self, self.throttle.trailingGate(),
                      let framebuffer = self.framebufferBox.get() else { return }
                self.renderAndDeliver(framebuffer)
            }
        }
    }

    private nonisolated func renderAndDeliver(_ framebuffer: VNCFramebuffer) {
        // Materialize the snapshot here, on the SDK's queue, under the
        // surface read lock: the main thread receives a finished CGImage.
        guard let ciImage = framebuffer.ciImage else { return }
        let fullSize = framebuffer.cgSize
        let scale = min(1, maxImageEdge / max(fullSize.width, max(fullSize.height, 1)))
        let scaled = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        framebuffer.allocator.lockReadOnly()
        let image = ciContext.createCGImage(scaled, from: scaled.extent)
        framebuffer.allocator.unlockReadOnly()
        guard let image else { return }
        deliver(image, size: fullSize)
    }

    private nonisolated func deliver(_ image: CGImage, size: CGSize) {
        guard deliveryBox.submit(image, size: size) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let frame = self.deliveryBox.take() {
                self.delegate?.vncConnection(self, didUpdateFrame: frame.image, size: frame.size)
            }
        }
    }
}
