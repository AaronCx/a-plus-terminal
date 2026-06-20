import XCTest
@testable import aPlusTerminal

@MainActor
final class AgentActivityMonitorTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private let claudeCode = AgentProfile(
        id: "claude-code", displayName: "Claude Code",
        detectionMarkers: ["claude code", "esc to interrupt"], attachTemplate: "{path} ")
    private let hermes = AgentProfile(
        id: "hermes", displayName: "Hermes", detectionMarkers: ["hermes"], attachTemplate: "{path} ")
    private let generic = AgentProfile(
        id: "generic", displayName: "Agent", detectionMarkers: [], attachTemplate: "{path} ")

    /// Marker-gated monitor (a specific agent selected — no generic fallback).
    private func gatedMonitor(quietInterval: TimeInterval = 5, burstThreshold: Int = 200) -> AgentActivityMonitor {
        AgentActivityMonitor(candidates: [claudeCode], quietInterval: quietInterval, burstThreshold: burstThreshold)
    }

    func testSilentBeforeAgentMarker() {
        let monitor = gatedMonitor(quietInterval: 0.05)
        monitor.observe(bytes(String(repeating: "x", count: 5000)))
        XCTAssertEqual(monitor.status, .none, "no marker yet — stream volume alone must not trigger")
        XCTAssertNil(monitor.detected)
    }

    func testMarkerPlusBurstMeansWorkingAndSetsDetected() {
        let monitor = gatedMonitor()
        monitor.observe(bytes("Welcome to Claude Code v2.1\n"))
        monitor.observe(bytes(String(repeating: "output ", count: 50)))
        XCTAssertEqual(monitor.status, .working)
        XCTAssertEqual(monitor.detected?.id, "claude-code")
    }

    func testMarkerSplitAcrossChunksStillDetects() {
        let monitor = gatedMonitor()
        monitor.observe(bytes("...Clau"))
        monitor.observe(bytes("de Code session\n"))
        monitor.observe(bytes(String(repeating: "y", count: 300)))
        XCTAssertEqual(monitor.status, .working)
    }

    func testKeystrokeEchoesDoNotReadAsWorking() {
        let monitor = gatedMonitor(burstThreshold: 200)
        monitor.observe(bytes("esc to interrupt"))
        for _ in 0..<10 {
            monitor.observe(bytes("a"))  // user typing a reply
        }
        XCTAssertEqual(monitor.status, .none, "small echoes must stay below the burst threshold")
    }

    func testQuietAfterWorkingMeansWaiting() async {
        let monitor = gatedMonitor(quietInterval: 0.1)
        var transitions: [AgentActivityMonitor.Status] = []
        monitor.onChange = { transitions.append(monitor.status) }

        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "stream", count: 100)))
        XCTAssertEqual(monitor.status, .working)

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting)
        XCTAssertEqual(transitions, [.working, .waiting])
    }

    func testNewBurstAfterWaitingReturnsToWorking() async {
        let monitor = gatedMonitor(quietInterval: 0.1)
        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting)

        monitor.observe(bytes(String(repeating: "b", count: 300)))
        XCTAssertEqual(monitor.status, .working)
    }

    func testResetClearsEverything() {
        let monitor = gatedMonitor()
        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        XCTAssertEqual(monitor.status, .working)
        XCTAssertEqual(monitor.detected?.id, "claude-code")
        monitor.reset()
        XCTAssertEqual(monitor.status, .none)
        XCTAssertNil(monitor.detected)
        monitor.observe(bytes(String(repeating: "a", count: 5000)))
        XCTAssertEqual(monitor.status, .none, "marker gate must re-arm after reset")
    }

    // MARK: - Auto mode (multiple candidates + generic fallback)

    func testAutoDetectsHermesByMarker() {
        let monitor = AgentActivityMonitor(candidates: [claudeCode, hermes, generic], burstThreshold: 200)
        monitor.observe(bytes("hermes --tui ready\n"))
        monitor.observe(bytes(String(repeating: "z", count: 300)))
        XCTAssertEqual(monitor.detected?.id, "hermes")
        XCTAssertEqual(monitor.status, .working)
    }

    func testGenericFallbackYieldsWorkingWithoutMarker() {
        // With a generic candidate, the heuristic runs immediately and reports
        // working on a burst, but detected stays nil (label → "Agent").
        let monitor = AgentActivityMonitor(candidates: [claudeCode, generic], burstThreshold: 200)
        monitor.observe(bytes(String(repeating: "q", count: 300)))
        XCTAssertEqual(monitor.status, .working)
        XCTAssertNil(monitor.detected)
    }

    func testEmptyCandidatesDisablesDetection() {
        let monitor = AgentActivityMonitor(candidates: [])
        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "a", count: 5000)))
        XCTAssertEqual(monitor.status, .none, "no candidates → detection disabled")
    }
}
