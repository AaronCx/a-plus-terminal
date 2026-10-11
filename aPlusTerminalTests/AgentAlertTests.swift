import XCTest
@testable import aPlusTerminal

/// The notification decision, driven directly — no UNUserNotificationCenter.
final class AgentAlertPolicyTests: XCTestCase {
    private let session = UUID()

    func testPostsInBackgroundAndRateLimitsTheStorm() {
        var policy = AgentAlertPolicy()
        let start = Date()
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipIsShowing: false, now: start))
        // A flapping agent inside the 30s floor is silence, not a storm.
        for seconds in [1.0, 5, 15, 29] {
            XCTAssertFalse(policy.shouldPost(
                session: session, trigger: .bell,
                appIsActive: false, pipIsShowing: false,
                now: start.addingTimeInterval(seconds)
            ), "posted again after \(seconds)s — the storm the daemon's policy exists to stop")
        }
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipIsShowing: false,
                                        now: start.addingTimeInterval(31)))
    }

    func testTheFloorIsPerSessionNotGlobal() {
        var policy = AgentAlertPolicy()
        let now = Date()
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipIsShowing: false, now: now))
        XCTAssertTrue(policy.shouldPost(session: UUID(), trigger: .bell,
                                        appIsActive: false, pipIsShowing: false, now: now),
                      "another session's agent is not this session's storm")
    }

    func testWatchingUsersAreNotTold() {
        var policy = AgentAlertPolicy()
        XCTAssertFalse(policy.shouldPost(session: session, trigger: .bell,
                                         appIsActive: true, pipIsShowing: false),
                       "a user looking at the app can see the prompt")
        XCTAssertFalse(policy.shouldPost(session: session, trigger: .bell,
                                         appIsActive: false, pipIsShowing: true),
                       "the pop-out exists so they can watch — telling them is noise")
        // Suppression must not burn the rate-limit slot.
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .bell,
                                        appIsActive: false, pipIsShowing: false),
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
        return TerminalSession(
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

    /// Feeds raw server output through the emulator, the way the pump does.
    private func feed(_ session: TerminalSession, _ text: String) {
        session.feedOutput(Array(text.utf8))
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

    func testOnlyARealResizeIsADisruption() throws {
        // SwiftTerm reports a size change only when cols/rows change; the
        // keepalive's same-size ping goes straight to resize() and must not
        // open a quiet window every 25 s.
        let (session, _) = claudeSession()
        session.resize(cols: 80, rows: 24)
        XCTAssertEqual(session.noteAgentSignal(.bell), .forwarded(.bell))
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
                                 appIsActive: false, pipIsShowing: false, now: now) {
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
        session.postAgentAlert = { fired.append($0) }
        XCTAssertNil(session.namedAgentID)

        feed(session, "\u{1B}]7501;state=working:app=claude-code:progress=10\u{07}")
        feed(session, "\u{1B}]7501;state=idle:app=claude-code\u{07}")
        XCTAssertEqual(fired, [], "status updates are not requests")
        XCTAssertTrue(session.speaksProgramStatus)

        feed(session, "\u{1B}]7501;state=blocked:app=claude-code:kind=permission\u{1B}\\")
        XCTAssertEqual(fired, [.blocked(kind: "permission")])

        // A subagent finishing is not the session finishing.
        feed(session, "\u{1B}]7501;state=done:app=claude-code:id=task-1\u{07}")
        XCTAssertEqual(fired, [.blocked(kind: "permission")])

        feed(session, "\u{1B}]7501;state=done:app=claude-code\u{07}")
        XCTAssertEqual(fired, [.blocked(kind: "permission"), .finished])
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
