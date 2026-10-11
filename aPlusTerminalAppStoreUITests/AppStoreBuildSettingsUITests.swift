import XCTest

/// The App Store candidate's Settings has no meshyy anywhere (brief 1.0.4 §1).
///
/// Runs against `aPlusTerminalAppStore` — the target built WITHOUT the MESHYY
/// condition — so this is the shipped Settings screen, not a runtime switch.
/// The beta-side mirror (`BetaBuildSettingsUITests`) proves the same walk DOES
/// find the meshyy toggle when it is compiled in; without it a query that can
/// never see the row would pass here for the wrong reason.
///
/// Needs no SSH and no environment, so it is not LIVE_QA-gated: CI runs it.
final class AppStoreBuildSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A first-launch system alert (local network, notifications) must not
        // sit over the form. Interruption monitors fire on the next
        // interaction, which the tab tap and swipes below provide.
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

    func testSettingsHasNoMeshyyAnywhere() throws {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab present at launch")
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings is open")

        let pages = try SettingsFormWalker(app: app).walk()

        let hits = pages.flatMap(\.meshyyHits)
        XCTAssertTrue(hits.isEmpty, "meshyy in the App Store build's Settings: \(hits)")
        let connection = pages.flatMap(\.texts).filter {
            $0.caseInsensitiveCompare("Connection") == .orderedSame
        }
        XCTAssertTrue(connection.isEmpty, "the meshyy \"Connection\" section is present")
        XCTAssertFalse(app.descendants(matching: .any)["settings.meshyyTransport"].exists,
                       "the meshyy toggle is present")

        // Proof the walk covered the form: the rows either side of where the
        // meshyy section sits in the beta build, and the last row of all.
        let seen = Set(pages.flatMap(\.texts))
        for landmark in ["Capture console output", "Customize key bar", "Third-Party Notices"] {
            XCTAssertTrue(seen.contains(landmark), "walk never reached \"\(landmark)\"")
        }
    }
}
