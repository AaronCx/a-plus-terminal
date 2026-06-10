import SwiftUI
import SwiftTerm

/// SwiftTerm view with an insert hook so the accessory bar's sticky Ctrl can
/// turn the next typed character into a control byte.
final class RelayTerminalView: TerminalView {
    var interceptInsert: ((String) -> Bool)?

    override func insertText(_ text: String) {
        if interceptInsert?(text) == true { return }
        super.insertText(text)
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

/// Hosts SwiftTerm's `TerminalView`, pumping SSH output into the emulator and
/// emulator input back into the SSH channel.
struct TerminalHostView: UIViewRepresentable {
    let connection: SSHConnection
    let bridge: TerminalBridge
    var fontSize: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(connection: connection)
    }

    func makeUIView(context: Context) -> RelayTerminalView {
        let view = RelayTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Relay ships its own accessory bar (KeyAccessoryBar).
        view.inputAccessoryView = nil
        view.interceptInsert = { [weak bridge] text in
            bridge?.handleInsert(text) ?? false
        }
        bridge.terminalView = view
        bridge.sendData = { [coordinator = context.coordinator] data in
            coordinator.sendToConnection(data)
        }
        context.coordinator.startPump(into: view)
        return view
    }

    func updateUIView(_ view: RelayTerminalView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.5 {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let connection: SSHConnection
        private var pumpTask: Task<Void, Never>?

        init(connection: SSHConnection) {
            self.connection = connection
        }

        deinit {
            pumpTask?.cancel()
        }

        func sendToConnection(_ data: Data) {
            Task { try? await connection.send(data) }
        }

        /// Feeds SSH output bytes into the emulator on the main thread.
        func startPump(into view: RelayTerminalView) {
            guard pumpTask == nil else { return }
            pumpTask = Task { [weak view, connection] in
                for await chunk in await connection.output {
                    guard let view else { return }
                    await MainActor.run {
                        view.feed(byteArray: ArraySlice([UInt8](chunk)))
                    }
                }
            }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sendToConnection(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { try? await connection.resize(cols: newCols, rows: newRows) }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
            UIApplication.shared.open(url)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
