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
        /// "working" / "waiting" when a Claude-Code-style agent is detected
        /// in the session's output, nil otherwise. Optional so payloads from
        /// older builds keep decoding.
        var agentStatus: String?

        var isConnected: Bool { state == "connected" }
        var agentLabel: String? {
            switch agentStatus {
            case "working": return "Claude: working…"
            case "waiting": return "Claude: waiting for input"
            default: return nil
            }
        }
        var agentIsWaiting: Bool { agentStatus == "waiting" }
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

    /// Agent status to surface in the Live Activity. Only a *connected*
    /// session can show a live agent — a reconnecting / suspended / closed
    /// session must not keep displaying "Claude: working…" or "waiting for
    /// input", since the stream that produced that reading is gone.
    static func resolvedAgentStatus(sessionState: String, monitorStatus: String?) -> String? {
        sessionState == "connected" ? monitorStatus : nil
    }
}

extension URL {
    /// aplusterminal://session/<uuid> deep link for a session (§4.5 tap targets).
    static func sessionDeepLink(id: UUID) -> URL {
        URL(string: "aplusterminal://session/\(id.uuidString)")!
    }
}
