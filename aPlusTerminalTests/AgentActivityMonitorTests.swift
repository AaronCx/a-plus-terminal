import XCTest
@testable import aPlusTerminal

@MainActor
final class AgentActivityMonitorTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testSilentBeforeAgentMarker() {
        let monitor = AgentActivityMonitor(quietInterval: 0.05)
        monitor.observe(bytes(String(repeating: "x", count: 5000)))
        XCTAssertEqual(monitor.status, .none, "no marker yet — stream volume alone must not trigger")
    }

    func testMarkerPlusBurstMeansWorking() {
        let monitor = AgentActivityMonitor(quietInterval: 5)
        monitor.observe(bytes("Welcome to Claude Code v2.1\n"))
        monitor.observe(bytes(String(repeating: "output ", count: 50)))
        XCTAssertEqual(monitor.status, .working)
    }

    func testMarkerSplitAcrossChunksStillDetects() {
        let monitor = AgentActivityMonitor(quietInterval: 5)
        monitor.observe(bytes("...Clau"))
        monitor.observe(bytes("de Code session\n"))
        monitor.observe(bytes(String(repeating: "y", count: 300)))
        XCTAssertEqual(monitor.status, .working)
    }

    func testKeystrokeEchoesDoNotReadAsWorking() {
        let monitor = AgentActivityMonitor(quietInterval: 5, burstThreshold: 200)
        monitor.observe(bytes("esc to interrupt"))
        for _ in 0..<10 {
            monitor.observe(bytes("a"))  // user typing a reply
        }
        XCTAssertEqual(monitor.status, .none, "small echoes must stay below the burst threshold")
    }

    func testQuietAfterWorkingMeansWaiting() async {
        let monitor = AgentActivityMonitor(quietInterval: 0.1)
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
        let monitor = AgentActivityMonitor(quietInterval: 0.1)
        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting)

        monitor.observe(bytes(String(repeating: "b", count: 300)))
        XCTAssertEqual(monitor.status, .working)
    }

    func testResetClearsEverything() {
        let monitor = AgentActivityMonitor(quietInterval: 5)
        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        XCTAssertEqual(monitor.status, .working)
        monitor.reset()
        XCTAssertEqual(monitor.status, .none)
        monitor.observe(bytes(String(repeating: "a", count: 5000)))
        XCTAssertEqual(monitor.status, .none, "marker gate must re-arm after reset")
    }
}
