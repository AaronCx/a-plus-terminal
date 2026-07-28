import XCTest

/// Live QA for the detected-ports picker's **tap target**.
///
/// Aaron, on build 40: "on this list page only clicking the numbers brings you
/// to the preview not the bar." `.buttonStyle(.plain)` sizes a button to its
/// label, and the label hugged its content, so a row that *rendered* full width
/// only responded to taps over the port number itself. Nothing in a screenshot
/// shows that, and no unit test of the view model can reach it — the only
/// honest check is to tap the empty space in a running app and see whether the
/// preview opens.
///
/// Skipped unless the runner passes `APLUSTERMINAL_LIVE_QA=1`, like the other
/// live QA suites here — CI never runs it. It needs an SSH host that has a dev
/// server listening on loopback, because the whole point is a real detected
/// port rendered by the real picker.
///
/// **Erase or uninstall first.** `TestSeed` reuses any previously imported key
/// named "uitest" rather than re-importing, so a simulator carrying a key from
/// an earlier run authenticates with the wrong one and this fails at "never
/// reached a connected session" — which looks like a product bug and isn't:
///   xcrun simctl erase 'iPhone 17 Pro'
///
/// Run (settings are UNPREFIXED — the scheme forwards them to the runner; the
/// `TEST_RUNNER_` prefix quoted in the older suites here does not reach a UI
/// test runner on Xcode 26):
///   xcodebuild test -project aPlusTerminal.xcodeproj -scheme aPlusTerminal \
///     -only-testing:aPlusTerminalUITests/PreviewPortPickerUITests \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     APLUSTERMINAL_LIVE_QA=1 \
///     APLUSTERMINAL_TEST_SERVER='{"name":"PreviewQA","host":"127.0.0.1","port":2222,"username":"<user>"}' \
///     APLUSTERMINAL_TEST_PRIVATE_KEY='<base64 OpenSSH pem>'
final class PreviewPortPickerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = env["APLUSTERMINAL_TEST_SERVER"]
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = env["APLUSTERMINAL_TEST_PRIVATE_KEY"]
        // Connect through the production deep-link path rather than driving the
        // server list, same as the other live suites.
        app.launchEnvironment["APLUSTERMINAL_TEST_CONNECT_AFTER_MS"] = "1500"
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The port rows, identified the way VoiceOver sees them.
    private var portRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open port'"))
    }

    func testTappingTheEmptySpaceOfAPortRowOpensThePreview() throws {
        // The Preview toolbar item only exists once the session is connected,
        // so waiting on it waits out the SSH handshake too.
        let previewButton = app.buttons["Preview Local Server"]
        XCTAssertTrue(
            previewButton.waitForExistence(timeout: 60),
            "never reached a connected session — check the seeded server and key"
        )
        previewButton.tap()

        let row = portRows.firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 60),
            "no listener was detected on the far end — start a dev server before running this"
        )
        shot("port picker")

        // Direct measurement of the defect: the row's hit frame against the
        // width it renders at. With the bug this was the width of "5173 node".
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(
            row.frame.width, window.frame.width * 0.8,
            "the row's tappable frame is far narrower than the row the user sees"
        )

        // And the behavioural half: tap the far right of the row, well past any
        // text. Deliberately in *window* coordinates rather than the row's own
        // normalized offset — an offset inside a shrunken button would land on
        // the text and pass while the bug was still there.
        let target = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.maxX - 30, dy: row.frame.midY))
        target.tap()

        // Reload only exists once a URL is bound, i.e. the tunnel came up and
        // the picker gave way to the web view.
        let reload = app.buttons["Reload Preview"]
        XCTAssertTrue(
            reload.waitForExistence(timeout: 45),
            "tapping the empty space on the row did not open the preview"
        )
        shot("preview opened from an edge tap")
    }
}

/// App Store screenshot capture for the Preview feature. Gated on
/// `APLUSTERMINAL_SCREENSHOTS=1` as well as live QA, so it never runs by
/// accident, and driven against a real SSH host with a real dev server —
/// a store screenshot has to be the app actually doing the thing.
///
/// Run on a 6.7"-class simulator (the store set is APP_IPHONE_67):
///   xcodebuild test ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///     APLUSTERMINAL_LIVE_QA=1 APLUSTERMINAL_SCREENSHOTS=1 \
///     APLUSTERMINAL_SHOT_PATH=/shot.html APLUSTERMINAL_TEST_SERVER=... APLUSTERMINAL_TEST_PRIVATE_KEY=...
final class PreviewScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled")
        try XCTSkipUnless(env["APLUSTERMINAL_SCREENSHOTS"] == "1", "screenshot capture disabled")
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = env["APLUSTERMINAL_TEST_SERVER"]
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = env["APLUSTERMINAL_TEST_PRIVATE_KEY"]
        app.launchEnvironment["APLUSTERMINAL_TEST_CONNECT_AFTER_MS"] = "1500"
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pasteboard route, as in the other live suites.
    private func type(_ text: String, settle: UInt32 = 2) {
        UIPasteboard.general.string = text
        app.buttons["Paste"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
        sleep(settle)
    }

    func testCapturePreviewScreenshot() throws {
        let port = ProcessInfo.processInfo.environment["APLUSTERMINAL_SHOT_PORT"] ?? "5173"
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 60), "never reached a connected session")

        // Print the dev server's URL the way a dev server does. This is not
        // decoration: the picker caps at 8 entries and this Mac has ~21
        // loopback listeners, so an unvouched port is evicted before it can be
        // shown. A scraped URL is what protects it — and it is the flow the
        // feature is built around anyway.
        type("clear; echo '  ➜  Local:   http://localhost:\(port)/'\n", settle: 3)

        let previewButton = app.buttons["Preview Local Server"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 60), "never reached a connected session")
        previewButton.tap()

        // Pick the dev server explicitly rather than "whatever is first" — the
        // machine has plenty of other listeners and the screenshot must show a
        // real page, not rapportd.
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Open port \(port)")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "dev server on \(port) was not detected")
        shot("preview-picker")
        row.tap()

        XCTAssertTrue(app.buttons["Reload Preview"].waitForExistence(timeout: 45), "preview never bound")
        // Let the page paint and the layout settle before capturing.
        sleep(6)
        shot("preview-page")
    }
}
