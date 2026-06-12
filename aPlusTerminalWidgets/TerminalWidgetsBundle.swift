import WidgetKit
import SwiftUI

@main
struct TerminalWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LauncherWidget()
        ServerStatusWidget()
        SessionLiveActivity()
    }
}

struct LauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Launcher", provider: LauncherProvider()) { _ in
            LauncherWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("a+Terminal")
        .description("Open a+Terminal.")
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
            Text("a+Terminal")
                .font(.headline)
        }
    }
}
