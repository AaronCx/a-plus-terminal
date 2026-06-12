import WidgetKit
import SwiftUI

/// Home-screen "is my server up" widget. Reads the shared server list from
/// the App Group container and TCP-probes each host in the timeline provider
/// — entirely on-device, like everything else in the app.
struct ServerStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ServerStatusWidget", provider: ServerStatusProvider()) { entry in
            ServerStatusView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Server Status")
        .description("Shows whether your servers are reachable.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ServerStatusEntry: TimelineEntry {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let up: Bool
    }

    let date: Date
    let rows: [Row]
}

struct ServerStatusProvider: TimelineProvider {
    /// Probe at most this many servers — widget timeline budgets are tight.
    static let maxServers = 4

    func placeholder(in context: Context) -> ServerStatusEntry {
        ServerStatusEntry(date: Date(), rows: [
            .init(id: UUID(), name: "Mac mini", up: true),
            .init(id: UUID(), name: "homelab", up: false),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ServerStatusEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServerStatusEntry>) -> Void) {
        Task {
            let entry = await makeEntry()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)
                ?? entry.date.addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func makeEntry() async -> ServerStatusEntry {
        let servers = Array(ServerStore.sharedSnapshot().prefix(Self.maxServers))
        let rows = await withTaskGroup(of: ServerStatusEntry.Row.self) { group in
            for server in servers {
                group.addTask {
                    let up = await ServerReachability.isReachable(
                        host: server.host, port: server.port, timeout: 2
                    )
                    return ServerStatusEntry.Row(id: server.id, name: server.name, up: up)
                }
            }
            var collected: [UUID: ServerStatusEntry.Row] = [:]
            for await row in group {
                collected[row.id] = row
            }
            // Preserve the user's list order.
            return servers.compactMap { collected[$0.id] }
        }
        return ServerStatusEntry(date: Date(), rows: rows)
    }
}

struct ServerStatusView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ServerStatusEntry

    var body: some View {
        if entry.rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text("Add a server in a+Terminal")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        } else if family == .systemSmall, let first = entry.rows.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(first.up ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(first.up ? "UP" : "DOWN")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(first.up ? .green : .red)
                }
                Text(first.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.rows) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(row.up ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(row.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text(row.up ? "up" : "down")
                            .font(.caption)
                            .foregroundStyle(row.up ? .green : .red)
                    }
                }
                Spacer(minLength: 0)
                Text("Checked \(entry.date, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
