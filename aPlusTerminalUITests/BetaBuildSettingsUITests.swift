import XCTest

/// Mirror of `AppStoreBuildSettingsUITests` against the BETA app (MESHYY set):
/// the same form walk must find the meshyy toggle here. This is what makes the
/// App Store test's "found nothing" mean something — a walk that cannot see
/// the row would pass there for the wrong reason.
///
/// Needs no SSH and no environment, so it is not LIVE_QA-gated: CI runs it.
final class BetaBuildSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "system alert") { alert in
            for title in ["Allow", "Allow While Using App", "OK", "Don't Allow"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        app.launch()
    }

    func testSettingsShowsTheMeshyyToggle() throws {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab present at launch")
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings is open")

        let pages = try SettingsFormWalker(app: app).walk()

        let texts = Set(pages.flatMap(\.texts))
        XCTAssertTrue(texts.contains("settings.meshyyTransport"), "meshyy toggle not found by the walk")
        XCTAssertFalse(pages.flatMap(\.meshyyHits).isEmpty, "walk saw no meshyy text in the beta build")
        XCTAssertTrue(texts.contains("Third-Party Notices"), "walk never reached the bottom of the form")
    }
}
