// Agent notifications are compiled out unless the app's AGENT_NOTIFY switch
// is on (project.yml); with them out there is nothing here to test.
#if AGENT_NOTIFY
import XCTest

/// Settings → Notifications → "Send test notification" really delivers, and
/// it shows even with the app in front (the banner is the whole point of a
/// test). Drives SpringBoard, so it runs with the live suites
/// (`APLUSTERMINAL_LIVE_QA=1`), not in CI.
final class NotificationSettingsUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APLUSTERMINAL_LIVE_QA"] == "1",
                          "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        continueAfterFailure = false
    }

    func testSendTestNotificationShowsABanner() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Settings"].tap()

        let send = app.buttons["sendTestNotification"]
        for _ in 0..<8 where !send.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no Send test notification row")
        XCTAssertTrue(app.staticTexts["Set up Claude Code"].exists || app.buttons["Set up Claude Code"].exists,
                      "the setup card is not reachable from Settings")
        send.tap()

        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
        let banner = springboard.staticTexts["Test notification"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "the test notification never showed while the app was in front")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "test-notification-banner"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
