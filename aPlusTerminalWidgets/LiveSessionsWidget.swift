import WidgetKit
import SwiftUI

/// Home-screen view of the sessions you actually have open, and a way back
/// into them.
///
/// The Server Status widget answers "is the box up". This one answers "what am
/// I running, and can I get back to it" — the thing you want from the home
/// screen when an agent is working in a tmux session somewhere.
///
/// Both jumps reuse deep links the app already routes (`DeepLinkRouter.handle`):
/// a live session opens `aplusterminal://session/<uuid>`, and a server with no
/// session opens `aplusterminal://connect/<uuid>`, which is the same request an
/// App Intent makes. No new entry points into the app, and nothing here can act
/// on its own — a widget tap always lands in the app.
struct LiveSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LiveSessionsWidgetKind, provider: LiveSessionsProvider()) { entry in
            LiveSessionsView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Sessions")
        .description("Your open sessions — tap to jump back in, or start one on a saved server.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LiveSessionsProvider: TimelineProvider {
    /// Enough to fill a large widget without turning the timeline into work.
    static let maxRows = 6

    func placeholder(in context: Context) -> LiveSessionsEntry {
        LiveSessionsEntry(date: Date(), rows: [
            .init(id: UUID(), name: "Mac mini",
                  kind: .session(state: "connected", startedAt: Date().addingTimeInterval(-2_400), agent: "Claude Code")),
            .init(id: UUID(), name: "homelab",
                  kind: .session(state: "suspended", startedAt: Date().addingTimeInterval(-9_000), agent: nil)),
            .init(id: UUID(), name: "vps", kind: .idleServer),
        ], stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (LiveSessionsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveSessionsEntry>) -> Void) {
        let entry = makeEntry()
        // The app reloads this widget on every session change, so the timeline
        // only has to cover the case where the app never gets to run. Fifteen
        // minutes keeps the elapsed times from drifting far without spending
        // budget the app's own reloads make unnecessary.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)
            ?? entry.date.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry() -> LiveSessionsEntry {
        let snapshot = SessionSnapshotStore.read()
        let stale = SessionSnapshotStore.isStale(snapshot)
        // A stale snapshot lists sessions that almost certainly no longer
        // exist. Offering them as live would send the user into a session the
        // app has to recreate; showing the servers instead is honest and still
        // useful, because starting one is what they would do next anyway.
        let sessions = stale ? [] : snapshot.sessions

        var rows = sessions
            .sorted { $0.startedAt > $1.startedAt }
            .map { summary in
                LiveSessionsEntry.Row(
                    id: summary.id,
                    name: summary.name,
                    kind: .session(state: summary.state,
                                   startedAt: summary.startedAt,
                                   agent: summary.agentLabel)
                )
            }

        // Fill the remaining space with servers that have nothing open, so the
        // widget is useful before the first session of the day too.
        let busy = Set(sessions.map(\.name))
        for server in ServerStore.sharedSnapshot() where !busy.contains(server.name) {
            guard rows.count < Self.maxRows else { break }
            guard server.kind == .ssh else { continue }
            rows.append(.init(id: server.id, name: server.name, kind: .idleServer))
        }

        return LiveSessionsEntry(date: Date(), rows: Array(rows.prefix(Self.maxRows)), stale: stale)
    }
}

// MARK: - Views

struct LiveSessionsView: View {
    @Environment(\.widgetFamily) private var family

    let entry: LiveSessionsEntry

    private var visibleRows: [LiveSessionsEntry.Row] {
        switch family {
        case .systemSmall: return Array(entry.rows.prefix(1))
        case .systemMedium: return Array(entry.rows.prefix(3))
        default: return Array(entry.rows.prefix(6))
        }
    }

    var body: some View {
        if entry.rows.isEmpty {
            emptyState
        } else if family == .systemSmall {
            // Small widgets get one tap target for the whole widget, so it
            // carries the single most relevant row rather than a list that
            // cannot be tapped individually.
            smallBody
                .widgetURL(visibleRows.first?.url)
        } else {
            listBody
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Add a server in a+Terminal")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var smallBody: some View {
        if let row = visibleRows.first {
            VStack(alignment: .leading, spacing: 5) {
                SessionStatusChip(row: row)
                Text(row.name)
                    .font(.headline)
                    .lineLimit(2)
                if case .session(_, let startedAt, let agent) = row.kind {
                    if let agent {
                        Text(agent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(startedAt, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Tap to connect")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entry.sessionCount == 0 ? "No open sessions" : "\(entry.sessionCount) open")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.stale {
                    Text("stale")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(visibleRows) { row in
                // Per-row Links are what make "jump into this one" possible;
                // a widgetURL would send every tap to the same place.
                if let url = row.url {
                    Link(destination: url) { SessionRowView(row: row) }
                } else {
                    SessionRowView(row: row)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionStatusChip: View {
    let row: LiveSessionsEntry.Row

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        }
    }

    private var label: String {
        switch row.kind {
        case .session(let state, _, _):
            switch state {
            case "connected": return "LIVE"
            case "suspended": return "PAUSED"
            case "reconnecting": return "RECONNECTING"
            default: return state.uppercased()
            }
        case .idleServer:
            return "START"
        }
    }

    private var color: Color {
        switch row.kind {
        case .session(let state, _, _):
            switch state {
            case "connected": return .green
            case "suspended": return .orange
            default: return .yellow
            }
        case .idleServer:
            return .secondary
        }
    }
}

struct SessionRowView: View {
    let row: LiveSessionsEntry.Row

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if case .session(_, _, let agent) = row.kind, let agent {
                    Text(agent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.kind {
        case .session(let state, let startedAt, _):
            if state == "connected" {
                Text(startedAt, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(state == "suspended" ? "paused" : state)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        case .idleServer:
            Image(systemName: "play.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var dotColor: Color {
        switch row.kind {
        case .session(let state, _, _):
            return state == "connected" ? .green : .orange
        case .idleServer:
            return .gray.opacity(0.5)
        }
    }
}
