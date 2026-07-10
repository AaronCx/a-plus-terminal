import ActivityKit
import Foundation
import UIKit

/// Live Activity lifecycle (§4.5): starts when the first session connects,
/// updates on add/remove/state change, and represents **open app sessions**,
/// not live sockets — a suspended session renders as "Paused" and keeps the
/// Activity alive. It ends only when the last session is *closed* (zero-state
/// grace wind-down), on foreground termination (willTerminate), or with the
/// death of the process itself: the Activity is requested `.transient` (see
/// `requestStyle`), so the system ends it when the app is killed — including
/// a force-quit while suspended, which delivers no willTerminate. The launch
/// reconcile (adopt one survivor, zero-push ends an orphan whose sessions no
/// longer exist) remains as a guard for restart/adopt edge cases.
///
/// Two lifecycle traps this must survive:
/// - The app gets suspended: an in-process grace timer never fires, so
///   dismissal is delegated to ActivityKit via `dismissalPolicy: .after`,
///   and the final paused push must carry an hours-long staleDate — no
///   process is left alive to refresh it.
/// - The app relaunches (update, crash): the previous process's Activity
///   outlives it — adopt one survivor and end any extras, or the on-screen
///   Activity is an orphan nobody updates.
@MainActor
final class SessionActivityController {
    static let graceWindow: TimeInterval = 300
    /// Every Activity is requested with `ActivityStyle.transient` (iOS 18
    /// API, available since this app targets iOS 26). This is the
    /// platform-native fix for the force-quit orphan: the product rule is
    /// "the Activity lives exactly as long as the app does" — force-quit
    /// kills the sessions, so the card must follow (DoorDash-style), with
    /// zero data leaving the device and no push infrastructure.
    ///
    /// Verified empirically in the iOS 26 simulator (real ActivityKit,
    /// local-only activities):
    /// - `.transient` + normal suspension → Activity SURVIVES (paused
    ///   sessions keep their card, as required);
    /// - `.transient` + process killed while suspended (the force-quit
    ///   case, where iOS delivers no `willTerminate`) → the system ENDS
    ///   the Activity itself — no orphan;
    /// - `.standard` + the same kill (control) → Activity survives as an
    ///   orphan, which is exactly the failure mode transient eliminates.
    ///
    /// Accepted trade-off: a system memory reclaim (jetsam) of the
    /// *suspended* app also counts as process death and ends the card.
    /// That is correct by the same rule — a dead process's sessions are
    /// dead, nothing can reattach them until the user relaunches — and it
    /// matches how pro apps behave. The staleDate + launch reconcile
    /// machinery below stays as a belt-and-braces guard for restart/adopt
    /// edge cases.
    static let requestStyle: ActivityStyle = .transient
    /// Force-killing the app leaves the Activity orphaned with no way to end
    /// it (iOS gives no on-kill hook). Content older than this renders as
    /// stale in the widget instead of pretending sessions are still live.
    /// Applies while at least one session is live — the heartbeat below keeps
    /// bumping the horizon for as long as the process runs.
    static let staleWindow: TimeInterval = 600
    /// Stale horizon for content whose open sessions are ALL paused. The
    /// final push before iOS suspends the process carries this: nothing runs
    /// afterwards to heartbeat the Activity, yet the paused sessions are
    /// genuinely open and reattachable for as long as the suspended app stays
    /// alive — a minutes-scale horizon would falsely mark them stale. Four
    /// hours balances that against the one case nothing can catch in the
    /// moment: a force-quit while suspended (iOS delivers no willTerminate to
    /// a suspended app), whose orphan renders stale after this window and is
    /// ended for real by the next launch's reconcile.
    static let pausedStaleWindow: TimeInterval = 4 * 60 * 60

    private var activity: Activity<SessionActivityAttributes>?
    /// Last content pushed to ActivityKit — also the regression-test seam.
    private(set) var lastPushedState: SessionActivityAttributes.ContentState?
    /// staleDate of the last content built for ActivityKit — test seam for
    /// the live-vs-paused stale-horizon choice (mirrors `lastPushedState`).
    private(set) var lastPushedStaleDate: Date?
    /// Count of mutations actually dispatched to ActivityKit. Test seam for the
    /// de-duplication below — identical content must not burn the update budget.
    private(set) var pushCount = 0
    /// Style the last successful `Activity.request` was made with. Test seam:
    /// ActivityKit exposes no readable `style` on a running `Activity`
    /// (verified against the iOS 26 SDK .swiftinterface — only the `request`
    /// overloads take it), so the runtime tests assert the request path here.
    private(set) var lastRequestedStyle: ActivityStyle?

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
    /// Retained so it can be deregistered; otherwise the block-based observer
    /// outlives the controller with no way to remove it.
    private var terminateObserver: NSObjectProtocol?

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
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            // Best-effort: the system gives ~5s on terminate. The 3s wait may
            // not always flush under IPC pressure, but a force-quit orphan is
            // also covered by the staleDate mechanism above.
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

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
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

        let content = makeContent(for: state)

        if state.activeCount > 0 {
            if let activity {
                pushCount += 1
                enqueue { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                // Sweep anything still on screen (an ended-but-undismissed
                // zero state, an orphan from a previous launch) so exactly one
                // Activity exists. The sweep enumerates only the *pre-existing*
                // activities, so the new request below is never in that set; the
                // request stays synchronous (not enqueued) so `activity` is set
                // immediately and a rapid second update can't double-request.
                for stale in Activity<SessionActivityAttributes>.activities {
                    let stale = stale
                    enqueue { await stale.end(nil, dismissalPolicy: .immediate) }
                }
                activity = try? Activity.request(
                    attributes: SessionActivityAttributes(),
                    content: content,
                    // No pushType: local-only, zero-data posture.
                    // Transient so the system ends the Activity when the
                    // process dies (force-quit while suspended included) —
                    // see the `requestStyle` doc for the verified matrix.
                    style: Self.requestStyle
                )
                // Only count a push that actually started an Activity — a failed
                // request (activities disabled, per-app limit) leaves activity nil.
                if activity != nil {
                    pushCount += 1
                    lastRequestedStyle = Self.requestStyle
                }
            }
        } else if let activity {
            // Zero open sessions: only the user closing the last session (or
            // the launch-time reconcile of an adopted orphan whose sessions
            // no longer exist) reaches here — suspended sessions still count
            // above. Show the truthful zero state during the grace window,
            // then let the system dismiss it — works even while suspended.
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

    /// Builds the content to push: live content gets the short `staleWindow`
    /// (the heartbeat keeps bumping it), all-paused content gets
    /// `pausedStaleWindow` — the process is about to be suspended and this
    /// push is the last one until foreground, so a short horizon would mark a
    /// genuinely open, reattachable session as stale within minutes.
    private func makeContent(
        for state: SessionActivityAttributes.ContentState
    ) -> ActivityContent<SessionActivityAttributes.ContentState> {
        let window = state.allPaused ? Self.pausedStaleWindow : Self.staleWindow
        let staleDate = Date(timeIntervalSinceNow: window)
        lastPushedStaleDate = staleDate
        return ActivityContent(state: state, staleDate: staleDate)
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
                let content = self.makeContent(for: state)
                self.pushCount += 1
                self.enqueue { await activity.update(content) }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Re-push the current content with a fresh staleDate without changing
    /// state. Called on foreground after a background freeze (where the
    /// heartbeat couldn't fire): `update(with:)` would coalesce away an
    /// unchanged session list and leave the stale horizon where it was.
    func refreshStaleHorizon() {
        guard let activity, let state = lastPushedState, state.activeCount > 0 else { return }
        let content = makeContent(for: state)
        pushCount += 1
        enqueue { await activity.update(content) }
    }

    /// Awaits every queued ActivityKit mutation. Called at the tail of the
    /// background grace window, after sessions are suspended: the final
    /// *paused* update enqueued by that suspend (paused summaries + the long
    /// `pausedStaleWindow` horizon) must be submitted while the process still
    /// has background time — once iOS suspends us nothing runs until
    /// foreground, and the Activity would keep claiming connected sessions
    /// whose sockets are gone. Safe to call with an empty queue.
    func flushActivityUpdates() async {
        await applyTask?.value
    }

    /// Test-only: immediate teardown for deterministic assertions. Runtime
    /// teardown goes through `update(with:)`'s graceful zero-state + system
    /// dismissal instead, so this is intentionally not wired to `closeAll()`.
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
