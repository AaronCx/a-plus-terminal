import SwiftUI

/// Keys the accessory bar can send (§4.2).
enum TerminalKey {
    case esc, tab, up, down, left, right, pipe, tilde, dash

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
        }
    }
}

/// Esc / Tab / sticky-Ctrl / arrows / `|` `~` `-` / paste / mic / dismiss bar
/// shown above the keyboard.
struct KeyAccessoryBar: View {
    @Bindable var bridge: TerminalBridge
    var onMic: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc") { bridge.sendKey(.esc) }
                    key("tab") { bridge.sendKey(.tab) }
                    Button {
                        bridge.ctrlActive.toggle()
                    } label: {
                        Text("ctrl")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                bridge.ctrlActive ? Color.accentColor : Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(bridge.ctrlActive ? .white : .primary)
                    }
                    .accessibilityLabel("Control")
                    .accessibilityAddTraits(bridge.ctrlActive ? .isSelected : [])
                    key(systemImage: "arrow.up") { bridge.sendKey(.up) }
                    key(systemImage: "arrow.down") { bridge.sendKey(.down) }
                    key(systemImage: "arrow.left") { bridge.sendKey(.left) }
                    key(systemImage: "arrow.right") { bridge.sendKey(.right) }
                    key("|") { bridge.sendKey(.pipe) }
                    key("~") { bridge.sendKey(.tilde) }
                    key("-") { bridge.sendKey(.dash) }
                    key(systemImage: "doc.on.clipboard") { bridge.paste() }
                        .accessibilityLabel("Paste")
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
                bridge.dismissKeyboard()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15))
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
            }
            .accessibilityLabel("Dismiss Keyboard")
        }
        .padding(.vertical, 4)
        .background(.bar)
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
