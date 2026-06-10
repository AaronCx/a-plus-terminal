import ActivityKit
import Foundation

/// Live Activity lifecycle (§4.5): starts when the first session connects,
/// updates on add/remove/state change, and ends 5 minutes after the last
/// session closes (grace window for "I'm coming right back").
@MainActor
final class SessionActivityController {
    static let graceWindow: Duration = .seconds(300)

    private var activity: Activity<SessionActivityAttributes>?
    private var graceTask: Task<Void, Never>?

    func update(with summaries: [SessionActivityAttributes.SessionSummary]) {
        let state = SessionActivityAttributes.ContentState.make(from: summaries)

        if state.activeCount > 0 {
            graceTask?.cancel()
            graceTask = nil
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity {
                Task { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(
                    attributes: SessionActivityAttributes(),
                    content: content
                    // No pushType: local-only, zero-data posture.
                )
            }
        } else if activity != nil, graceTask == nil {
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.graceWindow)
                guard !Task.isCancelled else { return }
                await self?.endNow()
            }
        }
    }

    func endNow() async {
        graceTask?.cancel()
        graceTask = nil
        guard let activity else { return }
        self.activity = nil
        let finalState = SessionActivityAttributes.ContentState(sessions: [], activeCount: 0)
        await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
    }
}
