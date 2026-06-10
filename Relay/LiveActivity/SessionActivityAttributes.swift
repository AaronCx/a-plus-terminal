import ActivityKit
import Foundation

/// Shared between the app and the widget extension. Local-only Activity —
/// no push tokens, no remote updates (zero-data posture, §4.5).
struct SessionActivityAttributes: ActivityAttributes {
    struct SessionSummary: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var host: String
        /// "connected" / "suspended" / "reconnecting" / "connecting"
        var state: String
        var startedAt: Date

        var isConnected: Bool { state == "connected" }
    }

    struct ContentState: Codable, Hashable {
        /// Most recent first, capped at 3 for the expanded Island view.
        var sessions: [SessionSummary]
        var activeCount: Int

        /// Newest-first, top 3, with the total preserved in `activeCount`.
        static func make(from summaries: [SessionSummary]) -> ContentState {
            let sorted = summaries.sorted { $0.startedAt > $1.startedAt }
            return ContentState(sessions: Array(sorted.prefix(3)), activeCount: summaries.count)
        }

        var mostRecentSessionID: UUID? {
            sessions.first?.id
        }
    }
}

extension URL {
    /// relay://session/<uuid> deep link for a session (§4.5 tap targets).
    static func relaySession(id: UUID) -> URL {
        URL(string: "relay://session/\(id.uuidString)")!
    }
}
