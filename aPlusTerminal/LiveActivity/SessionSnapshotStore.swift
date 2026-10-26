import Foundation
import WidgetKit

/// Widget kind, declared here rather than in the widget target: the app calls
/// `WidgetCenter.reloadTimelines(ofKind:)` with it and the extension declares
/// its `StaticConfiguration` with it, and a typo in either would silently mean
/// the widget simply never refreshes. This file is compiled into both targets,
/// so there is one spelling.
let LiveSessionsWidgetKind = "LiveSessionsWidget"

/// The app's open sessions, mirrored into the App Group container so the
/// widget extension can render them.
///
/// A widget runs in its own process and can see none of the app's memory, so
/// "monitor my live sessions" needs the same trick `ServerStore` already uses
/// for the server list: write a small file the extension can read. The payload
/// is `SessionActivityAttributes.SessionSummary` — the type the Live Activity
/// already builds on every session change, already `Codable`, and already
/// compiled into the widget target. Nothing new has to be derived or kept in
/// sync; the widget shows exactly what the Dynamic Island shows.
///
/// Writes are best-effort and never throw into the caller: failing to update a
/// widget must never disturb a live SSH session.
enum SessionSnapshotStore {
    struct Snapshot: Codable {
        var sessions: [SessionActivityAttributes.SessionSummary]
        /// When the app last wrote this. The widget shows it, because a
        /// snapshot the app has not been able to refresh (suspended, killed)
        /// is stale by definition and saying so beats implying it is live.
        var updatedAt: Date

        static let empty = Snapshot(sessions: [], updatedAt: .distantPast)
    }

    static let fileName = "sessions.json"

    static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ServerStore.appGroupID)?
            .appendingPathComponent(fileName)
    }

    /// Called from the app whenever the session list or any session's state
    /// changes. Returns whether anything was written, for tests.
    @discardableResult
    static func write(_ sessions: [SessionActivityAttributes.SessionSummary],
                      at date: Date = Date()) -> Bool {
        guard let url = fileURL() else { return false }
        let snapshot = Snapshot(sessions: sessions, updatedAt: date)
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        // Atomic: the widget can read at any moment, and a half-written file
        // would decode to nothing and blank the widget.
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read-only, for the widget extension. Never throws — a missing or
    /// corrupt file is simply "no sessions".
    static func read() -> Snapshot {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Sessions worth showing, most recently started first.
    ///
    /// `.closed` never reaches here (the app filters it before writing), but a
    /// snapshot can outlive the app that wrote it: if the app was killed, its
    /// sessions are gone and the file still lists them. Anything older than
    /// this is treated as unreliable and reported as stale rather than shown
    /// as live.
    static let staleAfter: TimeInterval = 30 * 60

    static func isStale(_ snapshot: Snapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.updatedAt) > staleAfter
    }
}

/// What one row of the sessions widget shows, and where tapping it goes.
///
/// Lives beside the snapshot rather than in the widget target because the deep
/// links are domain logic, not presentation: they have to match the routes
/// `DeepLinkRouter` accepts, and getting one wrong sends every tap to the wrong
/// place. Here it compiles into the app too, so the tests can hold it against
/// the real router.
struct LiveSessionsEntry: TimelineEntry {
    struct Row: Identifiable, Hashable {
        enum Kind: Hashable {
            /// An open session in the app.
            case session(state: String, startedAt: Date, agent: String?)
            /// A saved server with no session open — tapping starts one.
            case idleServer
        }

        let id: UUID
        let name: String
        let kind: Kind

        var isSession: Bool {
            if case .session = kind { return true }
            return false
        }

        /// Where a tap goes. Both routes already exist in the app.
        var url: URL? {
            switch kind {
            case .session: return URL(string: "aplusterminal://session/\(id.uuidString)")
            case .idleServer: return URL(string: "aplusterminal://connect/\(id.uuidString)")
            }
        }
    }

    let date: Date
    let rows: [Row]
    /// The app has not refreshed the snapshot recently enough to trust it as
    /// live — see `SessionSnapshotStore.isStale`.
    let stale: Bool

    var sessionCount: Int { rows.filter(\.isSession).count }
}
