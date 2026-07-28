import MeshyyCore
import SwiftUI

/// Decides whether the palette is offered, and which actions.
///
/// A free function rather than an `if` inside the view body, because "actions are
/// unavailable when the agent is not waiting — no stray sends" is the property this
/// feature has to get right, and a condition buried in a `ViewBuilder` can only be
/// checked by looking at the screen. meshyy asserts the same rule on its own side of
/// the wire; this is the app's half of it.
enum QuickActionAvailability {
    /// Note `MeshyyCore` also exports an `AgentActivityMonitor` — the daemon-side
    /// detector that feeds notifications. This takes the APP's, which has driven the
    /// Live Activity since build 14. Same-module declarations win here, but the two
    /// names being one grep apart is worth saying out loud.
    static func actions(
        forAgentStatus status: AgentActivityMonitor.Status
    ) -> [QuickActionDefinition] {
        status == .waiting ? QuickActionPalette.tier1 : []
    }
}

/// One-tap answers to an agent's prompt, shown only while the agent is waiting.
///
/// This is meshyy's M6 tier 1, and it is deliberately the stupidest thing that works:
/// a fixed row of keystrokes, with **no parsing of the screen at all**. It cannot
/// break when an agent changes its UI, because it never looked at the UI. The
/// alternative — scraping an alt-screen TUI to extract the actual options — demos
/// well once and then breaks silently on the next upstream release.
///
/// The keys come from `QuickActionPalette.tier1`, which is data rather than code and
/// contains no agent name and no prompt text. They are terminal universals: the same
/// keystrokes a person would type at any prompt in any program of the last forty
/// years.
///
/// **Not gated on meshyy.** The gate is "an agent is waiting", which the app has
/// detected locally since build 14 for the Live Activity. Tying this to the transport
/// would withhold the feature from every SSH session for no reason — a permission
/// prompt is just as tedious to answer without meshyy as with it.
struct QuickActionBar: View {
    let actions: [QuickActionDefinition]
    let agentName: String?
    var onTap: (QuickActionDefinition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.id) { action in
                        Button {
                            onTap(action)
                        } label: {
                            Text(action.label)
                                .font(.system(.callout, design: .rounded).weight(.medium))
                                .frame(minWidth: 44, minHeight: 34)
                                .padding(.horizontal, 10)
                                .background(background(for: action), in: .rect(cornerRadius: 8))
                                .foregroundStyle(foreground(for: action))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(for: action))
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Names the agent when it is known, and says nothing about what it asked —
    /// the app never reads the prompt, so it must not imply that it did.
    private var prompt: String {
        if let agentName { "\(agentName) is waiting" } else { "Waiting for you" }
    }

    /// Interrupt is set apart, because it is the only key here that throws work away
    /// rather than answering a question, and the cost of a mis-tap is not symmetric.
    private func background(for action: QuickActionDefinition) -> some ShapeStyle {
        action.id == "interrupt" ? AnyShapeStyle(.red.opacity(0.15)) : AnyShapeStyle(.quaternary)
    }

    private func foreground(for action: QuickActionDefinition) -> some ShapeStyle {
        action.id == "interrupt" ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)
    }

    /// The labels are single characters, which VoiceOver reads as letters rather than
    /// as what they do. Spelling out the intent costs nothing and makes the row usable
    /// without sight — which is the whole point of a one-tap answer.
    private func accessibilityLabel(for action: QuickActionDefinition) -> String {
        switch action.id {
        case "yes": "Yes"
        case "no": "No"
        case "enter": "Enter"
        case "escape": "Escape"
        case "interrupt": "Interrupt"
        case "option-1": "Option 1"
        case "option-2": "Option 2"
        case "option-3": "Option 3"
        default: action.label
        }
    }
}

#Preview("Palette above the key bar") {
    // Reproduces the build 45 layout bug if the VStack in TerminalScreen is ever
    // removed: without it the two bars overlay and the caption is clipped in half.
    VStack(spacing: 0) {
        Color.black.frame(height: 120)
        VStack(spacing: 0) {
            QuickActionBar(
                actions: QuickActionPalette.tier1,
                agentName: "Claude Code"
            ) { _ in }
            HStack(spacing: 6) {
                ForEach(["esc", "ctrl", "C-b"], id: \.self) { key in
                    Text(key)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minWidth: 54, minHeight: 38)
                        .background(.quaternary, in: .rect(cornerRadius: 8))
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}
