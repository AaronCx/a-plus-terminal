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

    // Note: SwiftTerm 1.13.0 doesn't publicly expose the negotiated mouse
    // *encoding* (only `mouseMode`), so Mode A always emits SGR (1006) wheel
    // events. That's correct for effectively all modern apps that enable mouse
    // reporting; a legacy app that enables mouse without SGR (X10 only) would
    // misparse the wheel bytes. Revisit if SwiftTerm exposes `mouseProtocol`.
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

    /// The 1-based row a wheel event should claim for a touch at `y` in a
    /// view of `height` with `rows` rows — clamped OFF the bottom row.
    ///
    /// tmux's default binds wheel-on-the-status-line to previous/next-window,
    /// and the status line is the bottom row — so a swipe that drifts low
    /// switched windows instead of scrolling ("no previous window" in the
    /// message bar). A scroll gesture means "scroll the CONTENT"; the content
    /// never includes the bottom row of a multiplexer, and no TUI puts its
    /// scrollable region there. Aiming one row up costs nothing anywhere.
    static func wheelRow(forY y: CGFloat, height: CGFloat, rows: Int) -> Int {
        guard rows > 1, height > 0 else { return 1 }
        let raw = min(max(Int(y / (height / CGFloat(rows))) + 1, 1), rows)
        return min(raw, rows - 1)
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

/// The routing decision for one swipe, and the emulator belief it was made on.
struct SwipeDecision: Equatable {
    let mode: ScrollBridgeCore.Mode
    let mouseMode: Terminal.MouseMode
    let altScreen: Bool
    let applicationCursor: Bool
    let rows: Int
    let cols: Int
    let wheelBridgeEnabled: Bool
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

    #if MESHYY
    /// Scroll trace (observation only). nil, or a tracer whose store is
    /// disabled, leaves every byte and every routing decision exactly as
    /// without it. Beta-only: App Store candidates compile the trace out.
    var tracer: ScrollGestureTracer?
    /// Used instead of `sendData` for bytes that belong to a trace record, so
    /// the transport's send outcome can be reported against that record. Must
    /// deliver the bytes exactly as `sendData` would.
    var sendTraced: ((Data, UUID) -> Void)?
    #endif

    private var core = ScrollBridgeCore()
    private var activeMode: ScrollBridgeCore.Mode = .native
    private var momentumTask: Task<Void, Never>?
    #if MESHYY
    /// The open trace record for the current gesture, if tracing.
    private var traceID: UUID?
    #endif
    /// Build 14 — while a long-press (text selection) is held, the scroll pan
    /// stands down so SwiftTerm's selection isn't hijacked into a scroll.
    private var isSuspended = false
    private weak var selectionPress: UILongPressGestureRecognizer?

    init(sendData: @escaping (Data) -> Void, wheelBridgeEnabled: @escaping () -> Bool) {
        self.sendData = sendData
        self.wheelBridgeEnabled = wheelBridgeEnabled
    }

    deinit {
        // A flick can leave momentum emitting after the view/session goes away.
        momentumTask?.cancel()
    }

    func attach(to view: TerminalEmulatorView) {
        terminalView = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        // Set priorityPan *before* adding, so the addGestureRecognizer override
        // already knows our pan when it (and any pan SwiftTerm registers later,
        // e.g. its mouse-mode pan) is wired to require(toFail:) ours.
        view.priorityPan = pan
        view.addGestureRecognizer(pan)
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
        guard let view = terminalView else {
            #if MESHYY
            if gestureRecognizer is UIPanGestureRecognizer { traceDecline(.noView) }
            #endif
            return false
        }
        // Non-pan recognizers we own (the selection long-press) always begin.
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Hold in progress → let the selection / native gestures have the touch.
        if isSuspended {
            #if MESHYY
            traceDecline(.selectionHold)
            #endif
            return false
        }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else {
            #if MESHYY
            traceDecline(.horizontal)
            #endif
            return false
        }
        guard let decision = beginSwipe() else { return false }
        // `.native` declines the pan, handing the swipe to SwiftTerm's own
        // scrollback (TerminalView is a UIScrollView).
        return decision.mode != .native
    }

    /// The routing decision for a swipe starting now, from the emulator's
    /// current belief. Sets `activeMode` (what every emission of this gesture,
    /// momentum included, is routed by) and opens the gesture's trace record.
    /// The pan path calls this after its selection-hold and direction checks;
    /// tests and the SSH-oracle harness call it directly.
    @discardableResult
    func beginSwipe() -> SwipeDecision? {
        guard let view = terminalView else {
            #if MESHYY
            traceDecline(.noView)
            #endif
            return nil
        }
        let terminal = view.getTerminal()
        let bridgeEnabled = wheelBridgeEnabled()
        activeMode = ScrollBridgeCore.mode(
            altScreen: terminal.isCurrentBufferAlternate,
            mouseReporting: terminal.mouseMode != .off,
            wheelBridgeEnabled: bridgeEnabled
        )
        let decision = SwipeDecision(
            mode: activeMode,
            mouseMode: terminal.mouseMode,
            altScreen: terminal.isCurrentBufferAlternate,
            applicationCursor: terminal.applicationCursor,
            rows: terminal.rows,
            cols: terminal.cols,
            wheelBridgeEnabled: bridgeEnabled
        )
        if activeMode == .arrowKeys && terminal.mouseMode == .off {
            onModeBTriggered?()
        }
        #if MESHYY
        traceID = tracer?.begin(decision, view: view)
        #endif
        return decision
    }

    /// Test/oracle seam: emits `ticks` wheel ticks (or arrow ticks) for the
    /// current `activeMode` through the SAME `emit` the pan uses, as if the
    /// finger travelled exactly that far at `point`, and returns the bytes
    /// sent (empty on the native route). Call `beginSwipe()` first.
    @discardableResult
    func injectSwipe(ticks: Int, up: Bool, at point: CGPoint) -> Data {
        core.reset()
        let travel = CGFloat(ticks) * ScrollBridgeCore.pointsPerTick
        #if MESHYY
        return emit(deltaY: up ? travel : -travel, location: point, traceID: traceID)
        #else
        return emit(deltaY: up ? travel : -travel, location: point)
        #endif
    }

    /// Test/oracle seam: releases the finger at `velocityY` (points/s, UIKit
    /// sign: positive = finger moving down = wheel up), running the SAME momentum decay
    /// as a real pan's `.ended`. The gesture's record closes when it dies out.
    func injectRelease(velocityY: CGFloat, at point: CGPoint) {
        startMomentum(velocityY: velocityY, location: point)
    }

    #if MESHYY
    /// Closes the current gesture's trace record (the pan path does this when
    /// momentum ends or the pan cancels).
    func endSwipe() {
        finishTrace(traceID)
    }

    private func finishTrace(_ id: UUID?) {
        guard let id else { return }
        tracer?.end(id)
        if traceID == id { traceID = nil }
    }

    private func traceDecline(_ reason: ScrollTrace.DeclineReason) {
        guard let tracer, tracer.isRecording else { return }
        tracer.decline(reason, wheelBridgeEnabled: wheelBridgeEnabled(), view: terminalView)
    }
    #endif

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
        guard let view = terminalView else {
            #if MESHYY
            // The view went away mid-gesture: still close its record, or the
            // trace shows a swipe that never finished.
            switch pan.state {
            case .ended, .cancelled, .failed: endSwipe()
            default: break
            }
            #endif
            return
        }
        switch pan.state {
        case .began:
            momentumTask?.cancel()
            core.reset()
        case .changed:
            let deltaY = pan.translation(in: view).y
            pan.setTranslation(.zero, in: view)
            #if MESHYY
            emit(deltaY: deltaY, location: pan.location(in: view), traceID: traceID)
            #else
            emit(deltaY: deltaY, location: pan.location(in: view))
            #endif
        case .ended:
            startMomentum(velocityY: pan.velocity(in: view).y, location: pan.location(in: view))
        case .cancelled, .failed:
            core.reset()
            #if MESHYY
            endSwipe()
            #endif
        default:
            break
        }
    }

    /// The single producer of scroll bytes: pan, momentum and `injectSwipe`
    /// all come through here. Returns what it sent.
    #if MESHYY
    @discardableResult
    private func emit(deltaY: CGFloat, location: CGPoint, momentum: Bool = false, traceID: UUID?) -> Data {
        guard let out = scrollBytes(deltaY: deltaY, location: location) else { return Data() }
        if let traceID, let tracer, let sendTraced {
            tracer.emitted(
                recordID: traceID, ticks: abs(out.ticks), up: out.ticks > 0, momentum: momentum,
                col: out.cell?.col, row: out.cell?.row, bytes: out.bytes
            )
            sendTraced(out.bytes, traceID)
        } else {
            sendData(out.bytes)
        }
        return out.bytes
    }
    #else
    @discardableResult
    private func emit(deltaY: CGFloat, location: CGPoint) -> Data {
        guard let bytes = scrollBytes(deltaY: deltaY, location: location)?.bytes else { return Data() }
        sendData(bytes)
        return bytes
    }
    #endif

    /// The bytes one pan delta produces on the current route, with the signed
    /// tick count and (wheel route) the target cell. nil when nothing is sent:
    /// no view, under one tick of travel, or the native route.
    private func scrollBytes(
        deltaY: CGFloat, location: CGPoint
    ) -> (bytes: Data, ticks: Int, cell: (col: Int, row: Int)?)? {
        guard let view = terminalView else { return nil }
        let ticks = core.ticks(forDeltaY: deltaY)
        guard ticks != 0 else { return nil }
        let up = ticks > 0

        switch activeMode {
        case .sgrWheel:
            let terminal = view.getTerminal()
            let target = cellCoordinate(for: location, in: view, cols: terminal.cols, rows: terminal.rows)
            let bytes = ScrollBridgeCore.wheelEvents(up: up, count: abs(ticks), col: target.col, row: target.row)
            return (bytes, ticks, target)
        case .arrowKeys:
            let applicationCursor = view.getTerminal().applicationCursor
            let bytes = ScrollBridgeCore.arrowEvents(up: up, ticks: abs(ticks), applicationCursor: applicationCursor)
            return (bytes, ticks, nil)
        case .native:
            return nil
        }
    }

    /// Momentum decay: keep emitting from the release velocity until it dies
    /// out, so a flick keeps the transcript moving like native scrolling.
    private func startMomentum(velocityY: CGFloat, location: CGPoint) {
        guard activeMode != .native, abs(velocityY) > 80 else {
            #if MESHYY
            endSwipe()
            #endif
            return
        }
        #if MESHYY
        let gestureTrace = traceID
        // Held strongly: if the bridge is deallocated mid-flick (tab closed),
        // deinit cancels this task and `self` is gone, but the gesture's
        // record must still close — an open record reads as a stuck swipe.
        let tracer = self.tracer
        momentumTask = Task { @MainActor [weak self] in
            var velocity = velocityY
            while !Task.isCancelled, abs(velocity) > 40 {
                self?.emit(deltaY: velocity * 0.016, location: location, momentum: true, traceID: gestureTrace)
                velocity *= 0.92
                try? await Task.sleep(for: .milliseconds(16))
            }
            if let self {
                self.finishTrace(gestureTrace)
            } else if let gestureTrace {
                tracer?.end(gestureTrace)
            }
        }
        #else
        momentumTask = Task { @MainActor [weak self] in
            var velocity = velocityY
            while !Task.isCancelled, abs(velocity) > 40 {
                self?.emit(deltaY: velocity * 0.016, location: location)
                velocity *= 0.92
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        #endif
    }

    /// Approximate 1-based cell under `point`, assuming the grid fills the
    /// view's bounds with uniform cells (no content inset, single pane). That
    /// holds for the common full-screen terminal; SwiftTerm 1.13.0 doesn't
    /// expose precise cell metrics/origin to refine multi-pane targeting.
    private func cellCoordinate(for point: CGPoint, in view: UIView, cols: Int, rows: Int) -> (col: Int, row: Int) {
        guard cols > 0, rows > 0, view.bounds.width > 0, view.bounds.height > 0 else { return (1, 1) }
        let col = min(max(Int(point.x / (view.bounds.width / CGFloat(cols))) + 1, 1), cols)
        // Never the bottom row — see ScrollBridgeCore.wheelRow.
        let row = ScrollBridgeCore.wheelRow(forY: point.y, height: view.bounds.height, rows: rows)
        return (col, row)
    }
}
