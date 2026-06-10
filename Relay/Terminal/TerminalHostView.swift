import SwiftUI
import SwiftTerm

/// SwiftTerm view with an insert hook so the accessory bar's sticky Ctrl can
/// turn the next typed character into a control byte.
final class RelayTerminalView: TerminalView {
    var interceptInsert: ((String) -> Bool)?
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

    @ObservationIgnored weak var terminalView: RelayTerminalView?
    @ObservationIgnored var sendData: ((Data) -> Void)?

    func send(_ bytes: [UInt8]) {
        sendData?(Data(bytes))
    }

    func sendKey(_ key: TerminalKey) {
        let applicationCursor = terminalView?.getTerminal().applicationCursor ?? false
        send(key.bytes(applicationCursor: applicationCursor))
    }

    func paste() {
        guard let text = UIPasteboard.general.string else { return }
        sendData?(Data(text.utf8))
    }

    func focus() {
        terminalView?.becomeFirstResponder()
    }

    func dismissKeyboard() {
        terminalView?.resignFirstResponder()
    }

    /// Sticky-Ctrl chord: consumes one typed character and sends its control
    /// byte instead (tap ctrl, tap C → 0x03 — Claude Code interrupt, §4.2).
    func handleInsert(_ text: String) -> Bool {
        guard ctrlActive else { return false }
        ctrlActive = false
        guard text.count == 1,
              let scalar = text.uppercased().unicodeScalars.first,
              scalar.isASCII else {
            return false
        }
        switch UInt8(scalar.value) {
        case let byte where (0x40...0x5F).contains(byte):
            send([byte & 0x1F])
            return true
        case 0x20:
            send([0x00])
            return true
        case 0x3F:
            send([0x7F])
            return true
        default:
            return false
        }
    }
}

/// Mounts a session's persistent terminal view, so emulator state survives
/// navigating away and back.
struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession
    var fontSize: Double

    func makeUIView(context: Context) -> RelayTerminalView {
        let view = session.terminalView
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return view
    }

    func updateUIView(_ view: RelayTerminalView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.5 {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }
}
