import ActivityKit
import WidgetKit
import SwiftUI

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
                        Image(systemName: "terminal.fill")
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
                Image(systemName: "terminal.fill")
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
                Image(systemName: "terminal.fill")
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
