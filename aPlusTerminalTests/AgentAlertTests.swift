import XCTest
@testable import aPlusTerminal

/// The notification decision, driven directly — no UNUserNotificationCenter.
final class AgentAlertPolicyTests: XCTestCase {
    private let session = UUID()

    func testPostsInBackgroundAndRateLimitsTheStorm() {
        var policy = AgentAlertPolicy()
        let start = Date()
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipShowsThisSession: false, now: start))
        // A flapping agent inside the 30s floor is silence, not a storm.
        for seconds in [1.0, 5, 15, 29] {
            XCTAssertFalse(policy.shouldPost(
                session: session, trigger: .bell,
                appIsActive: false, pipShowsThisSession: false,
                now: start.addingTimeInterval(seconds)
            ), "posted again after \(seconds)s — the storm the daemon's policy exists to stop")
        }
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipShowsThisSession: false,
                                        now: start.addingTimeInterval(31)))
    }

    func testTheFloorIsPerSessionNotGlobal() {
        var policy = AgentAlertPolicy()
        let now = Date()
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipShowsThisSession: false, now: now))
        XCTAssertTrue(policy.shouldPost(session: UUID(), trigger: .bell,
                                        appIsActive: false, pipShowsThisSession: false, now: now),
                      "another session's agent is not this session's storm")
    }

    @MainActor
    func testForegroundPresentationShowsAlertsUnlessTheUserIsInTheApp() {
        // `.inactive` (app switcher, Notification Center) is foreground to
        // iOS but not to the policy: an alert posted then must show.
        XCTAssertEqual(AgentAlertCenter.presentation(identifier: "agent-x-bell", appIsActive: false),
                       [.banner, .list, .sound])
        XCTAssertEqual(AgentAlertCenter.presentation(identifier: "agent-x-bell", appIsActive: true), [])
        XCTAssertEqual(AgentAlertCenter.presentation(identifier: AgentAlertCenter.testNotificationID, appIsActive: true),
                       [.banner, .list, .sound], "the test notification must show in the foreground")
    }

    func testWatchingUsersAreNotTold() {
        var policy = AgentAlertPolicy()
        XCTAssertFalse(policy.shouldPost(session: session, trigger: .bell,
                                         appIsActive: true, pipShowsThisSession: false),
                       "a user looking at the app can see the prompt")
        XCTAssertFalse(policy.shouldPost(session: session, trigger: .bell,
                                         appIsActive: false, pipShowsThisSession: true),
                       "a pop-out of this session's terminal is them watching — telling them is noise")
        // Suppression must not burn the rate-limit slot.
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipShowsThisSession: false),
                      "a suppressed alert consumed the rate-limit window")
    }
}

/// The notification funnel: ONLY explicit agent signals post, and only
/// through the gates in `noteAgentSignal`.
@MainActor
final class AgentTransitionTests: XCTestCase {
    func bareSessionForStatus() -> TerminalSession { bareSession() }

    private let claudeCode = AgentProfile(
        id: "claude-code", displayName: "Claude Code",
        detectionMarkers: ["claude code", "esc to interrupt"], attachTemplate: "{path} ",
        busyMarkers: ["esc to interrupt"])
    private let generic = AgentProfile(
        id: "generic", displayName: "Agent", detectionMarkers: [], attachTemplate: "{path} ")

    private func bareSession(agents: [AgentProfile] = []) -> TerminalSession {
        let temporary = FileManager.default.temporaryDirectory
        let suffix = UUID().uuidString
        let session = TerminalSession(
            server: Server(name: "t", host: "127.0.0.1", username: "t"),
            keyStore: KeyStore(
                secrets: InMemorySecretStore(),
                metadataURL: temporary.appendingPathComponent("ak-\(suffix).json")
            ),
            serverStore: ServerStore(
                fileURL: temporary.appendingPathComponent("as-\(suffix).json")
            ),
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: AppSettings(defaults: UserDefaults(suiteName: "AgentAlert-\(suffix)")!),
            profiles: ProfileStore(
                agents: agents,
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
        session.requestAlertAuthorization = {}
        return session
    }

    /// A session where Claude Code's banner has been seen, recording posts.
    private func claudeSession() -> (TerminalSession, () -> [AgentAlertPolicy.Trigger]) {
        let session = bareSession(agents: [claudeCode, generic])
        var fired: [AgentAlertPolicy.Trigger] = []
        session.postAgentAlert = { fired.append($0) }
        session.agentMonitor.observe(Array("Claude Code v2.1.296".utf8))
        XCTAssertEqual(session.namedAgentID, "claude-code")
        return (session, { fired })
    }

    /// Feeds raw server output into the emulator exactly as both pumps do —
    /// `terminalView.feed`, with no wrapper, so a test cannot pass on a seam
    /// the pumps do not go through.
    private func feed(_ session: TerminalSession, _ text: String) {
        session.terminalView.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    func testTheHeuristicNeverPosts() throws {
        // The report: a notification EVERY time the user left the app. The
        // click-off shape — keyboard dismissal resizes the pty, the TUI
        // repaints (a burst, so "working"), goes quiet ("waiting") — and
        // every other working/waiting cycle, long or short, must stay silent.
        let (session, fired) = claudeSession()
        let t0 = Date()
        var t = 0.0
        for _ in 0..<20 {
            session.noteAgentStatus(.working, now: t0.addingTimeInterval(t))
            session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(t + 2))
            session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(t + 17))
            session.noteAgentStatus(.working, now: t0.addingTimeInterval(t + 20))
            session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(t + 60))
            t += 100
        }
        XCTAssertEqual(fired(), [], "a heuristic status change posted")
    }

    func testABellFromANamedAgentPosts() throws {
        let (session, fired) = claudeSession()
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))
        XCTAssertEqual(fired(), [.bell])
    }

    func testABellWithNoNamedAgentNeverPosts() throws {
        // A plain shell rings on a failed tab completion.
        let plain = bareSession(agents: [claudeCode, generic])
        var fired: [AgentAlertPolicy.Trigger] = []
        plain.postAgentAlert = { fired.append($0) }
        XCTAssertEqual(plain.noteAgentSignal(.bell), .noAgent)

        // The generic heuristic "Agent" is a guess, not a name.
        plain.agentMonitor.observe(Array(String(repeating: "x", count: 400).utf8))
        XCTAssertEqual(plain.agentMonitor.status, .working)
        XCTAssertNil(plain.namedAgentID)
        XCTAssertEqual(plain.noteAgentSignal(.bell), .noAgent)
        XCTAssertEqual(fired, [])
    }

    /// The user's explicit pick (one agent, no generic fallback), with a
    /// short quiet window so the idle-prompt check runs inside a test.
    private func explicitClaudeSession() -> (TerminalSession, () -> [AgentAlertPolicy.Trigger]) {
        var quick = claudeCode
        quick.quietInterval = 0.1
        let session = bareSession(agents: [quick])
        var fired: [AgentAlertPolicy.Trigger] = []
        session.postAgentAlert = { fired.append($0) }
        return (session, { fired })
    }

    func testAnExplicitPickAtABareShellPromptDoesNotOwnTheBell() async throws {
        // An explicit pick is NAMED before anything runs. A build script's
        // `\a` at a plain shell on that server is not Claude Code asking.
        let (session, fired) = explicitClaudeSession()
        XCTAssertEqual(session.namedAgentID, "claude-code", "explicit pick is named up front")
        session.agentMonitor.observe(Array("\r\naaron@mini ~ $ ".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.agentMonitor.status, .none)
        XCTAssertEqual(session.noteAgentSignal(.bell), .noAgent, "a bare shell's bell posted as the agent's")

        // The agent starts and draws: now its bell is its own.
        session.agentMonitor.observe(Array((String(repeating: "─", count: 120) + "\r\n│ ❯ │").utf8))
        XCTAssertEqual(session.agentMonitor.status, .working)
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))

        // It exits back to the shell: the next bell is the shell's again.
        session.sendInput(Data("y".utf8))
        session.agentMonitor.observe(Array("\r\naaron@mini ~ $ ".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.agentMonitor.status, .none)
        XCTAssertEqual(session.noteAgentSignal(.bell), .noAgent)
        XCTAssertEqual(fired(), [.bell])
    }

    func testA7501SpeakerThatExitsWithoutClearingIsForgottenAtThePrompt() async throws {
        // A program that announced itself over OSC 7501 and then exited
        // without its root `clear` (crash, ^C, kill) must not leave the
        // shell's bells passing the gate.
        let (session, fired) = explicitClaudeSession()
        session.agentMonitor.observe(Array("\r\naaron@mini ~ $ ".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        feed(session, "\u{1B}]7501;state=working:app=claude-code\u{07}")
        XCTAssertTrue(session.speaksProgramStatus)
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell), "a live 7501 speaker owns its bell")

        session.sendInput(Data("y".utf8))
        session.agentMonitor.observe(Array("^C\r\naaron@mini ~ $ ".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(session.speaksProgramStatus, "the 7501 latch outlived the program")
        XCTAssertEqual(session.noteAgentSignal(.bell), .noAgent)
        XCTAssertEqual(fired(), [.bell])
    }

    func testSignalsRightAfterAResizeOrSceneChangeAreDropped() throws {
        let (session, fired) = claudeSession()
        let t0 = Date()
        session.noteDisruption("resize", now: t0)
        XCTAssertEqual(session.noteAgentSignal(.bell, now: t0.addingTimeInterval(1.9)), .disruption)
        XCTAssertEqual(session.noteAgentSignal(.bell, now: t0.addingTimeInterval(2.1)), .forwarded(.bell))

        session.noteDisruption("scene-inactive", now: t0.addingTimeInterval(10))
        XCTAssertEqual(session.noteAgentSignal(.bell, now: t0.addingTimeInterval(10.5)), .disruption)
        XCTAssertEqual(session.noteAgentSignal(.bell, now: t0.addingTimeInterval(12.5)), .forwarded(.bell))
        XCTAssertEqual(fired(), [.bell, .bell])
    }

    func testARealGridResizeOpensTheQuietWindow() throws {
        // Through the real chain: the view's bounds change → SwiftTerm
        // recomputes the grid → its delegate (SessionIO.sizeChanged) → the
        // session's quiet window. Leaving the app on a device hides the
        // keyboard, which is exactly this.
        let (session, fired) = claudeSession()
        let view = session.terminalView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        let first = try XCTUnwrap(session.lastDisruptionAt, "a grid change did not reach the disruption gate")
        XCTAssertEqual(session.noteAgentSignal(.bell, now: first.addingTimeInterval(1)), .disruption)
        XCTAssertEqual(session.noteAgentSignal(.bell, now: first.addingTimeInterval(2.5)), .forwarded(.bell))

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        view.layoutIfNeeded()
        let second = try XCTUnwrap(session.lastDisruptionAt)
        XCTAssertGreaterThan(second, first, "the keyboard-sized resize was not a disruption")
        XCTAssertEqual(session.noteAgentSignal(.bell, now: second.addingTimeInterval(0.5)), .disruption)
        XCTAssertEqual(fired(), [.bell])
    }

    func testOnlyARealResizeIsADisruption() throws {
        // SwiftTerm reports a size change only when cols/rows change; the
        // keepalive's same-size ping goes straight to resize(), and a layout
        // pass at the same size changes nothing — neither may open a quiet
        // window (the keepalive would mute alerts every 25 s).
        let (session, _) = claudeSession()
        let view = session.terminalView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        let marked = session.lastDisruptionAt
        XCTAssertNotNil(marked)
        let grid = view.getTerminal()
        session.resize(cols: grid.cols, rows: grid.rows)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        XCTAssertEqual(session.lastDisruptionAt, marked, "a same-size resize counted as a disruption")
    }

    func testASeenSignalStaysQuietUntilTheUserAnswers() throws {
        // "I get notifications saying my agent needs me but I already
        // checked the session out and just didn't respond."
        let (session, fired) = claudeSession()
        session.noteAgentSignal(.bell)
        XCTAssertEqual(fired(), [.bell])

        // The user opens the session, looks, leaves without answering.
        session.markViewed()
        XCTAssertEqual(session.noteAgentSignal(.bell), .seenUnanswered)
        XCTAssertEqual(session.noteAgentSignal(.programStatus(.init(state: .blocked, kind: "permission"))), .seenUnanswered)
        XCTAssertEqual(fired(), [.bell], "a seen, unanswered signal re-notified")

        // The user ANSWERS. The next ring is news again.
        session.sendInput(Data("y".utf8))
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))
        XCTAssertEqual(fired(), [.bell, .bell])
    }

    func testLookingWithNothingPendingMutesNothing() throws {
        let (session, fired) = claudeSession()
        session.markViewed()
        session.noteAgentSignal(.bell)
        XCTAssertEqual(fired(), [.bell])
    }

    func testScrollingIsNotAnAnswer() throws {
        let (session, fired) = claudeSession()
        session.noteAgentSignal(.bell)
        session.markViewed()
        session.sendInput(Data("\u{1B}[<64;10;10M".utf8), countsAsResponse: false)
        XCTAssertEqual(session.noteAgentSignal(.bell), .seenUnanswered, "a scroll re-armed the alerts")
        XCTAssertEqual(fired(), [.bell])
    }

    func testFocusReportsAndQueryRepliesAreNotAnAnswer() throws {
        // Every app switch moves first responder, and with mode 1004 on
        // SwiftTerm writes ESC[I / ESC[O through the same delegate as typing.
        // Those used to count as the user's answer and clear the mute on
        // every return to the app.
        let (session, fired) = claudeSession()
        var writes: [(Data, Bool)] = []
        session.onSendInput = { writes.append(($0, $1)) }
        session.noteAgentSignal(.bell)
        session.markViewed()
        feed(session, "\u{1B}[?1004h")
        session.terminalView.getTerminal().setTerminalFocus(false)
        session.terminalView.getTerminal().setTerminalFocus(true)
        // A device-attributes query in the output: SwiftTerm answers it.
        feed(session, "\u{1B}[c")
        XCTAssertEqual(writes.map(\.0).prefix(2), [Data("\u{1B}[O".utf8), Data("\u{1B}[I".utf8)])
        XCTAssertGreaterThanOrEqual(writes.count, 3, "SwiftTerm did not answer the DA query")
        XCTAssertTrue(writes.allSatisfy { !$0.1 }, "a terminal-generated write counted as the user's answer")
        XCTAssertEqual(session.noteAgentSignal(.bell), .seenUnanswered,
                       "a focus report or query reply counted as the user answering")
        XCTAssertEqual(fired(), [.bell])

        // Real typing still answers.
        session.terminalView.send(txt: "y")
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))
    }

    func testQueryRepliesFromRealOutputAreNotAnAnswerButTypingIs() throws {
        // The marking lives in the emulator's own write funnel
        // (TerminalEmulatorView.send(source:data:)), so it holds for output
        // fed exactly as the pumps feed it. What a TUI asks at startup:
        // primary and secondary DA, a cursor-position report, the
        // foreground color.
        let (session, fired) = claudeSession()
        var writes: [(Data, Bool)] = []
        session.onSendInput = { writes.append(($0, $1)) }
        session.noteAgentSignal(.bell)
        session.markViewed()
        feed(session, "\u{1B}[c\u{1B}[>c\u{1B}[6n\u{1B}]10;?\u{07}")
        let replies = writes.map { String(decoding: $0.0, as: UTF8.self) }
        XCTAssertTrue(replies.contains { $0.hasPrefix("\u{1B}[?") && $0.hasSuffix("c") }, "no DA reply: \(replies.map(\.debugDescription))")
        XCTAssertTrue(replies.contains { $0.hasPrefix("\u{1B}[>") && $0.hasSuffix("c") }, "no secondary DA reply")
        XCTAssertTrue(replies.contains { $0.hasSuffix("R") }, "no cursor-position reply")
        XCTAssertTrue(replies.contains { $0.hasPrefix("\u{1B}]10;") }, "no color reply")
        XCTAssertEqual(writes.filter(\.1).count, 0, "a query reply counted as the user's answer")
        XCTAssertEqual(session.noteAgentSignal(.bell), .seenUnanswered)
        XCTAssertFalse(session.terminalView.isEmulatorWriting, "the marking leaked past the reply")

        // The soft keyboard's path: insertText → the input bridge / send(data:).
        writes.removeAll()
        session.terminalView.insertText("y")
        XCTAssertEqual(writes.map(\.0), [Data("y".utf8)])
        XCTAssertEqual(writes.map(\.1), [true], "typing no longer counts as the answer")
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))
        XCTAssertEqual(fired(), [.bell, .bell])
    }

    func testAMouseClickIsAnAnswerEvenThoughTheEmulatorWritesIt() throws {
        // SwiftTerm encodes a tap on a mouse-reporting TUI through the same
        // emulator path as its query replies; a tap on an option is still
        // the user choosing.
        // Every encoding SwiftTerm can be switched into: X10, SGR, urxvt.
        for (modes, expected) in [("\u{1B}[?1000h", "\u{1B}[M $%"),
                                  ("\u{1B}[?1000h\u{1B}[?1006h", "\u{1B}[<0;4;5M"),
                                  ("\u{1B}[?1000h\u{1B}[?1015h", "\u{1B}[32;4;5M")] {
            let (session, _) = claudeSession()
            var writes: [(Data, Bool)] = []
            session.onSendInput = { writes.append(($0, $1)) }
            session.noteAgentSignal(.bell)
            session.markViewed()
            feed(session, modes)
            session.terminalView.getTerminal().sendEvent(buttonFlags: 0, x: 3, y: 4)
            XCTAssertEqual(writes.last?.0, Data(expected.utf8))
            XCTAssertEqual(writes.last?.1, true, "a mouse click (\(expected.debugDescription)) did not count as the user's answer")
            XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))
        }
    }

    func testTheFloorStillAppliesBehindTheGates() throws {
        // The gates forward; the policy's 30 s per-session floor still has
        // the last word.
        var policy = AgentAlertPolicy()
        let (session, _) = claudeSession()
        var posted = 0
        let t0 = Date()
        var now = t0
        session.postAgentAlert = { trigger in
            if policy.shouldPost(session: session.id, trigger: trigger,
                                 appIsActive: false, pipShowsThisSession: false, now: now) {
                posted += 1
            }
        }
        for offset in [0.0, 5, 29] {
            now = t0.addingTimeInterval(offset)
            session.noteAgentSignal(.bell, now: now)
        }
        XCTAssertEqual(posted, 1)
        now = t0.addingTimeInterval(31)
        session.noteAgentSignal(.bell, now: now)
        XCTAssertEqual(posted, 2)
    }

    // MARK: - Escape sequences, through the real emulator

    func testOSC777NotifyPosts() throws {
        let (session, fired) = claudeSession()
        feed(session, "\u{1B}]777;notify;Claude Code;Claude needs your permission to use Bash\u{07}")
        XCTAssertEqual(fired(), [.message(title: "Claude Code", body: "Claude needs your permission to use Bash")])
    }

    func testOSC777ParsesBodiesWithSemicolons() {
        XCTAssertEqual(AgentSignal.parseOSC777(ArraySlice(Array("notify;T;a;b".utf8))),
                       .osc777(title: "T", body: "a;b"))
        XCTAssertNil(AgentSignal.parseOSC777(ArraySlice(Array("other;T;b".utf8))))
        XCTAssertNil(AgentSignal.parseOSC777(ArraySlice(Array("notify;only-title".utf8))))
    }

    func testOSC9MessagePostsAndProgressDoesNot() throws {
        let (session, fired) = claudeSession()
        feed(session, "\u{1B}]9;4;1;40\u{07}")
        feed(session, "\u{1B}]9;4;0\u{07}")
        feed(session, "\u{1B}]9;9;/Users/someone\u{07}")
        XCTAssertEqual(fired(), [], "progress and ConEmu commands are not notifications")
        feed(session, "\u{1B}]9;Claude Code: Claude is waiting for your input\u{07}")
        XCTAssertEqual(fired(), [.message(title: nil, body: "Claude Code: Claude is waiting for your input")])
    }

    func testOSC9ProgressStillDrivesTheBar() throws {
        // Registering an OSC 9 handler replaces SwiftTerm's built-in, so the
        // progress bar only lives if the handler hands 9;4 back to the view.
        let (session, _) = claudeSession()
        let view = session.terminalView
        let bar = try XCTUnwrap(view.subviews.first { String(describing: type(of: $0)) == "TerminalProgressBarView" },
                                "SwiftTerm's progress bar view is gone — check the pinned version")
        XCTAssertTrue(bar.isHidden)
        feed(session, "\u{1B}]9;4;1;40\u{07}")
        XCTAssertFalse(bar.isHidden, "9;4 progress no longer reaches the bar")
        feed(session, "\u{1B}]9;4;0\u{07}")
        XCTAssertTrue(bar.isHidden, "9;4;0 did not remove the bar")
    }

    func testOSC9ProgressIsStillParsedForTheBar() {
        XCTAssertEqual(AgentSignal.parseOSC9(ArraySlice(Array("4;1;40".utf8))),
                       .progress(.init(state: .set, progress: 40)))
        XCTAssertEqual(AgentSignal.parseOSC9(ArraySlice(Array("4;3".utf8))),
                       .progress(.init(state: .indeterminate, progress: nil)))
        XCTAssertEqual(AgentSignal.parseOSC9(ArraySlice(Array("4;0".utf8))),
                       .progress(.init(state: .remove, progress: nil)))
        XCTAssertEqual(AgentSignal.parseOSC9(ArraySlice(Array("4;9".utf8))), .ignored)
        XCTAssertEqual(AgentSignal.parseOSC9(ArraySlice(Array("hello".utf8))), .notification("hello"))
    }

    func testOSC7501ProbeIsAnsweredAndIsNotAnAnswer() throws {
        let (session, _) = claudeSession()
        var writes: [(Data, Bool)] = []
        session.onSendInput = { writes.append(($0, $1)) }
        session.noteAgentSignal(.bell)
        session.markViewed()
        feed(session, "\u{1B}]7501;?\u{07}")
        XCTAssertEqual(writes.map(\.0), [Data("\u{1B}]7501;?\u{07}".utf8)], "the probe got no (or the wrong) reply")
        XCTAssertEqual(writes.map(\.1), [false])
        XCTAssertEqual(session.noteAgentSignal(.bell), .seenUnanswered,
                       "the probe reply counted as the user answering")
    }

    func testOSC7501BlockedAndDonePostWorkingAndIdleDoNot() throws {
        // No marker match needed: a program speaking 7501 announced itself.
        let session = bareSession(agents: [claudeCode, generic])
        var fired: [AgentAlertPolicy.Trigger] = []
        var permissionAsks = 0
        session.postAgentAlert = { fired.append($0) }
        session.requestAlertAuthorization = { permissionAsks += 1 }
        XCTAssertNil(session.namedAgentID)

        feed(session, "\u{1B}]7501;state=working:app=claude-code:progress=10\u{07}")
        // It can post without ever being named, so permission is asked now —
        // unasked, its first `blocked` would be dropped by iOS.
        XCTAssertEqual(permissionAsks, 1, "a 7501 speaker never triggered the notification permission ask")
        feed(session, "\u{1B}]7501;state=idle:app=claude-code\u{07}")
        XCTAssertEqual(fired, [], "status updates are not requests")
        XCTAssertTrue(session.speaksProgramStatus)
        XCTAssertEqual(permissionAsks, 1, "asked again on every record")

        feed(session, "\u{1B}]7501;state=blocked:app=claude-code:kind=permission\u{1B}\\")
        XCTAssertEqual(fired, [.blocked(kind: "permission")])

        // A subagent finishing is not the session finishing.
        feed(session, "\u{1B}]7501;state=done:app=claude-code:id=task-1\u{07}")
        XCTAssertEqual(fired, [.blocked(kind: "permission")])

        feed(session, "\u{1B}]7501;state=done:app=claude-code\u{07}")
        XCTAssertEqual(fired, [.blocked(kind: "permission"), .finished])

        // The program clears its records on the way out: the shell's next
        // tab-completion bell is not an agent's.
        feed(session, "\u{1B}]7501;state=clear\u{07}")
        XCTAssertFalse(session.speaksProgramStatus)
        XCTAssertEqual(session.noteAgentSignal(.bell), .noAgent)
    }

    func testLogNamesNeverCarryTheProgramsWords() {
        // The unified log is persistent and ends up in sysdiagnoses: only
        // kinds, never the title, body or a free-form 7501 kind.
        XCTAssertEqual(AgentSignal.osc777(title: "secret", body: "token=hunter2").logName, "osc777")
        XCTAssertEqual(AgentSignal.osc9(message: "token=hunter2").logName, "osc9")
        XCTAssertEqual(AgentSignal.programStatus(.init(state: .blocked, kind: "token=hunter2")).logName,
                       "osc7501-blocked-other")
        XCTAssertEqual(AgentSignal.programStatus(.init(state: .blocked, kind: "permission")).logName,
                       "osc7501-blocked-permission")
        XCTAssertEqual(TerminalSession.SignalOutcome.forwarded(.message(title: "secret", body: "token=hunter2")).logName,
                       "forwarded-message")
        XCTAssertEqual(AgentAlertPolicy.Trigger.blocked(kind: "token=hunter2").slug, "blocked")
        XCTAssertEqual(AgentAlertPolicy.Trigger.message(title: "secret", body: "token=hunter2").slug, "message")
        for name in [TerminalSession.SignalOutcome.forwarded(.message(title: "secret", body: "token=hunter2")).logName,
                     AgentSignal.osc777(title: "secret", body: "token=hunter2").logName,
                     AgentAlertPolicy.Trigger.message(title: "secret", body: "token=hunter2").slug] {
            XCTAssertFalse(name.contains("secret") || name.contains("hunter2"), "\(name) carries the program's words")
        }
    }

    func testTheLoggedAgentIsAKnownProfileOrNothing() {
        let session = bareSession(agents: [claudeCode, generic])
        XCTAssertEqual(session.agentLogName, "nil")
        session.agentMonitor.observe(Array("Claude Code v2.1.296".utf8))
        XCTAssertEqual(session.agentLogName, "claude-code")
    }

    func testOSC7501RecordsParseAndBadReportsAreDiscarded() {
        let title = Data("Bash".utf8).base64EncodedString()
        let parsed = ProgramStatus.parse(ArraySlice(Array("state=blocked:app=claude-code:kind=question:title=\(title):junk:state=blocked".utf8)))
        XCTAssertEqual(parsed, .record(.init(state: .blocked, kind: "question", app: "claude-code", title: "Bash")))
        XCTAssertEqual(ProgramStatus.parse(ArraySlice(Array("?".utf8))), .probe)
        XCTAssertNil(ProgramStatus.parse(ArraySlice(Array("app=x".utf8))), "no state")
        XCTAssertNil(ProgramStatus.parse(ArraySlice(Array("state=dancing".utf8))), "unknown state")
        XCTAssertNil(ProgramStatus.parse(ArraySlice(Array("state=done:msg=%%%".utf8))), "bad base64")
        let control = Data("a\u{07}b".utf8).base64EncodedString()
        XCTAssertNil(ProgramStatus.parse(ArraySlice(Array("state=done:msg=\(control)".utf8))), "control character")
    }
}

/// The "how to get notified" card: once, the first time Claude Code shows up
/// in ANY session, and never for other agents.
@MainActor
final class NotificationSetupCardTests: XCTestCase {
    private let claudeCode = AgentProfile(
        id: "claude-code", displayName: "Claude Code",
        detectionMarkers: ["claude code"], attachTemplate: "{path} ")
    private let hermes = AgentProfile(
        id: "hermes", displayName: "Hermes", detectionMarkers: ["hermes"], attachTemplate: "{path} ")

    private func session(_ settings: AppSettings) -> TerminalSession {
        let temporary = FileManager.default.temporaryDirectory
        let suffix = UUID().uuidString
        return TerminalSession(
            server: Server(name: "t", host: "127.0.0.1", username: "t"),
            keyStore: KeyStore(secrets: InMemorySecretStore(),
                               metadataURL: temporary.appendingPathComponent("ck-\(suffix).json")),
            serverStore: ServerStore(fileURL: temporary.appendingPathComponent("cs-\(suffix).json")),
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: ProfileStore(
                agents: [claudeCode, hermes],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
    }

    /// A real SessionManager over in-memory stores. Sessions it opens have
    /// no credentials, so connect() fails before any network.
    private func manager(_ settings: AppSettings) -> SessionManager {
        let temporary = FileManager.default.temporaryDirectory
        let suffix = UUID().uuidString
        return SessionManager(
            keyStore: KeyStore(secrets: InMemorySecretStore(),
                               metadataURL: temporary.appendingPathComponent("mk-\(suffix).json")),
            serverStore: ServerStore(fileURL: temporary.appendingPathComponent("ms-\(suffix).json")),
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: ProfileStore(
                agents: [claudeCode, hermes],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
    }

    /// Opens a session in `manager` with Claude Code detected, the app
    /// backgrounded and no permission dialog.
    private func claudeSession(in manager: SessionManager, _ name: String) -> TerminalSession {
        let session = manager.open(server: Server(name: name, host: "127.0.0.1", username: "t"))
        session.requestAlertAuthorization = {}
        session.appIsActive = { false }
        session.agentMonitor.observe(Array("Claude Code v2.1.296".utf8))
        session.noteAgentStatus(.none)
        return session
    }

    func testRaisedForClaudeCodeOnly() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "SetupCard-\(UUID().uuidString)")!)

        let other = session(settings)
        other.agentMonitor.observe(Array("hermes ready".utf8))
        other.noteAgentStatus(.none)
        XCTAssertFalse(other.showNotificationSetupCard, "the card is about Claude Code's setting")

        let first = session(settings)
        first.noteAgentStatus(.none)
        XCTAssertFalse(first.showNotificationSetupCard, "nothing detected yet")
        first.agentMonitor.observe(Array("Claude Code v2.1.296".utf8))
        first.noteAgentStatus(.none)
        XCTAssertTrue(first.showNotificationSetupCard)
    }

    func testUsedUpOnlyOnceItIsOnScreen() throws {
        // Detection in a session the user never opens (or one whose card
        // sits behind the tmux mouse hint) must not spend the one showing.
        let settings = AppSettings(defaults: UserDefaults(suiteName: "SetupCard-\(UUID().uuidString)")!)
        let manager = self.manager(settings)
        defer { manager.closeAll() }
        let unseen = manager.open(server: Server(name: "a", host: "127.0.0.1", username: "t"))
        let seen = manager.open(server: Server(name: "b", host: "127.0.0.1", username: "t"))
        for session in [unseen, seen] {
            session.requestAlertAuthorization = {}
            session.agentMonitor.observe(Array("Claude Code v2.1.296".utf8))
            session.noteAgentStatus(.none)
            XCTAssertTrue(session.showNotificationSetupCard)
        }
        XCTAssertFalse(settings.notificationSetupCardShown, "detection alone used up the card")

        manager.notificationSetupCardAppeared(in: seen)
        XCTAssertTrue(settings.notificationSetupCardShown)
        XCTAssertTrue(seen.showNotificationSetupCard, "the card on screen stays until dismissed")
        XCTAssertFalse(unseen.showNotificationSetupCard, "a second session would show it again")

        let later = manager.open(server: Server(name: "c", host: "127.0.0.1", username: "t"))
        later.requestAlertAuthorization = {}
        later.agentMonitor.observe(Array("Claude Code v2.1.296".utf8))
        later.noteAgentStatus(.none)
        XCTAssertFalse(later.showNotificationSetupCard, "shown once, ever — Settings keeps it reachable")
    }

    func testASceneChangeQuietsEverySession() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "Scene-\(UUID().uuidString)")!)
        let manager = self.manager(settings)
        defer { manager.closeAll() }
        let sessions = [claudeSession(in: manager, "a"), claudeSession(in: manager, "b")]
        for session in sessions {
            session.postAgentAlert = { _ in }
        }
        let before = Date()
        manager.scenePhaseChanged(to: "inactive")
        for session in sessions {
            let marked = try XCTUnwrap(session.lastDisruptionAt, "scenePhaseChanged skipped a session")
            XCTAssertGreaterThanOrEqual(marked, before)
            XCTAssertEqual(session.noteAgentSignal(.bell, now: marked.addingTimeInterval(1)), .disruption)
            XCTAssertEqual(session.noteAgentSignal(.bell, now: marked.addingTimeInterval(2.5)), .forwarded(.bell))
        }
    }

    func testAPopOutMutesOnlyTheSessionItShows() throws {
        // Through the real wiring: session → SessionManager → AgentAlertCenter
        // → its policy, with only the final hand-off to iOS recorded.
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PiPMute-\(UUID().uuidString)")!)
        let manager = self.manager(settings)
        defer { manager.closeAll() }
        var posted: [String] = []
        manager.alertCenter = AgentAlertCenter(addRequest: { posted.append($0.identifier) })
        let watched = claudeSession(in: manager, "a")
        let other = claudeSession(in: manager, "b")
        manager.pipShowsTerminal = { $0 == watched.id }

        XCTAssertEqual(watched.noteAgentSignal(.bell), .forwarded(.bell))
        XCTAssertEqual(other.noteAgentSignal(.bell), .forwarded(.bell))
        XCTAssertEqual(posted, ["agent-\(other.id.uuidString)-bell"],
                       "a pop-out of session A must mute A only — B's agent still notifies")

        // A pop-out of something else (a preview, a VNC monitor) mutes nothing.
        manager.pipShowsTerminal = { _ in false }
        XCTAssertEqual(watched.noteAgentSignal(.programStatus(.init(state: .blocked, kind: "permission"))),
                       .forwarded(.blocked(kind: "permission")))
        XCTAssertEqual(posted.last, "agent-\(watched.id.uuidString)-blocked")
    }

    func testNoPopOutShowsATerminalWhileNoneIsActive() {
        let pip = PiPCoordinator(settings: AppSettings(defaults: UserDefaults(suiteName: "PiP-\(UUID().uuidString)")!))
        XCTAssertFalse(pip.isActive)
        XCTAssertFalse(pip.isShowingTerminal(of: UUID()))
    }

    func testTheCopiedTextIsTheSetting() {
        XCTAssertEqual(AgentNotificationSetup.settingLine, #""preferredNotifChannel": "terminal_bell""#)
    }
}

/// The daemon's read outranks the heuristic exactly when meshyy carries the
/// session.
@MainActor
final class EffectiveAgentStatusTests: XCTestCase {
    func testHeuristicIsTheFallbackNotTheTruth() throws {
        let session = AgentTransitionTests().bareSessionForStatus()
        // No meshyy, no daemon read: the heuristic is all there is.
        XCTAssertEqual(session.effectiveAgentStatus, session.agentMonitor.status)
    }
}

#if MESHYY
/// The by-name deep link parses; junk does not.
@MainActor
final class ServerSessionLinkTests: XCTestCase {
    func testParsesTheNamedSessionForm() throws {
        let router = DeepLinkRouter()
        let server = UUID()
        router.handle(URL(string: "aplusterminal://server/\(server.uuidString)/session/aplus-abc-0")!)
        XCTAssertEqual(router.targetServerSession?.server, server)
        XCTAssertEqual(router.targetServerSession?.name, "aplus-abc-0")
        XCTAssertEqual(router.selectedTab, .terminal)
    }

    func testJunkFormsAreRejected() throws {
        let router = DeepLinkRouter()
        for bad in ["aplusterminal://server/not-a-uuid/session/x",
                    "aplusterminal://server/\(UUID().uuidString)",
                    "aplusterminal://server/\(UUID().uuidString)/other/x"] {
            router.handle(URL(string: bad)!)
            XCTAssertNil(router.targetServerSession, "accepted junk: \(bad)")
        }
    }
}
#endif
