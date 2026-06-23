import XCTest

/// Live rendering QA against a real SSH server (the build machine's sshd).
/// Skipped unless the runner passes `APLUSTERMINAL_LIVE_QA=1` — CI never runs
/// these. Screenshots are attached at every step so a human (or agent) can
/// inspect actual rendering, which unit tests can't see.
///
/// Run:
///   xcodebuild test -project aPlusTerminal.xcodeproj -scheme aPlusTerminal \
///     -only-testing:aPlusTerminalUITests \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     TEST_RUNNER_APLUSTERMINAL_LIVE_QA=1 \
///     TEST_RUNNER_APLUSTERMINAL_TEST_SERVER='{"name":"LiveQA","host":"127.0.0.1","port":22,"username":"<user>"}' \
///     TEST_RUNNER_APLUSTERMINAL_TEST_PRIVATE_KEY='<base64 OpenSSH pem>'
final class TerminalLiveQAUITests: XCTestCase {
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

    /// The server row's subtitle ("username@host"), derived from the seed so the
    /// test carries no hardcoded personal username.
    private var seededServerSubtitle: String {
        let env = ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_SERVER"] ?? ""
        if let data = env.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let user = obj["username"] as? String,
           let host = obj["host"] as? String {
            return "\(user)@\(host)"
        }
        return "user@127.0.0.1"
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

    /// Pins the key-management flow: generate from Manage Keys, land in the
    /// detail screen, reveal the private key. Losing reveal/export would
    /// regress a headline capability, so it's a release blocker.
    func testKeyManagementGenerateAndReveal() {
        app.tabBars.buttons["Settings"].tap()
        sleep(1)
        // The SSH Keys section sits below the fold on most devices.
        let manageKeys = app.staticTexts["Manage Keys"]
        var swipes = 0
        while !manageKeys.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(manageKeys.waitForExistence(timeout: 5), "Manage Keys row missing")
        manageKeys.tap()
        sleep(1)

        app.buttons["Add Key"].tap()
        app.buttons["Generate New Key"].tap()
        let nameField = app.textFields["Key name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "generate alert missing")
        nameField.tap()
        nameField.typeText("qa-reveal")
        app.buttons["Generate"].tap()
        sleep(1)

        let row = app.staticTexts["qa-reveal"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "generated key missing from list")
        row.tap()
        sleep(1)
        shot("40-key-detail")

        app.buttons["Reveal Private Key"].tap()
        let pem = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'BEGIN OPENSSH PRIVATE KEY'")).firstMatch
        XCTAssertTrue(pem.waitForExistence(timeout: 5), "revealed private key not shown")
        XCTAssertTrue(app.buttons["Save to Files"].exists, "Save to Files missing")
        shot("41-key-revealed")

        // Clean up so reruns don't accumulate keys.
        app.swipeUp()
        app.buttons["Delete Key"].tap()
        sleep(1)
    }

    /// Compliance pin (App Review Guideline 3.1.2): the Support screen is now
    /// consumable tips only — no auto-renewable subscription. It must surface a
    /// Privacy Policy link and make clear nothing renews, and must NOT show the
    /// subscription-era "Restore Purchases" / auto-renewal / Terms of Use UI
    /// that would imply an auto-renewable product is attached to this version.
    func testSupporterDisclosureAndLegalLinks() {
        app.tabBars.buttons["Settings"].tap()
        sleep(1)

        // Tips live behind the single Support row.
        let supportRow = app.staticTexts["Support a+Terminal"]
        XCTAssertTrue(supportRow.waitForExistence(timeout: 5),
                      "Support a+Terminal row missing from Settings")
        supportRow.tap()
        sleep(1)
        shot("29-support-screen")

        // The tips-only footer makes the no-renewal posture explicit.
        let footer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'nothing renews'")).firstMatch
        if !footer.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(footer.waitForExistence(timeout: 5),
                      "tips-only footer missing from the Support screen")

        let hasPrivacyLink = app.links["Privacy Policy"].exists
            || app.staticTexts["Privacy Policy"].exists
        XCTAssertTrue(hasPrivacyLink, "Privacy Policy link missing from the Support screen")

        // Subscription-era UI must be gone (Guideline 3.1.2(a)).
        XCTAssertFalse(app.buttons["Restore Purchases"].exists,
                       "Restore Purchases must not appear once the subscription is removed")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'renew automatically'")).firstMatch.exists,
                       "auto-renewal disclosure must not appear once the subscription is removed")
        XCTAssertFalse(app.links["Terms of Use (EULA)"].exists,
                       "Terms of Use (EULA) link is subscription-only and must not appear")
        shot("30-tips-only-disclosure")
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
    /// Island rows send `aplusterminal://session/<uuid>`; `system.open` delivers
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
        app.staticTexts[seededServerSubtitle].tap()
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
        XCUIDevice.shared.system.open(URL(string: "aplusterminal://session/\(sessionB)")!)
        sleep(4)
        shot("22-after-deeplink-should-be-B")

        // And back to A the same way.
        XCUIDevice.shared.system.open(URL(string: "aplusterminal://session/\(sessionA)")!)
        sleep(4)
        shot("23-after-deeplink-back-to-A")
    }

    /// App Store screenshot capture — curated scenes at the device's native
    /// resolution. Run on an iPhone Pro Max-class simulator with the status
    /// bar overridden. Gated separately so normal live QA doesn't pay for it.
    func testAppStoreScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APLUSTERMINAL_SCREENSHOTS"] == "1")
        openSession()

        // Hero: a real tmux session with a generic, colorful dev command —
        // brand-neutral (no third-party CLI), shows tmux + SSH on a phone.
        type("tmux kill-session -t shots 2>/dev/null; tmux new -s shots\n", settle: 4)
        // Repo dir is overridable so no personal path is baked into the repo;
        // falls back to the remote cwd (then `ls -la`) when unset.
        type("clear; git -C \"${APLUSTERMINAL_SHOT_REPO:-.}\" log --graph --oneline -16 --color=always 2>/dev/null || ls -la\n", settle: 4)
        shot("shot-01-hero")

        // Scrollable output
        type("clear; seq 1 80\n", settle: 3)
        shot("shot-02-scroll")

        // Clean terminal + accessory bar (paperclip attach, mic, keyboard)
        type("clear; echo 'a+Terminal — SSH + tmux + any CLI agent'\n", settle: 2)
        shot("shot-06-terminal")
        type("tmux kill-session -t shots 2>/dev/null\n", settle: 2)

        // Sessions + servers list
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
        shot("shot-03-list")

        // Settings — top: Support / Tip jar + privacy posture
        app.buttons["Settings"].tap()
        sleep(3)
        shot("shot-04-tipjar")

        // Settings — Agent & Multiplexer pickers (the build-13 agent-agnostic
        // feature). Scroll down to reveal the section.
        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(2)
        shot("shot-05-agentmux")
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
