import ActivityKit
import Foundation

/// Shared between the app and the widget extension. Local-only Activity —
/// no push tokens, no remote updates (zero-data posture, §4.5).
struct SessionActivityAttributes: ActivityAttributes {
    struct SessionSummary: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        /// "connected" / "suspended" / "reconnecting" / "connecting"
        var state: String
        var startedAt: Date
        /// "working" / "waiting" when an agent is detected in the session's
        /// output, nil otherwise. Optional so payloads from older builds decode.
        var agentStatus: String?
        /// Detected agent's display name (e.g. "Claude Code"); nil → "Agent".
        /// Optional (default nil) so older payloads and call sites still work.
        var agentName: String? = nil

        var isConnected: Bool { state == "connected" }
        /// Paused-but-open: the socket was suspended (backgrounded past the
        /// iOS allowance, or a failed connect), but the app session is still
        /// open and reattachable — it renders as "Paused", never disappears.
        var isPaused: Bool { state == "suspended" }
        var agentLabel: String? {
            guard let agentStatus else { return nil }
            let who = agentName ?? "Agent"
            switch agentStatus {
            case "working": return "\(who): working…"
            case "waiting": return "\(who): waiting for input"
            default: return nil
            }
        }
        var agentIsWaiting: Bool { agentStatus == "waiting" }
    }

    struct ContentState: Codable, Hashable {
        /// Most recent first, capped at 3 for the expanded Island view.
        var sessions: [SessionSummary]
        /// Count of *open* sessions (connected, connecting, reconnecting, or
        /// paused) — everything except closed. Named "active" for payload
        /// compatibility with older builds.
        var activeCount: Int
        /// How many of the `activeCount` open sessions are paused, counted
        /// over ALL of them (not just the capped top 3). Optional so payloads
        /// from older builds decode.
        var pausedCount: Int? = nil

        /// Newest-first, top 3, with the totals preserved in `activeCount`
        /// and `pausedCount`.
        static func make(from summaries: [SessionSummary]) -> ContentState {
            let sorted = summaries.sorted { $0.startedAt > $1.startedAt }
            return ContentState(
                sessions: Array(sorted.prefix(3)),
                activeCount: summaries.count,
                pausedCount: summaries.filter(\.isPaused).count
            )
        }

        /// Every open session is paused — the shape the background suspend
        /// leaves behind. Drives the hours-long stale horizon on the final
        /// pre-suspension push (no process is left alive to refresh it) and
        /// the "paused" phrasing in the lock-screen header. False at zero
        /// sessions: that is the end path, not the paused path.
        var allPaused: Bool {
            activeCount > 0 && (pausedCount ?? 0) == activeCount
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
