import ActivityKit
import WidgetKit
import SwiftUI
import UIKit

/// Lock Screen + Dynamic Island presentations for active SSH sessions (§4.5).
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenSessionsView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AgentGlyph(iconName: context.state.sessions.first?.agentIconName)
                        Text("a+Terminal")
                            .font(.headline)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.activeCount)")
                        .font(.headline.monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if context.isStale {
                            Text("Sessions ended — tap to reopen")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if context.state.sessions.isEmpty {
                            Text("All sessions closed")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !context.isStale {
                            ForEach(context.state.sessions) { session in
                                Link(destination: .sessionDeepLink(id: session.id)) {
                                    SessionActivityRow(session: session)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                AgentGlyph(iconName: context.state.sessions.first?.agentIconName, size: 14)
                    .widgetURL(deepLink(for: context.state))
            } compactTrailing: {
                // An agent waiting for input outranks the session count —
                // that's the moment the user actually wants to glance for.
                if context.state.sessions.contains(where: { $0.agentIsWaiting }) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .widgetURL(deepLink(for: context.state))
                } else {
                    Text("\(context.state.activeCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .widgetURL(deepLink(for: context.state))
                }
            } minimal: {
                if context.state.sessions.contains(where: { $0.agentIsWaiting }) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                        .widgetURL(deepLink(for: context.state))
                } else {
                    Text("\(context.state.activeCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .widgetURL(deepLink(for: context.state))
                }
            }
        }
    }

    private func deepLink(for state: SessionActivityAttributes.ContentState) -> URL? {
        state.primarySessionID.map { URL.sessionDeepLink(id: $0) }
    }
}

/// The detected agent's icon, or the terminal glyph when none — the payload
/// only carries an icon name when the user's toggle is on. A USER-SUPPLIED
/// icon (App Group AgentIcons/<id>.png) wins over the bundled default, which
/// is what lets users bring vendor art the app itself does not ship.
struct AgentGlyph: View {
    let iconName: String?
    var size: CGFloat = 16

    var body: some View {
        if let iconName {
            if let custom = customImage(for: iconName) {
                Image(uiImage: custom)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            }
        } else {
            Image(systemName: "terminal.fill")
        }
    }

    /// iconName is "agent-<profileID>"; the custom file is keyed by the id.
    ///
    /// The loaded bitmap is thumbnailed DOWN TO THE SLOT before it reaches
    /// ActivityKit: the island's compact presentation replaces images larger
    /// than the slot with a gray placeholder box rather than scaling them —
    /// which is exactly how a user-imported 360px custom icon rendered as a
    /// gray square while the pre-sized bundled assets drew fine.
    private func customImage(for iconName: String) -> UIImage? {
        let id = iconName.hasPrefix("agent-") ? String(iconName.dropFirst(6)) : iconName
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.aaroncx.aplusterminal"
        ) else { return nil }
        let url = container.appendingPathComponent("AgentIcons/\(id).png")
        guard let full = UIImage(contentsOfFile: url.path) else { return nil }
        let side = size * 3   // the slot in pixels at max display scale
        return full.preparingThumbnail(of: CGSize(width: side, height: side)) ?? full
    }
}

struct SessionActivityRow: View {
    let session: SessionActivityAttributes.SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if session.isPaused {
                    // Paused-but-open: socket suspended in the background,
                    // session still reattachable. Same pause iconography as
                    // the in-app paused card (pause.circle.fill).
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 11, height: 11)
                } else {
                    Circle()
                        .fill(session.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                }
                if let icon = session.agentIconName {
                    AgentGlyph(iconName: icon, size: 13)
                }
                Text(session.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if session.isPaused {
                    Text("Paused")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(session.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 56)
            }
            if let agentLabel = session.agentLabel {
                Text(agentLabel)
                    .font(.caption)
                    .foregroundStyle(session.agentIsWaiting ? Color.orange : Color.cyan)
                    .padding(.leading, 16)
            }
        }
    }
}

struct LockScreenSessionsView: View {
    let state: SessionActivityAttributes.ContentState
    var isStale = false

    /// "Active" while anything is live; "paused" once every open session was
    /// suspended in the background (sessions still open and reattachable).
    private var title: String {
        if isStale { return "Sessions ended" }
        if state.allPaused {
            return state.activeCount == 1
                ? "1 session paused"
                : "\(state.activeCount) sessions paused"
        }
        return state.activeCount == 1
            ? "1 active session"
            : "\(state.activeCount) active sessions"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentGlyph(iconName: state.sessions.first?.agentIconName)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            if isStale {
                Text("Tap to reopen a+Terminal.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if state.sessions.isEmpty {
                Text("All sessions closed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !isStale {
                ForEach(state.sessions) { session in
                    Link(destination: .sessionDeepLink(id: session.id)) {
                        SessionActivityRow(session: session)
                    }
                }
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}
