import SwiftUI

/// One-tap answers to whatever the agent is waiting on (meshyy M6 tier 1).
///
/// This bar is the app's ENTIRE contribution to the feature: the daemon
/// matched the prompt, gated the offer on the agent actually waiting, and
/// withdraws it on any screen change; MeshyyKit refuses a tap that lands
/// after the moment passed. The bar draws labels and forwards taps — sending
/// raw keystrokes from here would bypass the tested gate and silently
/// discard all of those guarantees.
struct QuickActionPaletteBar: View {
    let actions: [MeshyyQuickAction]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        onTap(action.id)
                    } label: {
                        Text(action.label)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }
}
