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

    private var seededServerName: String {
        let env = ProcessInfo.processInfo.environment["ATERMINAL_TEST_SERVER"] ?? ""
        if let data = env.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["name"] as? String {
            return name
        }
        return "LiveQA"
    }

    private func openSession() {
        let row = app.staticTexts[seededServerName]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded server row \(seededServerName) missing")
        row.tap()
        // Connection + keyboard focus.
        sleep(4)
        // First keyboard on a fresh simulator shows the swipe-typing tutorial.
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 2) {
            tutorial.tap()
            sleep(1)
        }
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

    /// Compliance pin (App Review Guideline 3.1.2): the Supporter card must
    /// surface auto-renewal terms plus Privacy Policy and Terms of Use links
    /// at the point of purchase — reviewers reject subscription apps without
    /// this, so losing the footer is a release blocker, not a style change.
    func testSupporterDisclosureAndLegalLinks() {
        app.tabBars.buttons["Settings"].tap()
        sleep(1)

        let disclosure = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'renew automatically'")).firstMatch
        if !disclosure.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5),
                      "auto-renewal disclosure missing from the Supporter card")

        XCTAssertTrue(app.buttons["Restore Purchases"].exists,
                      "Restore Purchases button missing from the Supporter card")

        let hasPrivacyLink = app.links["Privacy Policy"].exists
            || disclosure.label.contains("Privacy Policy")
        let hasTermsLink = app.links["Terms of Use (EULA)"].exists
            || disclosure.label.contains("Terms of Use")
        XCTAssertTrue(hasPrivacyLink, "Privacy Policy link missing near the purchase UI")
        XCTAssertTrue(hasTermsLink, "Terms of Use link missing near the purchase UI")
        shot("30-supporter-disclosure")
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

    /// Reproduces the Island session-switch flow end-to-end: the expanded
    /// Island rows send `aterminal://session/<uuid>`; `system.open` delivers
    /// the identical URL, so this verifies routing while another session's
    /// screen is frontmost — the exact case that used to bounce users back.
    func testDeepLinkSwitchesBetweenLiveSessions() {
        // Session A with a full-screen marker.
        openSession()
        type("clear; echo SCREEN-OF-SESSION-A\n")
        app.navigationBars.buttons.firstMatch.tap()  // back to the list
        sleep(2)

        // Session B — tap the server row specifically (its subtitle is
        // unambiguous; the session row is also labeled "LiveQA").
        app.staticTexts["acx@127.0.0.1"].tap()
        sleep(4)
        type("clear; echo SCREEN-OF-SESSION-B\n")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
        shot("20-two-sessions-list")

        // Collect the session UUIDs — multiple AX nodes can carry one row's
        // identifier, so dedupe before assuming row 0/1 are distinct sessions.
        let ids = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-'"))
        var uuids: [String] = []
        for index in 0..<ids.count {
            let raw = ids.element(boundBy: index).identifier.replacingOccurrences(of: "session-", with: "")
            if !uuids.contains(raw) { uuids.append(raw) }
        }
        XCTAssertGreaterThanOrEqual(uuids.count, 2, "expected two distinct sessions, got \(uuids)")
        let sessionA = uuids[0]
        let sessionB = uuids[1]

        // Enter session A (oldest row), then deep-link to B while inside A.
        ids.element(boundBy: 0).tap()
        sleep(3)
        shot("21-inside-session-A")
        XCUIDevice.shared.system.open(URL(string: "aterminal://session/\(sessionB)")!)
        sleep(4)
        shot("22-after-deeplink-should-be-B")

        // And back to A the same way.
        XCUIDevice.shared.system.open(URL(string: "aterminal://session/\(sessionA)")!)
        sleep(4)
        shot("23-after-deeplink-back-to-A")
    }

    /// App Store screenshot capture — curated scenes at the device's native
    /// resolution. Run on an iPhone Pro Max-class simulator with the status
    /// bar overridden. Gated separately so normal live QA doesn't pay for it.
    func testAppStoreScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATERMINAL_SCREENSHOTS"] == "1")
        openSession()

        // Scene: terminal + keyboard + accessory bar (C-b visible)
        type("clear\n")
        shot("shot-05-keyboard")

        // Scene: tmux running Claude Code's CLI (the hero)
        type("tmux kill-session -t shots 2>/dev/null; tmux new -s shots\n", settle: 4)
        type("export PATH=$PATH:$HOME/.local/bin; clear; claude --help\n", settle: 5)
        shot("shot-01-hero-tmux-claude")

        // Scene: scrollable output
        type("clear; seq 1 40\n", settle: 3)
        shot("shot-02-scroll")
        type("tmux kill-session 2>/dev/null\n", settle: 2)

        // Scene: sessions + servers list
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
        shot("shot-03-list")

        // Scene: settings with the tip jar (StoreKit config loads products)
        app.buttons["Settings"].tap()
        sleep(4)
        shot("shot-04-settings")
    }

    func testTmuxTypingKeyboardCycleAndAppSwitch() {
        openSession()
        type("tmux kill-session -t liveqa 2>/dev/null; tmux new -s liveqa\n", settle: 4)
        shot("06-tmux-attached")
        type("echo TMUX-MARKER-BRAVO\n")
        shot("07-tmux-echo")

        // C-b prefix key: one tap + "c" must open a second tmux window.
        app.buttons["tmux prefix Control-B"].tap()
        sleep(1)
        type("c", settle: 3)
        shot("07b-tmux-new-window")

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
