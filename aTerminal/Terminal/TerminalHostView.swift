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

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        if let priorityPan, gestureRecognizer !== priorityPan,
           gestureRecognizer is UIPanGestureRecognizer {
            gestureRecognizer.require(toFail: priorityPan)
        }
    }
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
        send(consumePrefixBytes() + key.bytes(applicationCursor: applicationCursor))
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
              let scalar = text.uppercased().unicodeScalars.first,
              scalar.isASCII else {
            return nil
        }
        switch UInt8(scalar.value) {
        case let byte where (0x40...0x5F).contains(byte):
            return byte & 0x1F
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
        return view
    }

    func updateUIView(_ view: TerminalEmulatorView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.5 {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }
}
