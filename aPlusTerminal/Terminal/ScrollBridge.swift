import UIKit
import SwiftTerm

/// Pure scroll-translation logic (§4.3), separated from UIKit so the
/// no-leak regression tests can exercise it directly.
struct ScrollBridgeCore {
    enum Mode: Equatable {
        /// Mode A — the app requested mouse reporting: send SGR wheel events.
        case sgrWheel
        /// Mode B — alternate screen without mouse: send arrow keys.
        case arrowKeys
        /// Mode C — primary screen: SwiftTerm's native scrollback.
        case native
    }

    /// Finger travel per wheel event / arrow tick.
    static let pointsPerTick: CGFloat = 18
    /// Arrow lines sent per tick in Mode B.
    static let linesPerArrowTick = 3

    static func mode(altScreen: Bool, mouseReporting: Bool, wheelBridgeEnabled: Bool) -> Mode {
        if mouseReporting && wheelBridgeEnabled {
            return .sgrWheel
        }
        if altScreen {
            return .arrowKeys
        }
        return .native
    }

    private var residual: CGFloat = 0

    /// Accumulates pan travel; returns whole ticks (positive = finger moved
    /// down = wheel up / earlier content), keeping the remainder.
    mutating func ticks(forDeltaY deltaY: CGFloat) -> Int {
        residual += deltaY
        let whole = Int(residual / Self.pointsPerTick)
        residual -= CGFloat(whole) * Self.pointsPerTick
        return whole
    }

    mutating func reset() {
        residual = 0
    }

    /// SGR mouse wheel event at a 1-based cell coordinate:
    /// wheel-up `ESC[<64;col;rowM`, wheel-down `ESC[<65;col;rowM`.
    static func wheelEvent(up: Bool, col: Int, row: Int) -> Data {
        Data("\u{1B}[<\(up ? 64 : 65);\(col);\(row)M".utf8)
    }

    static func wheelEvents(up: Bool, count: Int, col: Int, row: Int) -> Data {
        var data = Data()
        for _ in 0..<count {
            data.append(wheelEvent(up: up, col: col, row: row))
        }
        return data
    }

    static func arrowEvents(up: Bool, ticks: Int, applicationCursor: Bool) -> Data {
        let key: TerminalKey = up ? .up : .down
        let bytes = key.bytes(applicationCursor: applicationCursor)
        var data = Data()
        for _ in 0..<(ticks * linesPerArrowTick) {
            data.append(contentsOf: bytes)
        }
        return data
    }
}

/// Owns the pan recognizer on a session's terminal view and routes vertical
/// pans per the mode rules. Wins over SwiftTerm's press/drag mouse pan, which
/// is what causes accidental copy-mode drags in tmux.
final class ScrollBridge: NSObject, UIGestureRecognizerDelegate {
    private weak var terminalView: TerminalEmulatorView?
    private let sendData: (Data) -> Void
    private let wheelBridgeEnabled: () -> Bool
    /// Fired when Mode B triggers on the alternate screen with no mouse mode —
    /// the "you probably want `set -g mouse on`" moment (§4.3).
    var onModeBTriggered: (() -> Void)?

    private var core = ScrollBridgeCore()
    private var activeMode: ScrollBridgeCore.Mode = .native
    private var momentumTask: Task<Void, Never>?
    /// Build 14 — while a long-press (text selection) is held, the scroll pan
    /// stands down so SwiftTerm's selection isn't hijacked into a scroll.
    private var isSuspended = false
    private weak var selectionPress: UILongPressGestureRecognizer?

    init(sendData: @escaping (Data) -> Void, wheelBridgeEnabled: @escaping () -> Bool) {
        self.sendData = sendData
        self.wheelBridgeEnabled = wheelBridgeEnabled
    }

    func attach(to view: TerminalEmulatorView) {
        terminalView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        // Existing pans yield to the bridge; `priorityPan` makes pans that
        // SwiftTerm registers later (mouse-mode pan) yield too.
        view.priorityPan = pan
        for existing in view.gestureRecognizers ?? [] where existing !== pan {
            if existing is UIPanGestureRecognizer {
                existing.require(toFail: pan)
            }
            // Snappier selection: SwiftTerm ships its long-press at 0.7s.
            if let stPress = existing as? UILongPressGestureRecognizer {
                stPress.minimumPressDuration = 0.4
            }
        }
        // A short hold suspends the scroll pan so a stationary press becomes a
        // text selection (SwiftTerm's long-press) instead of a scroll. A moving
        // finger fails this fast (small allowableMovement), leaving scroll intact.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        press.minimumPressDuration = 0.3
        press.delegate = self
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        selectionPress = press
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = terminalView else { return false }
        // Non-pan recognizers we own (the selection long-press) always begin.
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Hold in progress → let the selection / native gestures have the touch.
        if isSuspended { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }

        let terminal = view.getTerminal()
        activeMode = ScrollBridgeCore.mode(
            altScreen: terminal.isCurrentBufferAlternate,
            mouseReporting: terminal.mouseMode != .off,
            wheelBridgeEnabled: wheelBridgeEnabled()
        )
        if activeMode == .arrowKeys && terminal.mouseMode == .off {
            onModeBTriggered?()
        }
        return activeMode != .native
    }

    /// Let our selection long-press coexist with SwiftTerm's own gestures (its
    /// long-press, taps) without disturbing the scroll-pan/mouse-pan exclusivity.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === selectionPress || other === selectionPress
    }

    @objc private func handleLongPress(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            momentumTask?.cancel()
            isSuspended = true
        case .ended, .cancelled, .failed:
            isSuspended = false
        default:
            break
        }
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch pan.state {
        case .began:
            momentumTask?.cancel()
            core.reset()
        case .changed:
            let deltaY = pan.translation(in: view).y
            pan.setTranslation(.zero, in: view)
            emit(deltaY: deltaY, location: pan.location(in: view))
        case .ended:
            startMomentum(velocityY: pan.velocity(in: view).y, location: pan.location(in: view))
        case .cancelled, .failed:
            core.reset()
        default:
            break
        }
    }

    private func emit(deltaY: CGFloat, location: CGPoint) {
        guard let view = terminalView else { return }
        let ticks = core.ticks(forDeltaY: deltaY)
        guard ticks != 0 else { return }
        let up = ticks > 0

        switch activeMode {
        case .sgrWheel:
            let terminal = view.getTerminal()
            let cell = cellCoordinate(for: location, in: view, cols: terminal.cols, rows: terminal.rows)
            sendData(ScrollBridgeCore.wheelEvents(up: up, count: abs(ticks), col: cell.col, row: cell.row))
        case .arrowKeys:
            let applicationCursor = view.getTerminal().applicationCursor
            sendData(ScrollBridgeCore.arrowEvents(up: up, ticks: abs(ticks), applicationCursor: applicationCursor))
        case .native:
            break
        }
    }

    /// Momentum decay: keep emitting from the release velocity until it dies
    /// out, so a flick keeps the transcript moving like native scrolling.
    private func startMomentum(velocityY: CGFloat, location: CGPoint) {
        guard activeMode != .native, abs(velocityY) > 80 else { return }
        momentumTask = Task { @MainActor [weak self] in
            var velocity = velocityY
            while !Task.isCancelled, abs(velocity) > 40 {
                self?.emit(deltaY: velocity * 0.016, location: location)
                velocity *= 0.92
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func cellCoordinate(for point: CGPoint, in view: UIView, cols: Int, rows: Int) -> (col: Int, row: Int) {
        guard cols > 0, rows > 0, view.bounds.width > 0, view.bounds.height > 0 else { return (1, 1) }
        let col = min(max(Int(point.x / (view.bounds.width / CGFloat(cols))) + 1, 1), cols)
        let row = min(max(Int(point.y / (view.bounds.height / CGFloat(rows))) + 1, 1), rows)
        return (col, row)
    }
}
