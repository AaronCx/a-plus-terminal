import WidgetKit
import SwiftUI

@main
struct RelayWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RelayLauncherWidget()
        SessionLiveActivity()
    }
}

struct RelayLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RelayLauncher", provider: LauncherProvider()) { _ in
            LauncherWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Relay")
        .description("Open Relay.")
        .supportedFamilies([.systemSmall])
    }
}

struct LauncherEntry: TimelineEntry {
    let date: Date
}

struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .medium))
            Text("Relay")
                .font(.headline)
        }
    }
}
