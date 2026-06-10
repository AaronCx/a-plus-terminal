import XCTest
@testable import Relay

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
        router.handle(URL.relaySession(id: id))
        XCTAssertEqual(router.targetSessionID, id)
    }

    func testRejectsForeignSchemesAndHosts() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "https://session/\(UUID().uuidString)")!)
        XCTAssertNil(router.targetSessionID)
        router.handle(URL(string: "relay://server/\(UUID().uuidString)")!)
        XCTAssertNil(router.targetSessionID)
        router.handle(URL(string: "relay://session/not-a-uuid")!)
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
}
