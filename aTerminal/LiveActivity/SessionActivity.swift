import ActivityKit
import Foundation

/// Live Activity lifecycle (§4.5): starts when the first session connects,
/// updates on add/remove/state change, shows a zero state when the last
/// session closes, and lets the **system** dismiss it after the grace window.
///
/// Two lifecycle traps this must survive:
/// - The app gets suspended: an in-process grace timer never fires, so
///   dismissal is delegated to ActivityKit via `dismissalPolicy: .after`.
/// - The app relaunches (update, crash): the previous process's Activity
///   outlives it — adopt one survivor and end any extras, or the on-screen
///   Activity is an orphan nobody updates.
@MainActor
final class SessionActivityController {
    static let graceWindow: TimeInterval = 300
    /// Force-killing the app leaves the Activity orphaned with no way to end
    /// it (iOS gives no on-kill hook). Content older than this renders as
    /// stale in the widget instead of pretending sessions are still live.
    static let staleWindow: TimeInterval = 600

    private var activity: Activity<SessionActivityAttributes>?
    /// Last content pushed to ActivityKit — also the regression-test seam.
    private(set) var lastPushedState: SessionActivityAttributes.ContentState?

    init() {
        let survivors = Activity<SessionActivityAttributes>.activities
        activity = survivors.first
        for orphan in survivors.dropFirst() {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(with summaries: [SessionActivityAttributes.SessionSummary]) {
        let state = SessionActivityAttributes.ContentState.make(from: summaries)
        lastPushedState = state
        let content = ActivityContent(
            state: state,
            staleDate: Date(timeIntervalSinceNow: Self.staleWindow)
        )

        if state.activeCount > 0 {
            if let activity {
                Task { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                // Sweep anything still on screen (an ended-but-undismissed
                // zero state, an orphan from a previous launch) so exactly
                // one Activity exists.
                for stale in Activity<SessionActivityAttributes>.activities {
                    Task { await stale.end(nil, dismissalPolicy: .immediate) }
                }
                activity = try? Activity.request(
                    attributes: SessionActivityAttributes(),
                    content: content
                    // No pushType: local-only, zero-data posture.
                )
            }
        } else if let activity {
            // Show the truthful zero state during the grace window, then let
            // the system dismiss it — works even while the app is suspended.
            self.activity = nil
            Task {
                await activity.end(
                    content,
                    dismissalPolicy: .after(Date(timeIntervalSinceNow: Self.graceWindow))
                )
            }
        }
    }

    func endNow() async {
        activity = nil
        for current in Activity<SessionActivityAttributes>.activities {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }
}
