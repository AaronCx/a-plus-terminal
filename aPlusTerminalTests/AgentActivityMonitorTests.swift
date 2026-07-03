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

    /// An explicitly-chosen single agent (e.g. user picked "Claude Code").
    private func explicitMonitor(quietInterval: TimeInterval = 5, burstThreshold: Int = 200) -> AgentActivityMonitor {
        AgentActivityMonitor(candidates: [claudeCode], quietInterval: quietInterval, burstThreshold: burstThreshold)
    }

    /// Auto mode: every profile + generic fallback.
    private func autoMonitor(quietInterval: TimeInterval = 5, burstThreshold: Int = 200) -> AgentActivityMonitor {
        AgentActivityMonitor(candidates: [claudeCode, hermes, generic], quietInterval: quietInterval, burstThreshold: burstThreshold)
    }

    // MARK: - Explicit agent: status WITHOUT needing a marker (the tmux fix)

    func testExplicitAgentReportsWorkingOnBurstWithoutMarker() {
        // The regression: a specific agent selected + running inside tmux, where
        // the marker text is fragmented by redraw escapes and never matches as a
        // substring. Status must still fire on output, and the name is known up
        // front (no marker required).
        let monitor = explicitMonitor()
        XCTAssertEqual(monitor.detected?.id, "claude-code", "explicit pick names the agent immediately")
        monitor.observe(bytes(String(repeating: "x", count: 5000)))  // no marker present
        XCTAssertEqual(monitor.status, .working, "explicit agent must report status without a marker")
        XCTAssertEqual(monitor.detected?.id, "claude-code")
    }

    func testKeystrokeEchoesDoNotReadAsWorking() {
        let monitor = explicitMonitor(burstThreshold: 200)
        for _ in 0..<10 { monitor.observe(bytes("a")) }  // user typing a reply
        XCTAssertEqual(monitor.status, .none, "small echoes must stay below the burst threshold")
    }

    func testQuietAfterWorkingMeansWaiting() async {
        let monitor = explicitMonitor(quietInterval: 0.1)
        var transitions: [AgentActivityMonitor.Status] = []
        monitor.onChange = { transitions.append(monitor.status) }

        monitor.observe(bytes(String(repeating: "stream", count: 100)))
        XCTAssertEqual(monitor.status, .working)

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting)
        XCTAssertEqual(transitions, [.working, .waiting])
    }

    func testNewBurstAfterWaitingReturnsToWorking() async {
        let monitor = explicitMonitor(quietInterval: 0.1)
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting)

        monitor.observe(bytes(String(repeating: "b", count: 300)))
        XCTAssertEqual(monitor.status, .working)
    }

    func testResetReArmsExplicitAgent() {
        let monitor = explicitMonitor()
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        XCTAssertEqual(monitor.status, .working)
        monitor.reset()
        XCTAssertEqual(monitor.status, .none)
        XCTAssertEqual(monitor.detected?.id, "claude-code", "reset re-arms the explicit agent name")
        monitor.observe(bytes(String(repeating: "a", count: 300)))
        XCTAssertEqual(monitor.status, .working, "heuristic must re-arm after reset")
    }

    // MARK: - Auto mode (multiple candidates + generic fallback)

    func testAutoReportsWorkingBeforeAnyMarkerWithGenericName() {
        // Auto: status fires on a burst even with no marker yet; the name stays
        // generic (nil → "Agent") until a marker identifies the agent.
        let monitor = autoMonitor()
        monitor.observe(bytes(String(repeating: "q", count: 300)))
        XCTAssertEqual(monitor.status, .working)
        XCTAssertNil(monitor.detected)
    }

    func testAutoUpgradesNameOnMarker() {
        let monitor = autoMonitor()
        monitor.observe(bytes("hermes --tui ready\n"))
        monitor.observe(bytes(String(repeating: "z", count: 300)))
        XCTAssertEqual(monitor.detected?.id, "hermes")
        XCTAssertEqual(monitor.status, .working)
    }

    func testMarkerSplitAcrossChunksStillNamesAgent() {
        let monitor = autoMonitor()
        monitor.observe(bytes("...Clau"))
        monitor.observe(bytes("de Code session\n"))
        XCTAssertEqual(monitor.detected?.id, "claude-code", "markers split across reads still name the agent")
    }

    func testEmptyCandidatesDisablesDetection() {
        let monitor = AgentActivityMonitor(candidates: [])
        monitor.observe(bytes("Claude Code\n"))
        monitor.observe(bytes(String(repeating: "a", count: 5000)))
        XCTAssertEqual(monitor.status, .none, "no candidates → detection disabled")
    }

    // MARK: - Idle-prompt detection (connect-banner false positive fix)

    func testConnectBannerEndingAtPromptClearsStatus() async {
        let monitor = autoMonitor(quietInterval: 0.1)
        let banner = "Last login: Tue Jul  1 on ttys001\r\n"
            + String(repeating: "Welcome to the mini. ", count: 20)
            + "\u{1B}[1;32maaron@mac-mini\u{1B}[0m ~ % "
        monitor.observe(bytes(banner))
        XCTAssertEqual(monitor.status, .working, "banner burst trips the threshold first")

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .none, "an idle shell prompt is not an agent waiting for input")
    }

    func testBannerLatchedNameRevertsInAutoMode() async {
        let monitor = autoMonitor(quietInterval: 0.1)
        let banner = String(repeating: "x", count: 300)
            + " claude code was here \r\naaron@mac-mini ~ $ "
        monitor.observe(bytes(banner))
        XCTAssertEqual(monitor.detected?.id, "claude-code", "marker inside banner text latches")

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .none)
        XCTAssertNil(monitor.detected, "auto-latched name must un-latch at an idle prompt")
    }

    func testExplicitAgentKeepsNameButClearsStatusAtPrompt() async {
        let monitor = explicitMonitor(quietInterval: 0.1)
        monitor.observe(bytes(String(repeating: "x", count: 300) + "\r\nmini# "))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .none)
        XCTAssertEqual(monitor.detected?.id, "claude-code", "explicit pick keeps its name")
    }

    func testWaitingClearsWhenAgentExitsToPrompt() async {
        let monitor = explicitMonitor(quietInterval: 0.1)
        monitor.observe(bytes(String(repeating: "agent output ", count: 50)))
        XCTAssertEqual(monitor.status, .working)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting)

        // Agent exits; shell paints its prompt (small output, no new burst).
        monitor.observe(bytes("\r\naaron@mac-mini ~ % "))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .none, "a bare prompt after waiting clears the label")
    }

    func testAgentIdleFrameWithoutPromptStaysWaiting() async {
        let monitor = explicitMonitor(quietInterval: 0.1)
        monitor.observe(bytes(String(repeating: "tokens ", count: 50)
            + "\r\n│ ❯ type a message │\r\n╰────╯ esc to interrupt"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(monitor.status, .waiting, "an agent input box is not a shell prompt")
    }

    func testStripANSIRemovesCSIAndOSC() {
        XCTAssertEqual(
            AgentActivityMonitor.stripANSI("\u{1B}]0;title\u{07}hi \u{1B}[1;32mthere\u{1B}[0m"),
            "hi there")
    }

    func testEndsAtShellPromptTerminators() {
        XCTAssertTrue(AgentActivityMonitor.endsAtShellPrompt("aaron@mini ~ % "))
        XCTAssertTrue(AgentActivityMonitor.endsAtShellPrompt("mini:~ aaron$"))
        XCTAssertTrue(AgentActivityMonitor.endsAtShellPrompt("root@mini:/# \u{1B}[?2004h"))
        XCTAssertFalse(AgentActivityMonitor.endsAtShellPrompt("❯ "))
        XCTAssertFalse(AgentActivityMonitor.endsAtShellPrompt(""))
        XCTAssertFalse(AgentActivityMonitor.endsAtShellPrompt("done."))
    }
}
