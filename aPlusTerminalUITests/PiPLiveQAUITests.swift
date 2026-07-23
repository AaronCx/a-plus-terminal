import AVKit
import XCTest

/// On-device Pop-Out acceptance (the check build 31 was missing): PiP cannot
/// run in the simulator, and a PiP that silently fails to start is
/// indistinguishable from success in every off-device harness. This test
/// asserts the feature's real contract — with a pop-out up, a backgrounded
/// session stays CONNECTED past the ~20s wind-down that would otherwise
/// suspend it — so a silent PiP no-op turns the paused card into a failure.
///
/// Skipped unless `APLUSTERMINAL_LIVE_QA=1` (CI never runs it) and skipped
/// wherever PiP is unsupported (any simulator). Run against a real device:
///   xcodebuild test -project aPlusTerminal.xcodeproj -scheme aPlusTerminal \
///     -only-testing:aPlusTerminalUITests/PiPLiveQAUITests \
///     -destination 'platform=iOS,id=<udid>' \
///     TEST_RUNNER_APLUSTERMINAL_LIVE_QA=1 \
///     TEST_RUNNER_APLUSTERMINAL_TEST_SERVER='{"name":"LiveQA","host":"<mac-ip>","port":22,"username":"<user>"}' \
///     TEST_RUNNER_APLUSTERMINAL_TEST_PRIVATE_KEY='<base64 OpenSSH pem>' \
///     (+ DevLab manual-signing overrides; see the device-lab notes)
final class PiPLiveQAUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported(),
                          "PiP unsupported here (simulator) — this is a device test")
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = env["APLUSTERMINAL_TEST_SERVER"]
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = env["APLUSTERMINAL_TEST_PRIVATE_KEY"]
        app.launch()
    }

    private func shot(_ name: String) {
        // Full-screen capture (not app-scoped): the PiP window lives outside
        // the app's hierarchy and only XCUIScreen sees it.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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

    func testPopOutKeepsBackgroundedSessionConnectedPastWindDown() throws {
        // [1] Enable the beta toggle through the real Settings UI.
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["Pop-Out Sessions (beta)"]
        var swipes = 0
        while !toggle.isHittable && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Pop-Out settings toggle missing")
        if (toggle.value as? String) != "1" {
            toggle.tap()
        }
        shot("01-toggle-on")

        // [2] Connect the seeded session.
        app.tabBars.buttons["Terminal"].tap()
        let row = app.staticTexts[seededServerName]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded server row missing")
        row.tap()
        sleep(5)
        shot("02-connected")

        // [3] Start the pop-out from the toolbar (the sole sanctioned path).
        let popOut = app.buttons["Pop Out Session"]
        XCTAssertTrue(popOut.waitForExistence(timeout: 10),
                      "Pop Out button missing — connected session + toggle on should show it")
        popOut.tap()
        sleep(3)
        shot("03-pip-started")

        // [4] Background the app and stay away well past the ~20s point
        // where a PiP-less background stay suspends the session.
        XCUIDevice.shared.press(.home)
        sleep(30)
        shot("04-backgrounded-pip")

        // [5] Return. A working pop-out kept the process (and socket) alive:
        // the session must still be live — no "Session Paused" card.
        app.activate()
        sleep(3)
        shot("05-restored")
        XCTAssertFalse(app.staticTexts["Session Paused"].waitForExistence(timeout: 3),
                       "session was suspended during the background stay — PiP did not keep the process alive")
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 5),
                      "key accessory bar missing — session is not in the connected state")
    }
}
