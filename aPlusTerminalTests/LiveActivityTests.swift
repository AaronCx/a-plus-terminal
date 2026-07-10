import XCTest
import ActivityKit
@testable import aPlusTerminal

final class SessionActivityContentStateTests: XCTestCase {
    private func summary(name: String, startedAt: Date, state: String = "connected") -> SessionActivityAttributes.SessionSummary {
        SessionActivityAttributes.SessionSummary(
            id: UUID(),
            name: name,
            state: state,
            startedAt: startedAt
        )
    }

    func testCapsAtThreeNewestFirstButCountsAll() {
        let now = Date()
        let summaries = (0..<5).map { offset in
            summary(name: "s\(offset)", startedAt: now.addingTimeInterval(Double(offset)))
        }
        let state = SessionActivityAttributes.ContentState.make(from: summaries)

        XCTAssertEqual(state.activeCount, 5)
        XCTAssertEqual(state.sessions.map(\.name), ["s4", "s3", "s2"], "expanded view shows the 3 most recent")
        XCTAssertEqual(state.mostRecentSessionID, state.sessions.first?.id)
    }

    func testEmptyState() {
        let state = SessionActivityAttributes.ContentState.make(from: [])
        XCTAssertEqual(state.activeCount, 0)
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertNil(state.mostRecentSessionID)
    }

    func testConnectedFlag() {
        XCTAssertTrue(summary(name: "a", startedAt: .now, state: "connected").isConnected)
        XCTAssertFalse(summary(name: "a", startedAt: .now, state: "suspended").isConnected)
    }

    func testPausedFlag() {
        XCTAssertTrue(summary(name: "a", startedAt: .now, state: "suspended").isPaused)
        for state in ["connected", "connecting", "reconnecting", "closed"] {
            XCTAssertFalse(summary(name: "a", startedAt: .now, state: state).isPaused)
        }
    }

    func testAllPausedTruthTable() {
        let paused = { self.summary(name: "p", startedAt: .now, state: "suspended") }
        let live = summary(name: "l", startedAt: .now, state: "connected")

        let allPaused = SessionActivityAttributes.ContentState.make(from: [paused(), paused()])
        XCTAssertEqual(allPaused.pausedCount, 2)
        XCTAssertTrue(allPaused.allPaused)

        let mixed = SessionActivityAttributes.ContentState.make(from: [paused(), live])
        XCTAssertEqual(mixed.pausedCount, 1)
        XCTAssertFalse(mixed.allPaused, "one live session keeps the content on the live stale horizon")

        let empty = SessionActivityAttributes.ContentState.make(from: [])
        XCTAssertFalse(empty.allPaused, "zero sessions is the end path, not the paused path")
    }

    func testPausedCountCoversAllSessionsNotJustTheCappedThree() {
        // The display list is capped at 3, but allPaused drives the stale
        // horizon and must reflect EVERY open session: an older-but-live
        // session outside the top 3 means the content is not all-paused.
        let now = Date()
        let oldestLive = summary(name: "live", startedAt: now.addingTimeInterval(-100), state: "connected")
        let newerPaused = (0..<3).map { offset in
            summary(name: "p\(offset)", startedAt: now.addingTimeInterval(Double(offset)), state: "suspended")
        }
        let state = SessionActivityAttributes.ContentState.make(from: newerPaused + [oldestLive])
        XCTAssertEqual(state.activeCount, 4)
        XCTAssertEqual(state.sessions.count, 3)
        XCTAssertTrue(state.sessions.allSatisfy(\.isPaused), "the 3 newest are the paused ones")
        XCTAssertEqual(state.pausedCount, 3)
        XCTAssertFalse(state.allPaused, "the live session outside the cap must still count")
    }
}

final class DeepLinkRouterTests: XCTestCase {
    func testValidSessionLink() {
        let router = DeepLinkRouter()
        let id = UUID()
        router.handle(URL.sessionDeepLink(id: id))
        XCTAssertEqual(router.targetSessionID, id)
    }

    func testRejectsForeignSchemesAndHosts() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "https://session/\(UUID().uuidString)")!)
        XCTAssertNil(router.targetSessionID)
        router.handle(URL(string: "aplusterminal://server/\(UUID().uuidString)")!)
        XCTAssertNil(router.targetSessionID)
        router.handle(URL(string: "aplusterminal://session/not-a-uuid")!)
        XCTAssertNil(router.targetSessionID)
    }

    func testConnectLinkRoutes() {
        let router = DeepLinkRouter()
        let id = UUID()
        router.handle(URL(string: "aplusterminal://connect/\(id.uuidString)")!)
        XCTAssertEqual(router.connectServerID, id)
        XCTAssertNil(router.targetSessionID, "connect must not masquerade as a session link")
    }

    func testConnectLinkRejectsGarbage() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "aplusterminal://connect/not-a-uuid")!)
        XCTAssertNil(router.connectServerID)
        router.handle(URL(string: "https://connect/\(UUID().uuidString)")!)
        XCTAssertNil(router.connectServerID)
    }

    func testRequestConnectSetsTarget() {
        let router = DeepLinkRouter()
        let id = UUID()
        router.requestConnect(toServer: id)
        XCTAssertEqual(router.connectServerID, id)
    }
}

@MainActor
final class SessionActivityControllerTests: XCTestCase {
    private func summary(id: UUID = UUID(), state: String = "connected") -> SessionActivityAttributes.SessionSummary {
        SessionActivityAttributes.SessionSummary(
            id: id, name: "mini", state: state, startedAt: .now
        )
    }

    func testZeroSessionsPushesEmptyContent() {
        // Regression: closing the last session left the Island showing the
        // stale "1 session" state for the whole 5-minute grace window.
        // Under the paused-sessions semantics this zero-state path is still
        // the one taken when the user closes the last session — only closed
        // sessions leave the summary.
        let controller = SessionActivityController()
        controller.update(with: [summary()])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 1)

        controller.update(with: [])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 0, "grace window must show zero sessions")
        XCTAssertEqual(controller.lastPushedState?.sessions.isEmpty, true)
    }

    /// Deliberate behavior change from PR #76: backgrounding past the iOS
    /// allowance suspends every socket, but the app sessions stay open and
    /// reattachable — the resulting push must carry them as *paused*, never
    /// the empty zero state that used to end the Activity ~60s in.
    func testSuspendingAllSessionsPushesPausedContentNotZeroState() {
        let controller = SessionActivityController()
        let id = UUID()
        controller.update(with: [summary(id: id, state: "connected")])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 1)

        // What finishGrace()'s refreshActivity produces after suspend().
        controller.update(with: [summary(id: id, state: "suspended")])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 1,
                       "a paused session still counts toward the Activity")
        XCTAssertEqual(controller.lastPushedState?.sessions.first?.isPaused, true)
        XCTAssertEqual(controller.lastPushedState?.allPaused, true)
        XCTAssertEqual(controller.lastPushedState?.sessions.isEmpty, false,
                       "the summary must never be empty while sessions are merely paused")
    }

    /// The final paused push happens right before iOS suspends the process —
    /// nothing runs afterwards to refresh the staleDate, so it must carry the
    /// hours-long `pausedStaleWindow` instead of the heartbeat-scale
    /// `staleWindow` used while anything is live.
    func testPausedPushCarriesLongStaleDateLivePushShort() {
        let controller = SessionActivityController()
        let id = UUID()

        controller.update(with: [summary(id: id, state: "connected")])
        guard let liveStale = controller.lastPushedStaleDate else {
            return XCTFail("live push must record a staleDate")
        }
        XCTAssertEqual(liveStale.timeIntervalSinceNow,
                       SessionActivityController.staleWindow, accuracy: 30,
                       "live content keeps the short heartbeat-backed horizon")

        controller.update(with: [summary(id: id, state: "suspended")])
        guard let pausedStale = controller.lastPushedStaleDate else {
            return XCTFail("paused push must record a staleDate")
        }
        XCTAssertEqual(pausedStale.timeIntervalSinceNow,
                       SessionActivityController.pausedStaleWindow, accuracy: 30,
                       "the pre-suspension paused push must carry the long horizon")
        XCTAssertGreaterThan(SessionActivityController.pausedStaleWindow,
                             SessionActivityController.staleWindow)
    }

    func testReviveAfterZeroPushesLiveContent() {
        // Regression: after hitting zero, new sessions never reached the
        // Island again (the controller kept talking to an ended Activity).
        let controller = SessionActivityController()
        controller.update(with: [summary()])
        controller.update(with: [])
        controller.update(with: [summary(), summary()])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 2, "new sessions must produce live content after a zero state")
    }

    func testFlushActivityUpdatesReturnsWithEmptyQueue() async {
        let controller = SessionActivityController()
        await controller.flushActivityUpdates() // must not hang
        XCTAssertEqual(controller.pushCount, 0)
    }

    /// The user-facing mode → ActivityKit request-style mapping (§4.5) —
    /// the platform pick-two each mode deliberately picks a side of.
    func testModeToStyleMapping() {
        XCTAssertEqual(SessionActivityController.style(for: .endOnClose), .transient,
                       "end-on-close rides the transient style: dies with the process (and on lock)")
        XCTAssertEqual(SessionActivityController.style(for: .persistThroughLock), .standard,
                       "persist-through-lock is the style-less request this app always made")
    }

    /// Flipping the mode with no live Activity must be a no-op: there is
    /// nothing to restyle, and the next request reads the new mode anyway.
    func testApplyModeChangeWithoutLiveActivityIsANoOp() async {
        let controller = SessionActivityController(mode: { .persistThroughLock })
        // Clean slate: init may have adopted a leftover Activity from an
        // earlier test — drop it so this is genuinely the "none live" case.
        await controller.endNow()
        controller.applyModeChange()
        XCTAssertNil(controller.trackedActivityID)
        XCTAssertEqual(controller.pushCount, 0)
        XCTAssertNil(controller.lastRequestedStyle, "no request may happen without live content")
    }
}

/// Regression coverage for the agent label leaking onto a session that is no
/// longer connected (the "Live Activity didn't update when the connection
/// closed" bug). The gating lives in `resolvedAgentStatus`; `SessionManager`
/// routes every summary through it.
final class ResolvedAgentStatusTests: XCTestCase {
    func testConnectedSessionKeepsAgentStatus() {
        XCTAssertEqual(
            SessionActivityAttributes.resolvedAgentStatus(sessionState: "connected", monitorStatus: "working"),
            "working"
        )
        XCTAssertEqual(
            SessionActivityAttributes.resolvedAgentStatus(sessionState: "connected", monitorStatus: "waiting"),
            "waiting"
        )
    }

    func testNonConnectedSessionDropsAgentStatus() {
        for state in ["reconnecting", "suspended", "connecting", "closed"] {
            XCTAssertNil(
                SessionActivityAttributes.resolvedAgentStatus(sessionState: state, monitorStatus: "working"),
                "\(state) must not surface a stale agent label"
            )
        }
    }

    func testNoDetectionStaysNil() {
        XCTAssertNil(
            SessionActivityAttributes.resolvedAgentStatus(sessionState: "connected", monitorStatus: nil)
        )
    }
}

/// Runtime integration coverage that exercises a **real ActivityKit Live
/// Activity in the simulator** (not just the pure helpers). Live Activities do
/// run in the iOS Simulator for locally-managed activities; only push updates
/// need a device, and a+Terminal's Activity is local-only. This drives the same
/// transition the patch-4 bug was about — a connected session showing the agent
/// "working", then the connection dropping — and asserts the stale label clears
/// on the actually-running Activity.
@MainActor
final class SessionActivityRuntimeTests: XCTestCase {
    /// Build a summary the way `SessionManager.refreshActivity` does: the agent
    /// label is routed through `resolvedAgentStatus`, so connection state gates it.
    private func summary(id: UUID, state: String, monitor: String?) -> SessionActivityAttributes.SessionSummary {
        SessionActivityAttributes.SessionSummary(
            id: id, name: "runtime", state: state, startedAt: .now,
            agentStatus: SessionActivityAttributes.resolvedAgentStatus(sessionState: state, monitorStatus: monitor),
            agentName: "Claude Code"
        )
    }

    /// Live Activity updates are dispatched async (`Task { await activity.update }`),
    /// so poll the running Activity's content until it reflects the change.
    private func waitForLiveState(
        timeout: TimeInterval = 5,
        _ predicate: @escaping (SessionActivityAttributes.ContentState) -> Bool
    ) async -> SessionActivityAttributes.ContentState? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let st = Activity<SessionActivityAttributes>.activities.first?.content.state, predicate(st) {
                return st
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return Activity<SessionActivityAttributes>.activities.first?.content.state
    }

    func testLiveActivityClearsAgentLabelOnDisconnect() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment — enable them to run this integration test"
        )

        let controller = SessionActivityController()
        await controller.endNow()  // clean slate (drop any orphan from a prior run)

        let sid = UUID()

        // 1. Connected session, agent "working" → a real Live Activity starts and
        //    shows the label.
        controller.update(with: [summary(id: sid, state: "connected", monitor: "working")])
        let started = await waitForLiveState { $0.sessions.first?.agentStatus == "working" }
        XCTAssertEqual(
            Activity<SessionActivityAttributes>.activities.count, 1,
            "a real Live Activity should be running in the simulator"
        )
        XCTAssertEqual(started?.sessions.first?.state, "connected")
        XCTAssertEqual(started?.sessions.first?.agentStatus, "working")
        XCTAssertEqual(started?.sessions.first?.agentLabel, "Claude Code: working…")

        // 2. The connection drops (foreground reconnect). Same session id, but
        //    state → reconnecting. The stale "working" label MUST clear on the
        //    live Activity — this is the patch-4 bug.
        controller.update(with: [summary(id: sid, state: "reconnecting", monitor: "working")])
        let dropped = await waitForLiveState { $0.sessions.first?.agentStatus == nil }
        XCTAssertEqual(dropped?.sessions.first?.state, "reconnecting")
        XCTAssertNil(
            dropped?.sessions.first?.agentStatus,
            "stale agent label must clear once the session is no longer connected"
        )
        XCTAssertNil(dropped?.sessions.first?.agentLabel)

        // 3. Reconnect succeeds and the agent is active again → label returns.
        controller.update(with: [summary(id: sid, state: "connected", monitor: "waiting")])
        let revived = await waitForLiveState { $0.sessions.first?.agentStatus == "waiting" }
        XCTAssertEqual(revived?.sessions.first?.agentLabel, "Claude Code: waiting for input")

        await controller.endNow()
        let cleared = await waitForLiveState(timeout: 3) { _ in false }
        _ = cleared  // best-effort; system may keep an ending activity briefly
        XCTAssertTrue(
            Activity<SessionActivityAttributes>.activities.isEmpty,
            "endNow() should immediately dismiss the Activity"
        )
    }

    /// Re-pushing byte-identical content must not call ActivityKit again —
    /// refreshActivity fires on every session/agent event, and burning the
    /// update budget on no-ops can throttle later real updates.
    func testIdenticalUpdatesAreCoalesced() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        let s = SessionActivityAttributes.SessionSummary(
            id: UUID(), name: "dup", state: "connected",
            startedAt: Date(timeIntervalSince1970: 1_000_000), agentStatus: "working"
        )
        controller.update(with: [s])
        let afterFirst = controller.pushCount
        XCTAssertGreaterThan(afterFirst, 0, "the first update should push")

        controller.update(with: [s])  // identical
        controller.update(with: [s])  // identical
        XCTAssertEqual(controller.pushCount, afterFirst,
                       "identical content must not be re-pushed to ActivityKit")

        await controller.endNow()
    }

    /// A rapid burst of distinct states must leave the Activity on the LAST
    /// one. Before serialization, unordered Tasks could land it on an earlier
    /// value (the stall/stale-content bug).
    func testRapidUpdatesConvergeToLatestState() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        let id = UUID()
        let started = Date(timeIntervalSince1970: 2_000_000)
        func summ(_ agent: String?) -> SessionActivityAttributes.SessionSummary {
            SessionActivityAttributes.SessionSummary(
                id: id, name: "race", state: "connected",
                startedAt: started, agentStatus: agent
            )
        }

        controller.update(with: [summ("working")])
        controller.update(with: [summ(nil)])
        controller.update(with: [summ("working")])
        controller.update(with: [summ("waiting")])  // last write wins

        let final = await waitForLiveState { $0.sessions.first?.agentStatus == "waiting" }
        XCTAssertEqual(final?.sessions.first?.agentStatus, "waiting",
                       "serialized updates must converge to the latest state, never an earlier one")

        await controller.endNow()
    }

    /// A connected-but-idle session (no further state/agent events) must not
    /// slide past the stale window: the heartbeat re-pushes current content with
    /// a fresh staleDate. When the Activity ends, the heartbeat must stop.
    func testHeartbeatKeepsIdleActivityFresh() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController(heartbeatInterval: 0.2)
        await controller.endNow()

        let s = SessionActivityAttributes.SessionSummary(
            id: UUID(), name: "idle", state: "connected",
            startedAt: Date(timeIntervalSince1970: 3_000_000), agentStatus: nil
        )
        controller.update(with: [s])  // starts the Activity + heartbeat
        let pushesAfterStart = controller.pushCount
        let staleAfterStart = Activity<SessionActivityAttributes>.activities.first?.content.staleDate

        // No further update(with:) calls — only the heartbeat should fire.
        try await Task.sleep(nanoseconds: 700_000_000)  // ~3 heartbeat ticks
        XCTAssertGreaterThan(controller.pushCount, pushesAfterStart,
                             "heartbeat must re-push to keep an idle Activity alive")
        let staleNow = Activity<SessionActivityAttributes>.activities.first?.content.staleDate
        if let a = staleAfterStart, let b = staleNow {
            XCTAssertGreaterThan(b, a, "heartbeat must advance the staleDate")
        }

        // Once the Activity ends, the heartbeat must stop firing.
        await controller.endNow()
        let pushesAfterEnd = controller.pushCount
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(controller.pushCount, pushesAfterEnd,
                       "heartbeat must stop after the Activity ends")
    }

    /// True once the (sole) Activity has been ended — either it left
    /// `Activity.activities` (dismissed) or its state moved past `.active`.
    /// An `end(..., dismissalPolicy: .after(grace))` keeps it on screen for
    /// the grace window, so "ended but still listed" must count.
    private func waitUntilEndedOrGone(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard let first = Activity<SessionActivityAttributes>.activities.first else { return true }
            if first.activityState != .active { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return false
    }

    /// Deliberate behavior change from PR #76: the background grace suspend
    /// used to empty the summary and take the end() path, killing the
    /// Activity ~60s after backgrounding while the in-app session lived on as
    /// a reattachable paused card. Suspending must now keep the real Activity
    /// alive, flagged paused, with the hours-long stale horizon — this is the
    /// exact push finishGrace() flushes before the process is suspended.
    func testSuspendKeepsRealActivityAlivePausedWithLongStaleDate() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        let sid = UUID()
        controller.update(with: [summary(id: sid, state: "connected", monitor: nil)])
        _ = await waitForLiveState { $0.sessions.first?.state == "connected" }
        XCTAssertEqual(Activity<SessionActivityAttributes>.activities.count, 1)

        // finishGrace(): suspend → refreshActivity → flush before suspension.
        controller.update(with: [summary(id: sid, state: "suspended", monitor: nil)])
        await controller.flushActivityUpdates()

        let paused = await waitForLiveState { $0.sessions.first?.state == "suspended" }
        XCTAssertEqual(paused?.activeCount, 1, "the paused session still counts")
        XCTAssertEqual(paused?.sessions.first?.isPaused, true)
        XCTAssertEqual(paused?.allPaused, true)
        XCTAssertEqual(
            Activity<SessionActivityAttributes>.activities.first?.activityState, .active,
            "suspending must NOT take the end() path — the app session is still open"
        )
        if let stale = Activity<SessionActivityAttributes>.activities.first?.content.staleDate {
            XCTAssertGreaterThan(
                stale.timeIntervalSinceNow, 3600,
                "the final pre-suspension push must carry an hours-long staleDate — nothing runs afterwards to refresh it"
            )
        } else {
            XCTFail("paused content must carry a staleDate")
        }

        await controller.endNow()
    }

    /// Closing the last session (the summary genuinely empties) must still
    /// take the zero-state end path with the system-grace dismissal.
    func testClosingLastSessionStillEndsActivity() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        controller.update(with: [summary(id: UUID(), state: "connected", monitor: nil)])
        _ = await waitForLiveState { $0.sessions.first?.state == "connected" }

        controller.update(with: [])  // user closed the last session
        await controller.flushActivityUpdates()
        XCTAssertEqual(controller.lastPushedState?.activeCount, 0)
        let ended = await waitUntilEndedOrGone()
        XCTAssertTrue(ended, "closing the last session must end the Activity (grace wind-down)")

        await controller.endNow()
    }

    /// Force-quit while suspended delivers no willTerminate, so the paused
    /// Activity outlives the process. The next launch must reconcile it: the
    /// fresh controller adopts the orphan, and the manager's launch-time zero
    /// push (no sessions exist yet in a new process) ends it.
    func testLaunchReconcileEndsAdoptedOrphanWithNoMatchingSessions() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        // "Previous process": leaves a paused-content Activity behind.
        let previous = SessionActivityController()
        await previous.endNow()
        previous.update(with: [summary(id: UUID(), state: "suspended", monitor: nil)])
        await previous.flushActivityUpdates()
        _ = await waitForLiveState { $0.sessions.first?.state == "suspended" }
        XCTAssertEqual(Activity<SessionActivityAttributes>.activities.count, 1)

        // "Fresh launch": SessionActivityController.init adopts the survivor;
        // SessionManager.init then pushes the empty session list.
        let relaunched = SessionActivityController()
        relaunched.update(with: [])
        await relaunched.flushActivityUpdates()
        XCTAssertEqual(relaunched.lastPushedState?.activeCount, 0)
        let ended = await waitUntilEndedOrGone()
        XCTAssertTrue(ended, "an adopted orphan with no matching sessions must be ended at launch")

        await relaunched.endNow()
    }

    /// Waits (ground truth only — never via the controller) until the given
    /// Activity has left `Activity.activities` or reached a terminal state.
    private func waitUntilExternallyEnded(id: String, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Activity<SessionActivityAttributes>.activities
                .contains(where: { $0.id == id && $0.activityState == .active }),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The system can end the Activity behind the app's back (user
    /// swipe-dismiss, Live Activity system cap). Before the fix nothing
    /// observed `activityStateUpdates`: the stale non-nil handle blocked
    /// `needsStart` forever, every refresh enqueued updates onto the dead
    /// Activity, and the card could only come back after a full app restart.
    func testExternalEndIsNoticedAndNextRefreshRestarts() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        let sid = UUID()
        let summaries = [summary(id: sid, state: "connected", monitor: nil)]
        controller.update(with: summaries)
        _ = await waitForLiveState { $0.activeCount == 1 }
        let original = try XCTUnwrap(Activity<SessionActivityAttributes>.activities.first)
        XCTAssertEqual(controller.trackedActivityID, original.id)

        // Simulate a system end: end via the Activity's OWN handle, exactly
        // what the controller experiences when the user swipe-dismisses.
        await original.end(nil, dismissalPolicy: .immediate)

        // The state-stream observer must notice and drop the dead handle.
        let deadline = Date().addingTimeInterval(10)
        while controller.trackedActivityID != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(controller.trackedActivityID,
                     "an externally-ended Activity must clear the controller's handle")

        // Identical content — needsStart must now fire and request a FRESH
        // Activity (the coalescing must not swallow the restart).
        controller.update(with: summaries)
        await controller.flushActivityUpdates()
        _ = await waitForLiveState { $0.activeCount == 1 }
        let revived = try XCTUnwrap(Activity<SessionActivityAttributes>.activities.first)
        XCTAssertNotEqual(revived.id, original.id, "recovery must request a new Activity")
        XCTAssertEqual(controller.trackedActivityID, revived.id)

        await controller.endNow()
    }

    /// An end that happens while the process is suspended reaches the state
    /// stream only on resume — recovery must not race it. The foreground
    /// reconcile checks ActivityKit's ground truth and drops a dead handle
    /// synchronously, so the refresh that follows re-requests deterministically.
    func testForegroundReconcileDropsDeadHandle() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        let sid = UUID()
        let summaries = [summary(id: sid, state: "connected", monitor: nil)]
        controller.update(with: summaries)
        _ = await waitForLiveState { $0.activeCount == 1 }
        let original = try XCTUnwrap(Activity<SessionActivityAttributes>.activities.first)

        await original.end(nil, dismissalPolicy: .immediate)
        // Wait on ActivityKit's ground truth only — this test must hold even
        // when the stream observer hasn't fired yet (the suspended case).
        await waitUntilExternallyEnded(id: original.id)

        // The reconcile entry (what appWillEnterForeground calls first) must
        // leave the handle dropped by the time it returns.
        controller.reconcileExternalEnd()
        XCTAssertNil(controller.trackedActivityID,
                     "reconcile must drop a handle whose Activity the system ended")

        // What the foreground refresh then does: same sessions, needsStart
        // path, fresh Activity.
        controller.update(with: summaries)
        await controller.flushActivityUpdates()
        _ = await waitForLiveState { $0.activeCount == 1 }
        let revived = try XCTUnwrap(Activity<SessionActivityAttributes>.activities.first)
        XCTAssertNotEqual(revived.id, original.id, "the reconciled refresh must start a new Activity")
        XCTAssertEqual(controller.trackedActivityID, revived.id)

        await controller.endNow()
    }

    /// Two sequential Activities through one controller: requesting the
    /// second must replace the first's observer. Ending the OLD activity
    /// after the new one started must never clear the NEW handle — a leaked
    /// observer nil-ing the current handle would silently kill the successor
    /// card on the next coalesced refresh.
    func testObserverSwapsCleanlyAcrossSequentialActivities() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        let sid = UUID()
        let summaries = [summary(id: sid, state: "connected", monitor: nil)]
        controller.update(with: summaries)
        _ = await waitForLiveState { $0.activeCount == 1 }
        let first = try XCTUnwrap(Activity<SessionActivityAttributes>.activities.first)

        // Close the last session (grace wind-down on the first Activity),
        // then a new session arrives: the controller requests a SECOND
        // Activity while the first is still winding down.
        controller.update(with: [])
        controller.update(with: summaries)
        let secondID = try XCTUnwrap(controller.trackedActivityID)
        XCTAssertNotEqual(secondID, first.id, "a fresh Activity must have been requested")
        await controller.flushActivityUpdates()

        // The first Activity ends (wind-down, sweep, and this explicit
        // external end all deliver terminal states around now). None of them
        // may touch the new handle.
        await first.end(nil, dismissalPolicy: .immediate)
        try? await Task.sleep(nanoseconds: 700_000_000)  // room for a stray observer to misfire
        XCTAssertEqual(controller.trackedActivityID, secondID,
                       "ending the old Activity must not clear the new handle")
        XCTAssertTrue(Activity<SessionActivityAttributes>.activities.contains { $0.id == secondID },
                      "the new Activity must still be running")

        await controller.endNow()
    }

    /// A bare controller (no mode injected) must behave like a fresh install:
    /// the default mode is endOnClose, so the request carries `.transient`.
    func testDefaultModeRequestsTransientStyle() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController()
        await controller.endNow()

        controller.update(with: [summary(id: UUID(), state: "connected", monitor: nil)])
        _ = await waitForLiveState { $0.activeCount == 1 }
        XCTAssertNotNil(controller.trackedActivityID, "the request must have started an Activity")
        XCTAssertEqual(controller.lastRequestedStyle, .transient,
                       "the default endOnClose mode maps to the transient style")

        await controller.endNow()
    }

    /// persistThroughLock must produce the style-less (.standard) request —
    /// exactly what this app shipped before the mode existed.
    func testPersistThroughLockRequestsStandardStyle() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        let controller = SessionActivityController(mode: { .persistThroughLock })
        await controller.endNow()

        controller.update(with: [summary(id: UUID(), state: "connected", monitor: nil)])
        _ = await waitForLiveState { $0.activeCount == 1 }
        XCTAssertNotNil(controller.trackedActivityID, "the request must have started an Activity")
        XCTAssertEqual(controller.lastRequestedStyle, .standard,
                       "persistThroughLock maps to the standard (style-less) request")

        await controller.endNow()
    }

    /// Flipping the mode in Settings while an Activity is live must restyle it
    /// in place: end the current Activity (.immediate) and re-request a fresh
    /// one in the new style with the SAME content — ActivityKit offers no way
    /// to change a running Activity's style.
    func testModeToggleEndsAndRerequestsWithPreservedContent() async throws {
        try XCTSkipUnless(
            ActivityAuthorizationInfo().areActivitiesEnabled,
            "Live Activities are not enabled in this simulator environment"
        )
        var mode = LiveActivityMode.persistThroughLock
        let controller = SessionActivityController(mode: { mode })
        await controller.endNow()

        let sid = UUID()
        controller.update(with: [summary(id: sid, state: "connected", monitor: "working")])
        _ = await waitForLiveState { $0.activeCount == 1 }
        let original = try XCTUnwrap(controller.trackedActivityID)
        XCTAssertEqual(controller.lastRequestedStyle, .standard)
        let contentBefore = try XCTUnwrap(controller.lastPushedState)

        // The Settings toggle: mode flips, then the manager restyles in place.
        mode = .endOnClose
        controller.applyModeChange()
        await controller.flushActivityUpdates()

        let replacement = try XCTUnwrap(controller.trackedActivityID,
                                        "the mode change must re-request, not just end")
        XCTAssertNotEqual(replacement, original, "a fresh Activity must replace the old one")
        XCTAssertEqual(controller.lastRequestedStyle, .transient,
                       "the re-request must carry the NEW mode's style")
        XCTAssertEqual(controller.lastPushedState, contentBefore,
                       "the restyle must preserve the content")
        await waitUntilExternallyEnded(id: original)
        XCTAssertFalse(
            Activity<SessionActivityAttributes>.activities.contains { $0.id == original && $0.activityState == .active },
            "the old-style Activity must be ended immediately"
        )
        let live = await waitForLiveState { $0.activeCount == 1 }
        XCTAssertEqual(live, contentBefore, "the replacement Activity must show the same content")

        await controller.endNow()
    }
}

final class SessionStateActivityTests: XCTestCase {
    /// Deliberate behavior change from PR #76 (product decision): the old
    /// semantics dropped `.suspended` from the Activity, so it wound down
    /// ~60s after backgrounding even though the in-app session was still open
    /// as a reattachable paused card. The Activity mirrors open app sessions,
    /// not live sockets — every state except `.closed` counts.
    func testEveryOpenStateCountsTowardActivity() {
        XCTAssertTrue(SessionState.connecting.representsOpenSession)
        XCTAssertTrue(SessionState.connected.representsOpenSession)
        XCTAssertTrue(SessionState.reconnecting.representsOpenSession)
        XCTAssertTrue(SessionState.suspended.representsOpenSession,
                      "a paused session is still open — it must keep the Activity alive")
        XCTAssertFalse(SessionState.closed.representsOpenSession,
                       "only closing a session removes it from the Activity")
    }
}
