import XCTest

/// What happens when a session dies while the user is *not looking at it*.
///
/// Aaron, on build 40: he popped a session out, locked the phone, the shell
/// expired, and tapping the PiP window brought him back to the server list with
/// the keyboard up — "as if I did come back into the session". A keyboard over
/// a list with no text field in it is not a cosmetic wart: it hides half the
/// screen and there is nothing to dismiss it with.
///
/// The pop-out is not what breaks this, it is only how he got back. The defect
/// is that `TerminalScreen` calls `dismiss()` when the session closes without
/// resigning the terminal view first, so UIKit restores the keyboard for a
/// first responder that no longer has a screen. This reproduces it without PiP
/// (which cannot run in a simulator at all) by having the shell exit on its own
/// while the app is in the background.
///
/// Skipped unless `APLUSTERMINAL_LIVE_QA=1` — CI never runs it. Settings are
/// UNPREFIXED; the scheme forwards them (see PreviewPortPickerUITests for why).
/// Erase the simulator first — `TestSeed` reuses a stale "uitest" key.
final class SessionExitWhileAwayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        continueAfterFailure = true

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

    /// Same pasteboard route the other live suites use — XCUITest's focus
    /// detection is unreliable against a custom `UIKeyInput` view.
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

    func testShellExitingWhileBackgroundedDoesNotStrandTheKeyboard() {
        let row = app.staticTexts[seededServerName]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "seeded server row \(seededServerName) missing")
        row.tap()
        sleep(4)
        // First keyboard on a fresh simulator shows the swipe-typing tutorial.
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 2) {
            tutorial.tap()
            sleep(1)
        }
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 15),
                      "never reached a connected session")
        shot("01-connected")

        // Without this the whole test can pass vacuously: if no keyboard was
        // ever up, "no keyboard at the end" proves nothing.
        XCTAssertEqual(app.keyboards.count, 1,
                       "no keyboard in the session — this test cannot observe the defect")

        // Arm the shell to die a few seconds from now, then leave. This is the
        // remote end expiring while the phone is locked, minus the lock.
        type("sleep 4; exit\n", settle: 1)
        XCUIDevice.shared.press(.home)
        // Long enough for the exit to land, short enough to stay inside the
        // background grace window — so the session is torn down by the remote
        // hangup, not by the wind-down suspending it.
        sleep(12)

        app.activate()
        sleep(4)
        shot("02-returned")

        // The session is gone, so we are back at the list…
        XCTAssertTrue(app.staticTexts["Servers"].waitForExistence(timeout: 15),
                      "did not land back on the server list after the shell exited")
        // …and nothing on this screen can consume a keystroke.
        XCTAssertEqual(
            app.keyboards.count, 0,
            "the keyboard is still up over the server list — there is no session to type into"
        )
    }
}
