import CoreGraphics
import Foundation
import Observation
import RoyalVNCKit

/// Session states for a VNC monitor, mirroring the SSH session model
/// (brief §4.2). `suspended` is the background-disconnect analog of the SSH
/// paused state; `failed` carries the human-readable reason.
enum VNCMonitorSessionState: Equatable {
    case idle
    case connecting
    case authenticating
    case connected
    case reconnecting
    case suspended
    case failed(String)
    case closed

    var isOpen: Bool {
        self != .closed
    }

    /// A connection (or attempt) that would be interrupted by suspension.
    var isActiveConnection: Bool {
        self == .connecting || self == .authenticating || self == .connected
    }
}

/// Transport-level state reported by a VNC connection implementation.
enum VNCWireState {
    case connecting
    case connected
    case disconnecting
    case disconnected(Error?)
}

/// Credential the session supplies back to the wire on an auth request.
enum VNCSuppliedCredential: Equatable {
    case password(String)
    case usernamePassword(username: String, password: String)
}

/// A pointer event the app can inject when the user enables Control mode.
enum VNCPointerAction: Equatable {
    case move
    case leftDown
    case leftUp
    case rightClick
}

/// Seam between the session state machine and RoyalVNCKit, so the state
/// machine is unit-testable against a mock (brief §4.7). All calls and
/// delegate events are main-actor.
@MainActor
protocol VNCConnecting: AnyObject {
    var delegate: VNCConnectingDelegate? { get set }
    func connect()
    func disconnect()
    /// Coordinates are framebuffer pixels, pre-clamped by the session.
    func sendPointer(_ action: VNCPointerAction, x: UInt16, y: UInt16)
    /// Types text on the host (character key events).
    func sendText(_ text: String)
    /// A special (non-character) key press.
    func sendSpecialKey(_ key: VNCSpecialKey)
}

/// Non-character keys the Control keyboard exposes.
enum VNCSpecialKey: Equatable {
    case `return`
    case escape
    case tab
    case delete
}

@MainActor
protocol VNCConnectingDelegate: AnyObject {
    func vncConnection(_ connection: VNCConnecting, didChangeState state: VNCWireState)
    func vncConnection(
        _ connection: VNCConnecting,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCSuppliedCredential?) -> Void
    )
    func vncConnection(_ connection: VNCConnecting, didUpdateFrame image: CGImage, size: CGSize)
    /// The server sent a new cursor shape (nil = the empty cursor).
    func vncConnection(_ connection: VNCConnecting, didUpdateCursorShape shape: CGImage?, hotspot: CGPoint)
    /// The server reported the remote pointer's position (PointerPos —
    /// framebuffer pixels). Only some servers send it.
    func vncConnection(_ connection: VNCConnecting, didMovePointerTo position: CGPoint)
}

/// RoyalVNCKit errors → human-readable session errors, using the SDK's
/// LocalizedError descriptions (brief §4.2).
enum VNCErrorMapper {
    static func isAuthenticationFailure(_ error: Error?) -> Bool {
        (error as? VNCError)?.isAuthenticationError ?? false
    }

    static func message(for error: Error?) -> String {
        guard let error else { return "Connection closed." }
        if let vncError = error as? VNCError {
            if vncError.isAuthenticationError {
                return "Authentication failed — check the username and password. \(vncError.localizedDescription)"
            }
            return vncError.localizedDescription
        }
        return error.localizedDescription
    }
}

/// One VNC monitor of a remote screen. Owns the connection (via the
/// `VNCConnecting` seam), the latest framebuffer image, the client-rendered
/// cursor state, and the state machine. Opens view-only: every input path
/// is gated on the per-session Control mode, which defaults off.
@MainActor
@Observable
final class VNCMonitorSession: Identifiable, Hashable {
    nonisolated let id = UUID()
    let startedAt = Date()
    private(set) var server: Server
    private(set) var state: VNCMonitorSessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?()
            pipInvalidate?()
        }
    }
    /// Latest decoded remote frame (whole-screen; dirty rects are not
    /// tracked — the monitor redraws the full image at a capped rate).
    private(set) var lastFrame: CGImage?
    private(set) var framebufferSize: CGSize = .zero

    // MARK: Control mode (touch + keyboard input; off = classic view-only)

    /// Whether taps/keys are forwarded to the host. Per-session, defaults
    /// off — the monitor stays view-only until the user opts in.
    private(set) var controlEnabled = false
    /// Remote cursor shape from the server (nil until one arrives).
    private(set) var cursorShape: CGImage?
    private(set) var cursorHotspot: CGPoint = .zero
    /// Best-known remote cursor position (framebuffer pixels): last
    /// injected position, or server-reported when the host sends PointerPos.
    /// Nil until either source produces one (overlay hidden).
    private(set) var cursorPosition: CGPoint?

    func setControlEnabled(_ enabled: Bool) {
        controlEnabled = enabled
    }

    /// Clamp + forward a pointer action; remembers the position so the
    /// cursor overlay tracks the finger.
    func sendPointer(_ action: VNCPointerAction, at point: CGPoint) {
        guard controlEnabled, state == .connected, let connection,
              framebufferSize.width > 0 else { return }
        let clamped = CGPoint(
            x: min(max(point.x, 0), framebufferSize.width - 1),
            y: min(max(point.y, 0), framebufferSize.height - 1)
        )
        cursorPosition = clamped
        connection.sendPointer(action, x: UInt16(clamped.x), y: UInt16(clamped.y))
    }

    /// A full tap: move there, press, release.
    func sendTap(at point: CGPoint) {
        sendPointer(.move, at: point)
        sendPointer(.leftDown, at: point)
        sendPointer(.leftUp, at: point)
    }

    func sendText(_ text: String) {
        guard controlEnabled, state == .connected, !text.isEmpty else { return }
        connection?.sendText(text)
    }

    func sendSpecialKey(_ key: VNCSpecialKey) {
        guard controlEnabled, state == .connected else { return }
        connection?.sendSpecialKey(key)
    }

    /// Single pop-out slot, mirroring `TerminalSession.pipInvalidate`.
    @ObservationIgnored var pipInvalidate: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?

    private let passwords: PasswordStore
    private let makeConnection: (Server) -> VNCConnecting
    private var connection: VNCConnecting?
    /// One automatic reconnect per unexpected drop (mirrors the SSH retry
    /// spirit without a full backoff loop); further failures surface.
    private var reconnectAttempted = false
    private var suspending = false

    nonisolated static func == (lhs: VNCMonitorSession, rhs: VNCMonitorSession) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(
        server: Server,
        passwords: PasswordStore,
        makeConnection: @escaping (Server) -> VNCConnecting
    ) {
        self.server = server
        self.passwords = passwords
        self.makeConnection = makeConnection
    }

    func connect() {
        guard state == .idle || state == .suspended || isFailed else { return }
        suspending = false
        // A fresh user-initiated connect earns a fresh quiet-retry budget,
        // same as retry().
        reconnectAttempted = false
        openConnection(as: .connecting)
    }

    /// User-initiated retry from a failure card.
    func retry() {
        guard isFailed || state == .suspended else { return }
        reconnectAttempted = false
        openConnection(as: .connecting)
    }

    /// Backgrounded without a pop-out keeping the process alive: tear the
    /// socket down cleanly. The user reconnects on return (no auto path,
    /// matching the SSH contract).
    func suspend() {
        guard state == .connected || state == .connecting || state == .authenticating else { return }
        suspending = true
        connection?.disconnect()
        state = .suspended
    }

    func close() {
        state = .closed
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func openConnection(as newState: VNCMonitorSessionState) {
        connection?.delegate = nil
        connection?.disconnect()
        let fresh = makeConnection(server)
        connection = fresh
        fresh.delegate = self
        state = newState
        fresh.connect()
    }

    /// Resolve the stored credential for the wire's auth request. ARD wants
    /// username + password; classic VNC wants password only (the server uses
    /// just the first 8 characters — surfaced in the connect form's helper
    /// text). A request we have no credential for completes nil and the
    /// resulting auth failure surfaces normally.
    private func credential(for authenticationType: VNCAuthenticationType) -> VNCSuppliedCredential? {
        let password = server.passwordRef.flatMap { passwords.password(for: $0) } ?? ""
        switch authenticationType {
        case .appleRemoteDesktop, .ultraVNCMSLogonII:
            guard !server.username.isEmpty, !password.isEmpty else { return nil }
            return .usernamePassword(username: server.username, password: password)
        case .vnc:
            guard !password.isEmpty else { return nil }
            return .password(password)
        @unknown default:
            return nil
        }
    }
}

extension VNCMonitorSession: VNCConnectingDelegate {
    func vncConnection(_ connection: VNCConnecting, didChangeState wireState: VNCWireState) {
        guard connection === self.connection else { return }
        switch wireState {
        case .connecting:
            if state != .authenticating && state != .reconnecting {
                state = .connecting
            }
        case .connected:
            reconnectAttempted = false
            state = .connected
        case .disconnecting:
            break
        case .disconnected(let error):
            handleDisconnect(error)
        }
    }

    func vncConnection(
        _ connection: VNCConnecting,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCSuppliedCredential?) -> Void
    ) {
        guard connection === self.connection else {
            completion(nil)
            return
        }
        if state == .connecting {
            state = .authenticating
        }
        completion(credential(for: authenticationType))
    }

    func vncConnection(_ connection: VNCConnecting, didUpdateFrame image: CGImage, size: CGSize) {
        guard connection === self.connection else { return }
        lastFrame = image
        framebufferSize = size
        pipInvalidate?()
    }

    func vncConnection(_ connection: VNCConnecting, didUpdateCursorShape shape: CGImage?, hotspot: CGPoint) {
        guard connection === self.connection else { return }
        cursorShape = shape
        cursorHotspot = hotspot
    }

    func vncConnection(_ connection: VNCConnecting, didMovePointerTo position: CGPoint) {
        guard connection === self.connection else { return }
        cursorPosition = position
    }

    private func handleDisconnect(_ error: Error?) {
        if state == .closed { return }
        if suspending {
            suspending = false
            state = .suspended
            return
        }
        if let error {
            if VNCErrorMapper.isAuthenticationFailure(error) {
                state = .failed(VNCErrorMapper.message(for: error))
            } else if state == .connected && !reconnectAttempted {
                // One quiet retry for a transport blip on an established
                // monitor; a second failure lands on the failure card.
                reconnectAttempted = true
                openConnection(as: .reconnecting)
            } else {
                state = .failed(VNCErrorMapper.message(for: error))
            }
        } else if state == .connected {
            state = .failed("The host closed the connection.")
        } else {
            state = .failed(VNCErrorMapper.message(for: error))
        }
    }
}
