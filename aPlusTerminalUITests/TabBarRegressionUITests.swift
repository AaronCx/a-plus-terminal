import XCTest

/// Regression: a deep link / App Intent consumed while the Settings tab is
/// frontmost must bring the Terminal tab forward — NOT mutate the background
/// tab's navigation, which applied .toolbar(.hidden, for: .tabBar) to the
/// shared bar underneath Settings and stranded the user (no tab bar, no way
/// out). RED on 1.0.1 (c0df060), GREEN after the selection-binding fix.
final class TabBarRegressionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled")
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = env["APLUSTERMINAL_TEST_SERVER"]
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = env["APLUSTERMINAL_TEST_PRIVATE_KEY"]
        // Fire the connect request ~2.5s after launch — enough time for the
        // test to move to the Settings tab first. Deep-link test only: the
        // push/pop stress test must run without a scheduled trigger mutating
        // navigation mid-loop.
        if name.contains("testConnectRequestWhileOnSettingsBringsTerminalForward") {
            app.launchEnvironment["APLUSTERMINAL_TEST_CONNECT_AFTER_MS"] = "2500"
        }
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testConnectRequestWhileOnSettingsBringsTerminalForward() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Settings"].waitForExistence(timeout: 5), "tab bar present at launch")

        tabBar.buttons["Settings"].tap()
        shot("01-on-settings-before-trigger")

        // The seeded connect request fires at ~2.5s. Post-fix contract:
        // selection switches to Terminal and the session screen is pushed.
        // Pre-fix (c0df060): the app stays on Settings and the tab bar
        // vanishes — this assertion is the reproduction.
        let sessionNav = app.navigationBars.matching(
            NSPredicate(format: "identifier != 'Settings'")
        ).firstMatch
        XCTAssertTrue(
            sessionNav.waitForExistence(timeout: 8),
            "connect request must bring the Terminal tab + session forward"
        )
        shot("02-after-trigger")

        // Pop back to the server list: the bar must restore (single-owner
        // visibility — also covers the pop-race half of the bug).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            tabBar.buttons["Settings"].waitForExistence(timeout: 4),
            "tab bar restored after popping the session"
        )
        shot("03-bar-restored-after-pop")

        // And Settings itself must still have the bar.
        tabBar.buttons["Settings"].tap()
        XCTAssertTrue(
            tabBar.buttons["Terminal"].isHittable,
            "tab bar visible and usable on the Settings tab"
        )
        shot("04-settings-with-bar")
    }

    /// Stress the pop-restore path (defect B) independently of deep links.
    func testTabBarSurvivesRepeatedPushPop() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Terminal"].waitForExistence(timeout: 5))
        let serverRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '@'")
        ).firstMatch
        try XCTSkipUnless(serverRow.waitForExistence(timeout: 5), "seeded server row not found")

        for pass in 1...5 {
            serverRow.tap()
            _ = app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 4)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(
                tabBar.buttons["Settings"].waitForExistence(timeout: 4),
                "tab bar restored after pop #\(pass)"
            )
        }
    }
}
