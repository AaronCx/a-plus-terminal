import SwiftUI
import SwiftTerm

/// SwiftTerm view with an insert hook so the accessory bar's sticky Ctrl can
/// turn the next typed character into a control byte.
final class TerminalEmulatorView: TerminalView {
    var interceptInsert: ((String) -> Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Upstream SwiftTerm fix (#566/#567, landed after the 1.13.0 release we
        // pin): the glyph renderer paints transparent backdrops expecting the
        // layer color to show through. On an opaque view that leaves
        // uninitialized backing-store garbage which scroll blits re-expose as
        // overlapping/striped rows — the "text doubling" seen on device.
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    /// ScrollBridge's pan recognizer. SwiftTerm registers its press/drag mouse
    /// pan lazily — the moment an app enables mouse reporting (tmux `mouse on`)
    /// — which is after ScrollBridge attached. Any pan added later must yield
    /// to the wheel bridge or drags become copy-mode selections.
    weak var priorityPan: UIPanGestureRecognizer?

    override func insertText(_ text: String) {
        if interceptInsert?(text) == true { return }
        super.insertText(text)
    }

    /// True while the emulator itself is writing to the pty. In SwiftTerm
    /// 1.13.0 every such write — a reply to a query in the output (DA, DSR
    /// and cursor position, mode reports, colors, window ops, kitty
    /// keyboard flags and graphics), a mode-1004 focus report, or a mouse
    /// report — goes through `Terminal.sendResponse` / `setTerminalFocus` to
    /// this `send(source:data:)`. Typing (soft and hardware keyboard, kitty
    /// encoding included), paste, dictation and the accessory keys go
    /// through the view's `send(data:)` and never set it. Marked HERE, the
    /// one funnel, rather than around the pumps' `feed` calls, so no output
    /// path can forget to mark its replies. A SwiftTerm bump must re-check
    /// that split.
    private(set) var isEmulatorWriting = false

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        isEmulatorWriting = true
        defer { isEmulatorWriting = false }
        super.send(source: source, data: data)
    }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        if let priorityPan, gestureRecognizer !== priorityPan,
           gestureRecognizer is UIPanGestureRecognizer {
            gestureRecognizer.require(toFail: priorityPan)
        }
    }

    #if MESHYY
    /// When the emulator's mouse-mode belief last moved (scroll trace). Every
    /// scroll bug so far was this belief diverging from the far side's, so
    /// the trace needs to say how fresh it was when a swipe was routed on it.
    ///
    /// Stamped only on an actual change: SwiftTerm calls `mouseModeChanged`
    /// on every assignment, and meshyy's `.modes` frames re-assert the same
    /// mode, so stamping every call would make an unchanged belief look as
    /// if it had just flipped.
    private(set) var lastMouseModeChangeAt: Date?
    /// The mode before the last change (nil until one happens).
    private(set) var previousMouseMode: Terminal.MouseMode?
    private var currentMouseMode: Terminal.MouseMode = .off
    /// When the emulator last switched between the primary and alt buffer
    /// (SwiftTerm reports a re-entry into the buffer already active too).
    private(set) var lastBufferSwitchAt: Date?
    private var currentBufferIsAlternate = false

    override func mouseModeChanged(source: Terminal) {
        let mode = source.mouseMode
        if mode != currentMouseMode {
            previousMouseMode = currentMouseMode
            currentMouseMode = mode
            lastMouseModeChangeAt = Date()
        }
        super.mouseModeChanged(source: source)
    }

    override func bufferActivated(source: Terminal) {
        let alternate = source.isCurrentBufferAlternate
        if alternate != currentBufferIsAlternate {
            currentBufferIsAlternate = alternate
            lastBufferSwitchAt = Date()
        }
        super.bufferActivated(source: source)
    }
    #endif
}

/// Connects the SwiftUI layer (accessory bar, screens) to the UIKit terminal
/// view and the SSH channel. ScrollBridge (PR 6) plugs in here too.
@Observable
final class TerminalBridge {
    /// Sticky Ctrl: armed by the accessory bar, consumed by the next key.
    var ctrlActive = false
    /// Sticky tmux prefix (C-b): armed by the accessory bar, prepended to the
    /// next key — typed, ctrl-chorded, or an accessory arrow (pane nav).
    var prefixActive = false

    @ObservationIgnored weak var terminalView: TerminalEmulatorView?
    @ObservationIgnored var sendData: ((Data) -> Void)?

    func send(_ bytes: [UInt8]) {
        sendData?(Data(bytes))
    }

    func sendKey(_ key: TerminalKey) {
        let applicationCursor = terminalView?.getTerminal().applicationCursor ?? false
        let keyBytes = key.bytes(applicationCursor: applicationCursor)
        let prefix = consumePrefixBytes()
        // Sticky Ctrl arms the *next* key. Apply it to a single-byte accessory
        // key the same way the typed path does, and always disarm it so it
        // can't silently leak onto a later typed character.
        if ctrlActive {
            ctrlActive = false
            if keyBytes.count == 1, let control = Self.controlByte(forByte: keyBytes[0]) {
                send(prefix + [control])
                return
            }
        }
        send(prefix + keyBytes)
    }

    private func consumePrefixBytes() -> [UInt8] {
        guard prefixActive else { return [] }
        prefixActive = false
        return [0x02]
    }

    func paste() {
        // Never read the pasteboard synchronously on the main thread: the
        // paste-permission gate (libRPAC) can block on user consent, wedging
        // the entire UI (observed live: main thread parked in
        // dispatch_semaphore_wait under -[UIPasteboard string]).
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let text = UIPasteboard.general.string else { return }
            await MainActor.run {
                guard let self else { return }
                self.sendData?(Data(self.consumePrefixBytes() + Array(text.utf8)))
            }
        }
    }

    func focus() {
        terminalView?.becomeFirstResponder()
    }

    func dismissKeyboard() {
        terminalView?.resignFirstResponder()
    }

    /// Deterministic keyboard affordance: tap-to-refocus on the canvas can be
    /// swallowed by system UI, so the accessory bar button toggles instead.
    func toggleKeyboard() {
        guard let terminalView else { return }
        if terminalView.isFirstResponder {
            terminalView.resignFirstResponder()
        } else {
            terminalView.becomeFirstResponder()
        }
    }

    /// Sticky-Ctrl chord: consumes one typed character and sends its control
    /// byte instead (tap ctrl, tap C → 0x03 — Claude Code interrupt, §4.2).
    func handleInsert(_ text: String) -> Bool {
        // Chords apply to single keystrokes only. Multi-character inserts
        // (keyboard dictation results, autocomplete) must pass through
        // untouched — and must not consume an armed chord.
        guard text.count == 1 else { return false }
        let prefix = consumePrefixBytes()
        if ctrlActive {
            ctrlActive = false
            if let control = Self.controlByte(for: text) {
                send(prefix + [control])
                return true
            }
            // Unmappable chord: fall through, still honoring an armed prefix.
        }
        if !prefix.isEmpty {
            send(prefix + Array(text.utf8))
            return true
        }
        return false
    }

    private static func controlByte(for text: String) -> UInt8? {
        guard text.count == 1,
              let scalar = text.unicodeScalars.first,
              scalar.isASCII else {
            return nil
        }
        return controlByte(forByte: UInt8(scalar.value))
    }

    /// The control byte for a single ASCII byte (e.g. `c`/`C` → 0x03), or nil
    /// if it has no control mapping. Letters are normalized to uppercase.
    private static func controlByte(forByte byte: UInt8) -> UInt8? {
        let upper = (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
        switch upper {
        case 0x40...0x5F:
            return upper & 0x1F
        case 0x20:
            return 0x00
        case 0x3F:
            return 0x7F
        default:
            return nil
        }
    }
}

/// Mounts a session's persistent terminal view, so emulator state survives
/// navigating away and back.
struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession
    var fontSize: Double

    func makeUIView(context: Context) -> TerminalEmulatorView {
        let view = session.terminalView
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Lets a UI test find the terminal's frame (DuoLayoutUITests checks
        // the column count against it). Not spoken by VoiceOver.
        view.accessibilityIdentifier = "terminalView"
        return view
    }

    func updateUIView(_ view: TerminalEmulatorView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.5 {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }
}
