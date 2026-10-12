import XCTest

/// Agent notifications against a real Claude Code, over real SSH to the build
/// machine, inside tmux — the setup Aaron runs.
///
/// The report this pins: every time he left the app with an IDLE agent, a
/// "needs you" notification arrived. Leaving dismisses the keyboard, the pty
/// resizes, the TUI repaints (a burst, so "working"), goes quiet, and the
/// timing heuristic read the quiet as "waiting".
///
/// What the test reads: the DEBUG alert probe (`APLUSTERMINAL_TEST_ALERT_PROBE`),
/// a one-line file counting notifications actually handed to
/// UNUserNotificationCenter (the app and this runner share the host
/// filesystem in the simulator). The per-session floor is lowered to 0
/// (`APLUSTERMINAL_TEST_ALERT_FLOOR`) so a repeat is counted, never masked.
///
/// The terminal's text is not in the accessibility tree, so a relay script in
/// the tmux session mirrors the pane into `~/.aplus-notifqa/pane.txt` every
/// half second, and types what the runner drops into `keys.txt` with `tmux
/// send-keys`. Only the two commands that start tmux and the relay go
/// through the app's Paste button: the simulator's pasteboard is synced with
/// the Mac's, so with other simulators running a paste can carry someone
/// else's text (it did — mid-prompt), and the longer the app takes to go idle
/// the wider that window. Claude Code keeps the app from idling, so every
/// keystroke to it goes through the relay.
///
/// Skipped unless `APLUSTERMINAL_LIVE_QA=1` — CI never runs it. Settings are
/// UNPREFIXED; the scheme forwards them (see PreviewPortPickerUITests for why):
///   make test DEST='platform=iOS Simulator,id=<udid>' \
///     APLUSTERMINAL_LIVE_QA=1 \
///     APLUSTERMINAL_TEST_SERVER='{"name":"LiveQA","host":"127.0.0.1","port":22,"username":"<user>"}' \
///     APLUSTERMINAL_TEST_PRIVATE_KEY="$(base64 < ~/.ssh/aplus_probe)"
/// Erase the simulator first — `TestSeed` reuses a stale "uitest" key — and
/// make sure the software keyboard is used (hardware keyboard disconnected),
/// or backgrounding never resizes the pty and the test proves nothing.
final class AgentNotificationLiveUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private static let tmuxSession = "aplus104notif"
    private static let qaDir = ".aplus-notifqa"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = env["APLUSTERMINAL_TEST_SERVER"]
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = env["APLUSTERMINAL_TEST_PRIVATE_KEY"]
        // The QA directory lives in the host's home, outside any repo; the
        // probe file starts absent so a reading always comes from this run.
        try FileManager.default.createDirectory(atPath: qaPath, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: probePath)
        app.launchEnvironment["APLUSTERMINAL_TEST_ALERT_PROBE"] = "1"
        app.launchEnvironment["APLUSTERMINAL_TEST_ALERT_PROBE_FILE"] = probePath
        let floor = env["APLUSTERMINAL_TEST_ALERT_FLOOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        app.launchEnvironment["APLUSTERMINAL_TEST_ALERT_FLOOR"] = floor
        // Leaving hides the keyboard, as on a device (see the idle test).
        app.launchEnvironment["APLUSTERMINAL_TEST_HIDE_KEYBOARD_ON_LEAVE"] = "1"
        // Launch TWICE. On Xcode 26 a launch INTERMITTENTLY arrives with
        // none of launchEnvironment — seen on the first launch of a run,
        // alongside xcodebuild's "IDELaunchParametersSnapshot: no debugger
        // version", but not on every run. In one measured run a probe-only
        // test saw no APLUSTERMINAL_* variables in the first process and all
        // of them in the second. The probe file is removed again between
        // the launches, so the check below proves the process under test
        // got the environment — a file left by the first launch cannot
        // stand in for it.
        app.launch()
        app.terminate()
        try? FileManager.default.removeItem(atPath: probePath)
        app.launch()
        XCTAssertNoThrow(try probe(), "the app did not start its alert probe — launchEnvironment did not arrive")
    }

    override func tearDownWithError() throws {
        guard app != nil else { return }
        // Quit Claude Code and remove only this suite's tmux session; the
        // relay exits with it.
        if FileManager.default.fileExists(atPath: "\(qaPath)/pane.txt") {
            send(key: "C-c")
            send(key: "C-c")
            send(key: "KILL")
        }
    }

    // MARK: - Tests

    /// Twenty trips away from an idle Claude Code must produce zero
    /// notifications. Nothing is ever asked of the agent here: a fresh
    /// Claude Code with no answered turn never rings its idle bell, so any
    /// post is the app inventing a need.
    ///
    /// Every trip must resize the pty — the repaint is the whole bug. On a
    /// device leaving the app hides the keyboard; in the simulator it does
    /// not reliably (measured: only the first of 20 trips resized, and
    /// XCUIDevice rotation resized nothing at all). So the app is launched
    /// with `APLUSTERMINAL_TEST_HIDE_KEYBOARD_ON_LEAVE`: the session screen
    /// really dismisses the keyboard as the app goes inactive — the pty
    /// grows and the TUI repaints into the background, as on a device — and
    /// refocuses on return. (Tapping the accessory bar's toggle instead
    /// costs XCUITest's 60 s wait-for-idle per tap, which Claude Code never
    /// grants, and puts the resize a minute before leaving.) The probe is
    /// read while the app is away: a trip whose pty did not resize on the
    /// way out fails — it tested nothing.
    func testBackgroundingAnIdleAgentNeverNotifies() throws {
        try startIdleClaudeCode()
        let start = try probe()
        var timeline: [String] = []
        for trip in 1...20 {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                          "trip \(trip): the keyboard was not up to hide")
            let before = try probe()
            XCUIDevice.shared.press(.home)
            sleep(2)
            let away = try probe()
            XCTAssertGreaterThan(away.resizes, before.resizes,
                                 "trip \(trip): the pty never resized on the way out — this trip tested nothing (\(away.summary))")
            // 18 s away in all: longer than tmux's 15 s status refresh (the
            // small chunk that used to carry the bogus waiting edge to the
            // funnel), shorter than the background grace window.
            sleep(16)
            app.activate()
            XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 15),
                          "trip \(trip): never came back to the live session")
            XCTAssertFalse(app.staticTexts["Session Paused"].exists,
                           "trip \(trip): the session was suspended — the stay was too long to test anything")
            let now = try probe()
            timeline.append("trip \(trip): \(now.summary) (+\(away.resizes - before.resizes) resizing on the way out)")
        }
        let end = try probe()
        attach(text: timeline.joined(separator: "\n"), name: "probe-timeline")
        shot("idle-after-20-trips")
        XCTAssertEqual(end.posts - start.posts, 0,
                       "backgrounding an idle agent posted \(end.posts - start.posts) notification(s):\n\(timeline.joined(separator: "\n"))")
    }

    /// A permission prompt that sits unanswered while the user is away is
    /// the one thing Claude Code rings for inside a short background window
    /// (~6 s after the prompt appears with no typing). Exactly one post.
    func testAPermissionPromptWhileAwayNotifiesOnce() throws {
        try? FileManager.default.removeItem(atPath: "\(qaPath)/marker")
        try startIdleClaudeCode()
        let start = try probe()
        // Paste the request, then Enter on its own so the TUI sees a key.
        send(text: "Run this exact shell command and nothing else: touch ~/\(Self.qaDir)/marker")
        send(key: "Enter")
        let asked = waitForPane(timeout: 90) { $0.contains("Do you want") }
        XCTAssertTrue(asked, "Claude Code never asked for permission:\n\(paneText() ?? "")")
        attach(text: paneText() ?? "", name: "permission-prompt")
        // Leave right away: the bell comes ~6 s after the prompt appeared.
        XCUIDevice.shared.press(.home)
        sleep(20)
        app.activate()
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 15), "never came back to the live session")
        XCTAssertFalse(app.staticTexts["Session Paused"].exists,
                       "the session was suspended before the bell could arrive")
        let end = try probe()
        attach(text: "start: \(start.summary)\nend: \(end.summary)", name: "probe")
        shot("after-permission-away")
        XCTAssertEqual(end.posts - start.posts, 1,
                       "an unanswered permission prompt while away must notify exactly once (start \(start.summary), end \(end.summary))")
        // Deny: Escape cancels the prompt; nothing was run.
        send(key: "Escape")
        sleep(2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(qaPath)/marker"), "the denied command ran")
    }

    // MARK: - Claude Code

    /// Opens the seeded server, starts tmux in the QA directory with a pane
    /// mirror, launches Claude Code with the bell channel, accepts the folder
    /// trust dialog when it shows, and waits until the app names the agent.
    private func startIdleClaudeCode() throws {
        openSession()
        XCTAssertEqual(app.keyboards.count, 1,
                       "no software keyboard — backgrounding would not resize the pty, so this proves nothing")
        try writeRelayScript()
        try? FileManager.default.removeItem(atPath: "\(qaPath)/pane.txt")
        try? FileManager.default.removeItem(atPath: "\(qaPath)/keys.txt")
        type("tmux kill-session -t \(Self.tmuxSession) 2>/dev/null; cd ~/\(Self.qaDir) && tmux new -s \(Self.tmuxSession)\r", settle: 4)
        type("sh ~/\(Self.qaDir)/relay.sh >/dev/null 2>&1 &\r", settle: 2)
        XCTAssertTrue(waitForPane(timeout: 15) { _ in true },
                      "the tmux relay never started — a paste may have carried another simulator's pasteboard")
        send(text: "clear")
        send(key: "Enter")
        // Push notifications to a phone and Remote Control are account-level
        // features of the host's Claude Code; a test must never reach a
        // person's real devices, so they are off for this run only. `manual`
        // permission mode: the host may default to auto mode, which approves
        // commands without the prompt the permission test needs.
        send(text: "claude --model haiku --permission-mode manual --settings '{\"preferredNotifChannel\":\"terminal_bell\",\"agentPushNotifEnabled\":false,\"remoteControlAtStartup\":false}'")
        send(key: "Enter")

        // Folder trust: a fresh directory asks once. Enter accepts the
        // highlighted "Yes, proceed".
        let ready = waitForPane(timeout: 60) { text in
            text.localizedCaseInsensitiveContains("trust") || text.contains("❯")
        }
        XCTAssertTrue(ready, "Claude Code never drew anything:\n\(paneText() ?? "<no pane mirror>")")
        if paneText()?.localizedCaseInsensitiveContains("trust") == true {
            attach(text: paneText() ?? "", name: "trust-dialog")
            send(key: "Enter")
        }
        // Claude Code's idle footer: the TUI is up and sitting at its prompt.
        XCTAssertTrue(waitForPane(timeout: 60) { $0.contains("❯") && $0.contains("for agents") },
                      "Claude Code never reached its idle prompt:\n\(paneText() ?? "<no pane mirror>")")
        acceptNotificationPermissionIfAsked()
        // The app must have NAMED the agent: a bell only notifies from a
        // named agent, so zero posts from an unnamed one would prove nothing.
        XCTAssertTrue(waitForProbe(timeout: 30) { $0.agent == "claude-code" },
                      "the app never named Claude Code; probe=\((try? probe())?.summary ?? "?")")
        // Let the startup redraws and the first status-line tick settle.
        sleep(5)
        acceptNotificationPermissionIfAsked()
        attach(text: paneText() ?? "", name: "claude-idle-pane")
        attach(text: (try? probe())?.summary ?? "?", name: "probe-at-idle")
        shot("claude-idle")
    }

    // MARK: - Probe

    struct ProbeMissing: Error, CustomStringConvertible {
        var description: String { "alert probe file missing — not a DEBUG build, or the app could not write to the host QA directory" }
    }

    struct ProbeReading {
        let posts: Int
        let wouldPost: Int
        let agent: String
        let resizes: Int
        let summary: String
    }

    private func probe() throws -> ProbeReading {
        // Never a skip: the test sets APLUSTERMINAL_TEST_ALERT_PROBE itself,
        // so a missing probe is a broken harness, and a skipped count would
        // read as a clean run.
        guard let raw = try? String(contentsOfFile: probePath, encoding: .utf8) else {
            throw ProbeMissing()
        }
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        for part in summary.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        guard let posts = fields["posts"].flatMap(Int.init),
              let wouldPost = fields["wouldPost"].flatMap(Int.init),
              let resizes = fields["resizes"].flatMap(Int.init) else {
            XCTFail("unreadable probe: \(summary)")
            return ProbeReading(posts: 0, wouldPost: 0, agent: "none", resizes: 0, summary: summary)
        }
        return ProbeReading(posts: posts, wouldPost: wouldPost, agent: fields["agent"] ?? "none",
                            resizes: resizes, summary: summary)
    }

    private func waitForProbe(timeout: TimeInterval, _ condition: (ProbeReading) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reading = try? probe(), condition(reading) { return true }
            acceptNotificationPermissionIfAsked()
            sleep(1)
        }
        return false
    }

    // MARK: - Host relay (pane mirror + keystrokes)

    /// The relay runs inside the tmux session's shell and ends with it.
    /// `keys.txt` lines: `TEXT:<literal>` or `KEY:<tmux key name>`, or `KEY:KILL`
    /// to end the session.
    private func writeRelayScript() throws {
        let session = Self.tmuxSession
        let script = """
        cd ~/\(Self.qaDir) || exit 1
        while tmux has-session -t \(session) 2>/dev/null; do
          tmux capture-pane -p -t \(session) > pane.tmp 2>/dev/null && mv pane.tmp pane.txt
          if [ -f keys.txt ]; then
            # Consume first: KILL ends this loop along with the session.
            mv keys.txt keys.run
            while IFS= read -r line; do
              case "$line" in
                KEY:KILL) tmux kill-session -t \(session) ;;
                KEY:*) tmux send-keys -t \(session) "${line#KEY:}" ;;
                TEXT:*) tmux send-keys -t \(session) -l "${line#TEXT:}" ;;
              esac
            done < keys.run
            rm -f keys.run
          fi
          sleep 0.3
        done

        """
        try script.write(toFile: "\(qaPath)/relay.sh", atomically: true, encoding: .utf8)
    }

    private func send(text: String) { relay("TEXT:\(text)") }
    private func send(key: String) { relay("KEY:\(key)") }

    /// Hands one line to the relay and waits until it has been typed.
    private func relay(_ line: String) {
        let keys = "\(qaPath)/keys.txt"
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: keys), Date() < deadline {
            usleep(100_000)
        }
        let staging = "\(qaPath)/keys.tmp"
        try? (line + "\n").write(toFile: staging, atomically: true, encoding: .utf8)
        _ = rename(staging, keys)
        while FileManager.default.fileExists(atPath: keys), Date() < deadline {
            usleep(100_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keys), "the relay never typed: \(line)")
        usleep(500_000)
    }

    /// The host home directory, seen from inside the simulator.
    private var hostHome: String {
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] { return home }
        let path = NSHomeDirectory()
        if let range = path.range(of: "/Library/Developer/") { return String(path[..<range.lowerBound]) }
        return path
    }

    private var qaPath: String { "\(hostHome)/\(Self.qaDir)" }
    private var probePath: String { "\(qaPath)/probe.txt" }

    private func paneText() -> String? {
        try? String(contentsOfFile: "\(qaPath)/pane.txt", encoding: .utf8)
    }

    private func waitForPane(timeout: TimeInterval, _ condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = paneText(), condition(text) { return true }
            acceptNotificationPermissionIfAsked()
            sleep(1)
        }
        return false
    }

    // MARK: - UI helpers

    private func openSession() {
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
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 15), "never reached a connected session")
        acceptNotificationPermissionIfAsked()
        shot("connected")
    }

    /// The app asks for notification permission the first time an agent is
    /// detected — which, under auto-detect, can be any burst of shell output.
    private func acceptNotificationPermissionIfAsked() {
        let allow = springboard.alerts.buttons["Allow"]
        if allow.exists {
            allow.tap()
            sleep(1)
        }
    }

    /// Pasteboard + the accessory bar's Paste button: XCUITest's keyboard
    /// focus detection is unreliable against a custom `UIKeyInput` view. The
    /// app writes the bytes raw (no bracketed paste), so send Enter on its own
    /// when a TUI must see it as a key rather than part of a paste.
    private func type(_ text: String, settle: UInt32 = 2) {
        UIPasteboard.general.string = text
        app.buttons["Paste"].tap()
        let allowPaste = springboard.alerts.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 3) {
            allowPaste.tap()
        }
        acceptNotificationPermissionIfAsked()
        sleep(settle)
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

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
