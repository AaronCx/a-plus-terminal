import XCTest
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
