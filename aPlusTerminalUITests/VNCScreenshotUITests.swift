import XCTest

/// App Store screenshot capture for the Monitor (VNC) feature, the companion
/// to `PreviewScreenshotUITests`. Same gating and same principle: it drives a
/// real monitor session against a real Screen Sharing host and photographs what
/// the app renders.
///
/// `TestSeed.applyVNCIfRequested` does the setup — it seeds the monitor server,
/// stores the password through the production `PasswordStore` (Keychain, as in
/// a real install), and auto-opens the session after a delay, so this test never
/// has to drive the add-a-monitor UI or type a credential into a field.
///
/// Run on a 6.7"/6.9"-class simulator:
///   xcodebuild test -project aPlusTerminal.xcodeproj -scheme aPlusTerminal \
///     -only-testing:aPlusTerminalUITests/VNCScreenshotUITests \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///     APLUSTERMINAL_LIVE_QA=1 APLUSTERMINAL_SCREENSHOTS=1 \
///     APLUSTERMINAL_TEST_VNC_SERVER='{"name":"Mac mini","host":"127.0.0.1","port":5900,"username":"<user>"}'
///
/// The Screen Sharing credential never travels through xcodebuild: every build
/// setting it is handed is echoed into the build log, command line and xcconfig
/// alike. The host copies the credential file into the app's own container
/// (`simctl get_app_container <udid> <bundle id> data` + /Documents) and only
/// the file NAME is passed here.
final class VNCScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled")
        try XCTSkipUnless(env["APLUSTERMINAL_SCREENSHOTS"] == "1", "screenshot capture disabled")
        let seed = env["APLUSTERMINAL_TEST_VNC_SERVER"] ?? ""
        try XCTSkipUnless(!seed.isEmpty, "no VNC host seeded")
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_VNC_SERVER"] = seed
        // A file NAME, never the credential itself — see TestSeed. The host
        // writes that file into the app's container before this runs.
        app.launchEnvironment["APLUSTERMINAL_TEST_VNC_PASSWORD_FILE"] =
            env["APLUSTERMINAL_TEST_VNC_PASSWORD_FILE"] ?? "vncqa-pass"
        // Open the monitor by itself once the app has settled.
        app.launchEnvironment["APLUSTERMINAL_TEST_VNC_AUTOOPEN_MS"] = "2500"
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureMonitorScreenshot() throws {
        // The monitor cover is up once its own toolbar appears. Waiting on a
        // real control rather than a fixed sleep means a failed connection
        // fails the test instead of quietly photographing "Connecting…".
        let enableControl = app.buttons["Enable Control"].firstMatch
        let popOut = app.buttons["Pop Out Monitor"].firstMatch
        let appeared = enableControl.waitForExistence(timeout: 60) || popOut.waitForExistence(timeout: 10)
        XCTAssertTrue(appeared, "monitor never opened — check the seeded host and password")

        // Let the first full frame arrive and the image settle before capturing.
        sleep(8)
        XCTAssertFalse(
            app.staticTexts["Connecting…"].exists,
            "still connecting — the capture would show a placeholder, not the desktop"
        )
        shot("vnc-monitor")
    }
}
