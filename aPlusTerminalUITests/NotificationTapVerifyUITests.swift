import XCTest

/// Verifies the notification-tap crash fix: a tap on an agent notification
/// must foreground the app and leave it ALIVE. Before the fix, the delegate's
/// ObjC bridge fired UIKit's completion on the cooperative pool and the app
/// aborted ~2s after every tap.
///
/// The host side pushes the payload (simctl push) a few seconds after this
/// test backgrounds the app; the test waits for the banner on SpringBoard,
/// taps it, and asserts the app survives well past the old crash window.
final class NotificationTapVerifyUITests: XCTestCase {
    func testTappingAnAgentNotificationDoesNotCrash() throws {
        // Needs a HOST-SIDE pusher (simctl push in a loop) — meaningless in a
        // bare suite run, so it opts in via the runner environment:
        //   TEST_RUNNER_TAP_VERIFY_PUSHER=1 xcodebuild ... test
        // (TEST_RUNNER_ env reaches UI-test runners; it is app-hosted UNIT
        // tests it silently never reaches — see the repo's Xcode gotchas.)
        guard ProcessInfo.processInfo.environment["TAP_VERIFY_PUSHER"] == "1" else {
            throw XCTSkip("no host pusher — run with TEST_RUNNER_TAP_VERIFY_PUSHER=1 and push the payload from the host")
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.press(.home)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The banner arrives from the host's repeated pushes; match it by the
        // TITLE TEXT (banner container identifiers vary by iOS release).
        let banner = springboard.staticTexts["Claude Code needs you"].firstMatch
        let arrived = banner.waitForExistence(timeout: 90)
        XCTAssertTrue(arrived, "the push banner never appeared — host push failed?")
        banner.tap()

        // The app must come to the foreground and STAY alive across the
        // window in which the old bug aborted (~2s after tap).
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "the tap never foregrounded the app")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(app.state, .runningForeground,
                       "the app died within the old crash window after the tap")
    }
}
