import SwiftUI

/// Keys the accessory bar can send (§4.2).
enum TerminalKey {
    case esc, tab, up, down, left, right, pipe, tilde, dash
    case slash, ctrlC, ctrlD, home, end, pageUp, pageDown

    /// Wire bytes; arrows honor DECCKM application cursor mode.
    func bytes(applicationCursor: Bool) -> [UInt8] {
        let esc: UInt8 = 0x1B
        switch self {
        case .esc: return [esc]
        case .tab: return [0x09]
        case .up: return [esc, applicationCursor ? 0x4F : 0x5B, 0x41]
        case .down: return [esc, applicationCursor ? 0x4F : 0x5B, 0x42]
        case .right: return [esc, applicationCursor ? 0x4F : 0x5B, 0x43]
        case .left: return [esc, applicationCursor ? 0x4F : 0x5B, 0x44]
        case .pipe: return [0x7C]
        case .tilde: return [0x7E]
        case .dash: return [0x2D]
        case .slash: return [0x2F]
        case .ctrlC: return [0x03]
        case .ctrlD: return [0x04]
        case .home: return [esc, 0x5B, 0x48]            // ESC[H
        case .end: return [esc, 0x5B, 0x46]             // ESC[F
        case .pageUp: return [esc, 0x5B, 0x35, 0x7E]    // ESC[5~
        case .pageDown: return [esc, 0x5B, 0x36, 0x7E]  // ESC[6~
        }
    }
}

/// One configurable slot in the accessory bar (build 14). The set and order are
/// user-customizable in Settings; `defaultItems` reproduces the original bar.
enum KeyBarItem: String, CaseIterable, Identifiable {
    case esc, tab, ctrl, prefix, up, down, left, right, pipe, tilde, dash, paste, attach
    case slash, ctrlC, ctrlD, home, end, pageUp, pageDown

    var id: String { rawValue }

    /// The original bar, used as the default and by "Reset to default".
    static let defaultItems: [KeyBarItem] = [
        .esc, .tab, .ctrl, .prefix, .up, .down, .left, .right, .pipe, .tilde, .dash, .paste, .attach
    ]

    /// Human-readable name for the Settings list.
    var label: String {
        switch self {
        case .esc: return "Esc"
        case .tab: return "Tab"
        case .ctrl: return "Ctrl (sticky)"
        case .prefix: return "C-b (tmux prefix)"
        case .up: return "Arrow Up"
        case .down: return "Arrow Down"
        case .left: return "Arrow Left"
        case .right: return "Arrow Right"
        case .pipe: return "Pipe |"
        case .tilde: return "Tilde ~"
        case .dash: return "Dash -"
        case .paste: return "Paste"
        case .attach: return "Attach (photo / file)"
        case .slash: return "Slash /"
        case .ctrlC: return "Ctrl-C (^C)"
        case .ctrlD: return "Ctrl-D (^D)"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        }
    }

    /// Simple byte-sending keys map straight to a `TerminalKey`; the sticky
    /// modifiers, paste, and attach are handled specially in the bar.
    var terminalKey: TerminalKey? {
        switch self {
        case .esc: return .esc
        case .tab: return .tab
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .pipe: return .pipe
        case .tilde: return .tilde
        case .dash: return .dash
        case .slash: return .slash
        case .ctrlC: return .ctrlC
        case .ctrlD: return .ctrlD
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .ctrl, .prefix, .paste, .attach: return nil
        }
    }

    /// Short glyph shown on the bar button for text keys.
    var barText: String {
        switch self {
        case .esc: return "esc"
        case .tab: return "tab"
        case .pipe: return "|"
        case .tilde: return "~"
        case .dash: return "-"
        case .slash: return "/"
        case .ctrlC: return "^C"
        case .ctrlD: return "^D"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pgup"
        case .pageDown: return "pgdn"
        default: return label
        }
    }

    /// SF Symbol for arrow keys; nil = render `barText`.
    var systemImage: String? {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .paste: return "doc.on.clipboard"
        default: return nil
        }
    }
}

/// Customizable key bar shown above the keyboard. Items/order come from
/// `AppSettings.keyBarItems`; mic + keyboard toggle are fixed on the right.
struct KeyAccessoryBar: View {
    @Bindable var bridge: TerminalBridge
    var onMic: () -> Void
    var onAttachPhoto: () -> Void
    var onAttachFile: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(settings.keyBarItems) { item in
                        itemView(item)
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider().frame(height: 24)
            Button(action: onMic) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .accessibilityLabel("Dictate")
            Button {
                bridge.toggleKeyboard()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15))
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
            }
            .accessibilityLabel("Toggle Keyboard")
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private func itemView(_ item: KeyBarItem) -> some View {
        switch item {
        case .ctrl:
            stickyKey("ctrl", isOn: bridge.ctrlActive, a11y: "Control") {
                bridge.ctrlActive.toggle()
            }
        case .prefix:
            stickyKey("C-b", isOn: bridge.prefixActive, a11y: "tmux prefix Control-B") {
                bridge.prefixActive.toggle()
            }
        case .paste:
            key(systemImage: "doc.on.clipboard") { bridge.paste() }
                .accessibilityLabel("Paste")
        case .attach:
            attachMenu
        default:
            if let symbol = item.systemImage {
                key(systemImage: symbol) { send(item) }
                    .accessibilityLabel(item.label)
            } else {
                key(item.barText) { send(item) }
                    .accessibilityLabel(item.label)
            }
        }
    }

    private func send(_ item: KeyBarItem) {
        if let key = item.terminalKey { bridge.sendKey(key) }
    }

    private var attachMenu: some View {
        Menu {
            Button { onAttachPhoto() } label: { Label("Photo Library", systemImage: "photo") }
            Button { onAttachFile() } label: { Label("Files", systemImage: "folder") }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Attach image or file")
    }

    private func stickyKey(_ label: String, isOn: Bool, a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    isOn ? Color.accentColor : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .accessibilityLabel(a11y)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
        }
    }

    private func key(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
        }
    }
}
