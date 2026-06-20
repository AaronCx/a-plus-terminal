import XCTest
import ActivityKit
@testable import aPlusTerminal

final class SessionActivityContentStateTests: XCTestCase {
    private func summary(name: String, startedAt: Date, state: String = "connected") -> SessionActivityAttributes.SessionSummary {
        SessionActivityAttributes.SessionSummary(
            id: UUID(),
            name: name,
            host: "100.0.0.1",
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
}

@MainActor
final class SessionActivityControllerTests: XCTestCase {
    private func summary() -> SessionActivityAttributes.SessionSummary {
        SessionActivityAttributes.SessionSummary(
            id: UUID(), name: "mini", host: "100.0.0.1", state: "connected", startedAt: .now
        )
    }

    func testZeroSessionsPushesEmptyContent() {
        // Regression: closing the last session left the Island showing the
        // stale "1 session" state for the whole 5-minute grace window.
        let controller = SessionActivityController()
        controller.update(with: [summary()])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 1)

        controller.update(with: [])
        XCTAssertEqual(controller.lastPushedState?.activeCount, 0, "grace window must show zero sessions")
        XCTAssertEqual(controller.lastPushedState?.sessions.isEmpty, true)
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
            id: id, name: "runtime", host: "100.0.0.1", state: state, startedAt: .now,
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
            id: UUID(), name: "dup", host: "100.0.0.1", state: "connected",
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
                id: id, name: "race", host: "100.0.0.1", state: "connected",
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
            id: UUID(), name: "idle", host: "100.0.0.1", state: "connected",
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
}
