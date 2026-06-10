import XCTest

/// Live rendering QA against a real SSH server (the build machine's sshd).
/// Skipped unless the runner passes `ATERMINAL_LIVE_QA=1` — CI never runs
/// these. Screenshots are attached at every step so a human (or agent) can
/// inspect actual rendering, which unit tests can't see.
///
/// Run:
///   xcodebuild test -project aTerminal.xcodeproj -scheme aTerminal \
///     -only-testing:aTerminalUITests \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     TEST_RUNNER_ATERMINAL_LIVE_QA=1 \
///     TEST_RUNNER_ATERMINAL_TEST_SERVER='{"name":"LiveQA","host":"127.0.0.1","port":22,"username":"<user>"}' \
///     TEST_RUNNER_ATERMINAL_TEST_PRIVATE_KEY='<base64 OpenSSH pem>'
final class TerminalLiveQAUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ATERMINAL_LIVE_QA"] == "1", "live QA disabled (set ATERMINAL_LIVE_QA=1)")
        continueAfterFailure = true

        app = XCUIApplication()
        app.launchEnvironment["ATERMINAL_TEST_SERVER"] = env["ATERMINAL_TEST_SERVER"]
        app.launchEnvironment["ATERMINAL_TEST_PRIVATE_KEY"] = env["ATERMINAL_TEST_PRIVATE_KEY"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSession() {
        let row = app.staticTexts["LiveQA"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded server row missing")
        row.tap()
        // Connection + keyboard focus.
        sleep(4)
        shot("01-connected")
    }

    /// Injects input via the sim-shared pasteboard and the accessory bar's
    /// Paste button. XCUITest's keyboard-focus detection is unreliable for
    /// custom UIKeyInput views (the keyboard is visibly up while the AX
    /// snapshot claims nothing has focus), and this path exercises the same
    /// bridge → outbox → SSH → render pipeline as typed bytes.
    private func type(_ text: String, settle: UInt32 = 2) {
        UIPasteboard.general.string = text
        app.buttons["Paste"].tap()
        // First paste per install triggers the system "Allow Paste" alert.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
        sleep(settle)
    }

    func testPlainShellTypingAndBurst() {
        openSession()
        type("echo MARKER-ALPHA-12345\n")
        shot("02-echo")
        type("seq 1 30\n")
        shot("03-scroll-output")
        // Fast burst: any byte reordering shows up as a transposed command.
        type("echo the-quick-brown-fox-0123456789-jumps\n", settle: 3)
        shot("04-burst")
        type("printf 'COLS=%s ROWS=%s\\n' $(tput cols) $(tput lines)\n", settle: 3)
        shot("05-tput-size")
    }

    func testRefocusFirstKeystroke() {
        openSession()
        type("echo FOCUS-ONE\n")
        app.buttons["Toggle Keyboard"].tap()
        sleep(2)
        app.buttons["Toggle Keyboard"].tap()
        sleep(3)
        type("echo FOCUS-TWO-FIRSTCHAR\n", settle: 2)
        app.buttons["Toggle Keyboard"].tap()
        sleep(2)
        app.scrollViews.firstMatch.tap()
        sleep(3)
        type("echo FOCUS-THREE-FIRSTCHAR\n", settle: 2)
        shot("12-refocus-typing")
    }

    func testTmuxTypingKeyboardCycleAndAppSwitch() {
        openSession()
        type("tmux kill-session -t liveqa 2>/dev/null; tmux new -s liveqa\n", settle: 4)
        shot("06-tmux-attached")
        type("echo TMUX-MARKER-BRAVO\n")
        shot("07-tmux-echo")

        // Keyboard dismiss/show cycle — the resize path that broke rendering.
        app.buttons["Toggle Keyboard"].tap()
        sleep(3)
        shot("08-keyboard-dismissed")
        app.buttons["Toggle Keyboard"].tap()
        sleep(3)
        type("echo AFTER-KEYBOARD-CYCLE\n")
        shot("09-after-keyboard-cycle")

        // App switch: background then foreground.
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        sleep(5)
        shot("10-after-app-switch")
        type("echo AFTER-APP-SWITCH\n", settle: 3)
        shot("11-typed-after-switch")
        type("tmux kill-session 2>/dev/null\n", settle: 2)
    }
}
