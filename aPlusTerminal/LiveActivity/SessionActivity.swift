import ActivityKit
import Foundation
import UIKit

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
    /// Count of mutations actually dispatched to ActivityKit. Test seam for the
    /// de-duplication below — identical content must not burn the update budget.
    private(set) var pushCount = 0

    /// Serializes async ActivityKit mutations. `refreshActivity` fires from many
    /// sites in quick succession (state changes, agent transitions, open/close),
    /// and unstructured `Task`s do **not** preserve submission order — two rapid
    /// updates could otherwise apply out of order and strand the Live Activity on
    /// stale content (the same reorder hazard the terminal byte outbox fixes).
    /// Chaining each mutation behind the previous one guarantees FIFO ordering.
    private var applyTask: Task<Void, Never>?

    private func enqueue(_ op: @escaping () async -> Void) {
        let previous = applyTask
        applyTask = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    /// While the app is alive with active sessions, the current content is
    /// re-pushed on this cadence so a live-but-idle session never reaches
    /// `staleWindow` and renders as "stale". Must be < staleWindow. A force-quit
    /// app stops firing this (its tasks die with it), so the staleDate still
    /// elapses for genuine death — force-quit detection is preserved.
    private let heartbeatInterval: TimeInterval
    private var heartbeatTask: Task<Void, Never>?

    init(heartbeatInterval: TimeInterval = 240) {
        self.heartbeatInterval = heartbeatInterval
        let survivors = Activity<SessionActivityAttributes>.activities
        activity = survivors.first
        for orphan in survivors.dropFirst() {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }

        // Force-quit from the app switcher: a *suspended* app dies silently
        // (the stale treatment covers that), but an app that's foreground or
        // still inside the background grace task receives willTerminate —
        // end the Activity before the process goes away. The work runs on a
        // detached task (main is the thread being torn down) with a short
        // blocking wait, which is acceptable in a dying process.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                for activity in Activity<SessionActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
        }
    }

    func update(with summaries: [SessionActivityAttributes.SessionSummary]) {
        let state = SessionActivityAttributes.ContentState.make(from: summaries)

        // Coalesce no-ops: refreshActivity fires on every session/agent event,
        // many of which produce byte-identical content. Re-pushing the same
        // state wastes ActivityKit's update budget and can throttle later real
        // updates. Always fall through, though, when an Activity still needs to
        // be (re)started — otherwise a failed first request would never retry.
        let needsStart = state.activeCount > 0 && activity == nil
        if state == lastPushedState && !needsStart { return }
        lastPushedState = state

        let content = ActivityContent(
            state: state,
            staleDate: Date(timeIntervalSinceNow: Self.staleWindow)
        )

        if state.activeCount > 0 {
            if let activity {
                pushCount += 1
                enqueue { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                // Sweep anything still on screen (an ended-but-undismissed
                // zero state, an orphan from a previous launch) so exactly
                // one Activity exists.
                for stale in Activity<SessionActivityAttributes>.activities {
                    let stale = stale
                    enqueue { await stale.end(nil, dismissalPolicy: .immediate) }
                }
                activity = try? Activity.request(
                    attributes: SessionActivityAttributes(),
                    content: content
                    // No pushType: local-only, zero-data posture.
                )
                pushCount += 1
            }
        } else if let activity {
            // Show the truthful zero state during the grace window, then let
            // the system dismiss it — works even while the app is suspended.
            self.activity = nil
            pushCount += 1
            enqueue {
                await activity.end(
                    content,
                    dismissalPolicy: .after(Date(timeIntervalSinceNow: Self.graceWindow))
                )
            }
        }

        // Keep an idle-but-live Activity fresh; stop once there's nothing live.
        if self.activity != nil {
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
    }

    /// Re-push the current content on a cadence so a connected-but-idle session
    /// (no state/agent events) doesn't slide past `staleWindow` and render as
    /// stale. Bypasses the `update(with:)` coalescing on purpose — the intent is
    /// to bump the stale window, not to change state. Reset on every real push.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self,
                      let activity = self.activity,
                      let state = self.lastPushedState, state.activeCount > 0
                else { return }
                let content = ActivityContent(
                    state: state,
                    staleDate: Date(timeIntervalSinceNow: Self.staleWindow)
                )
                self.pushCount += 1
                self.enqueue { await activity.update(content) }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func endNow() async {
        // Drop any queued mutations so a late update can't resurrect the
        // Activity after we've torn it down.
        stopHeartbeat()
        applyTask?.cancel()
        applyTask = nil
        activity = nil
        for current in Activity<SessionActivityAttributes>.activities {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }
}
