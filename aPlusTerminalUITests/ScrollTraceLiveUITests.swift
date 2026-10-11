import XCTest

/// PR A's acceptance through the real UI: a real finger drag on a tmux session
/// carried by meshyy lands in Settings → Diagnostics → Scroll trace as a record
/// naming its route and transport, and Share trace opens the share sheet.
///
/// Live QA only — skipped unless the runner passes `APLUSTERMINAL_LIVE_QA=1`
/// plus the seeded server and key (see TerminalLiveQAUITests). Needs meshyyd
/// and tmux on the seeded host. Screenshots are attached at every step.
final class ScrollTraceLiveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = env["APLUSTERMINAL_TEST_SERVER"]
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = env["APLUSTERMINAL_TEST_PRIVATE_KEY"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var seededServerName: String {
        let env = ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_SERVER"] ?? ""
        if let data = env.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["name"] as? String {
            return name
        }
        return "LiveQA"
    }

    private func type(_ text: String, settle: UInt32 = 2) {
        UIPasteboard.general.string = text
        app.buttons["Paste"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(settle)
    }

    /// Scrolls the Settings form until `element` is on screen.
    private func reveal(_ element: XCUIElement) {
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    func testARealSwipeOverMeshyyShowsUpInTheScrollTrace() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        // 1. meshyy on (it defaults off on a fresh install).
        tabBar.buttons["Settings"].tap()
        let meshyy = app.switches["Use meshyy when available (beta)"]
        reveal(meshyy)
        XCTAssertTrue(meshyy.waitForExistence(timeout: 5), "meshyy toggle not found")
        if (meshyy.value as? String) != "1" { meshyy.switches.firstMatch.tap() }
        XCTAssertEqual(meshyy.value as? String, "1", "could not turn meshyy on")

        // 2. Connect to the seeded server and start an isolated tmux with mouse on.
        tabBar.buttons.element(boundBy: 0).tap()
        let row = app.staticTexts[seededServerName]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded server row missing")
        row.tap()
        // A session left by an earlier run parks the survivor picker; this
        // test wants a fresh one.
        let fresh = app.buttons["New Session"]
        if fresh.waitForExistence(timeout: 6) { fresh.tap() }
        sleep(5)
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 2) { tutorial.tap(); sleep(1) }
        let socket = "aplus-ui-\(UUID().uuidString.prefix(6).lowercased())"
        type("PATH=/opt/homebrew/bin:$PATH tmux -L \(socket) -f /dev/null new -s t \\; set -g mouse on\n", settle: 3)
        type("seq 1 400\n", settle: 2)
        shot("01-tmux-mouse-on")

        // 3. A real finger drag down the middle of the terminal: wheel-up.
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(2)
        shot("02-after-swipe")
        // The outcome is on screen in 02-after-swipe: tmux's copy-mode
        // position "[n/m]" top-right (the grid is not in the AX tree, so the
        // screenshot is the evidence; the oracle suite asserts it).

        // 4. The record is in Settings → Diagnostics → Scroll trace. The
        // terminal is full-screen with the tab bar hidden; go back first.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "tab bar did not come back")
        tabBar.buttons["Settings"].tap()
        let link = app.buttons["settings.scrollTrace"]
        reveal(link)
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Scroll trace row missing")
        link.tap()
        XCTAssertTrue(app.switches["scrollTrace.toggle"].waitForExistence(timeout: 5))
        let record = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'sgrWheel' AND label CONTAINS 'meshyy'")
        ).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10),
                      "no sgrWheel-over-meshyy record in the trace screen")
        shot("03-scroll-trace-screen")

        // 5. Share trace opens the system share sheet with a file.
        let share = app.buttons["scrollTrace.share"]
        reveal(share)
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "share sheet did not open")
        shot("04-share-sheet")
        // Dismiss the sheet.
        app.swipeDown(velocity: .fast)
        sleep(1)

        // The isolated tmux server (`-L aplus-ui-*`) and the meshyy session are
        // left for the runner to clean up on the host: re-entering the tab from
        // here would type into tmux's copy mode.
    }
}
