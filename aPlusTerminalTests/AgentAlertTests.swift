import XCTest
@testable import aPlusTerminal

/// The notification decision, driven directly — no UNUserNotificationCenter.
final class AgentAlertPolicyTests: XCTestCase {
    private let session = UUID()

    func testPostsInBackgroundAndRateLimitsTheStorm() {
        var policy = AgentAlertPolicy()
        let start = Date()
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .becameWaiting,
                                        appIsActive: false, pipIsShowing: false, now: start))
        // A flapping agent inside the 30s floor is silence, not a storm.
        for seconds in [1.0, 5, 15, 29] {
            XCTAssertFalse(policy.shouldPost(
                session: session, trigger: .becameWaiting,
                appIsActive: false, pipIsShowing: false,
                now: start.addingTimeInterval(seconds)
            ), "posted again after \(seconds)s — the storm the daemon's policy exists to stop")
        }
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .becameWaiting,
                                        appIsActive: false, pipIsShowing: false,
                                        now: start.addingTimeInterval(31)))
    }

    func testTheFloorIsPerSessionNotGlobal() {
        var policy = AgentAlertPolicy()
        let now = Date()
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .becameWaiting,
                                        appIsActive: false, pipIsShowing: false, now: now))
        XCTAssertTrue(policy.shouldPost(session: UUID(), trigger: .becameWaiting,
                                        appIsActive: false, pipIsShowing: false, now: now),
                      "another session's agent is not this session's storm")
    }

    func testWatchingUsersAreNotTold() {
        var policy = AgentAlertPolicy()
        XCTAssertFalse(policy.shouldPost(session: session, trigger: .becameWaiting,
                                         appIsActive: true, pipIsShowing: false),
                       "a user looking at the app can see the prompt")
        XCTAssertFalse(policy.shouldPost(session: session, trigger: .bell,
                                         appIsActive: false, pipIsShowing: true),
                       "the pop-out exists so they can watch — telling them is noise")
        // Suppression must not burn the rate-limit slot.
        XCTAssertTrue(policy.shouldPost(session: session, trigger: .becameWaiting,
                                        appIsActive: false, pipIsShowing: false),
                      "a suppressed alert consumed the rate-limit window")
    }
}

/// The transition funnel: alerts fire on the EDGE into waiting, once.
@MainActor
final class AgentTransitionTests: XCTestCase {
    func bareSessionForStatus() -> TerminalSession { bareSession() }

    private func bareSession() -> TerminalSession {
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
                agents: [],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
    }

    func testOnlyASustainedWorkingPhaseEarnsAnAlertOnItsEnd() throws {
        let session = bareSession()
        var fired: [AgentAlertPolicy.Trigger] = []
        session.postAgentAlert = { fired.append($0) }
        let t0 = Date()

        session.noteAgentStatus(.none, now: t0)
        session.noteAgentStatus(.working, now: t0)
        XCTAssertEqual(fired, [], "working must never alert — it fires constantly")

        // The click-off shape: keyboard dismissal resizes the pty, the TUI
        // repaints (2s of "work"), goes quiet, and manufactures a waiting
        // edge. This posted a notification EVERY time the user left the app.
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(2))
        XCTAssertEqual(fired, [], "a 2s repaint is not work; its end is not news")

        // Typing's turn-by-turn oscillation: same filter, same silence.
        session.noteAgentStatus(.working, now: t0.addingTimeInterval(3))
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(5.5))
        XCTAssertEqual(fired, [], "turn-taking echo bursts must not alert")

        // Real work: sustained, then finished — THIS is the notification.
        session.noteAgentStatus(.working, now: t0.addingTimeInterval(10))
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(20))
        XCTAssertEqual(fired, [.becameWaiting])
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(21))
        XCTAssertEqual(fired, [.becameWaiting], "still waiting is not newly waiting")
    }

    func testASeenWaitStaysQuietUntilTheUserAnswers() throws {
        // The report: "I get notifications saying my agent needs me but I
        // already checked the session out and just didn't respond." An agent
        // with background tasks cycles working→waiting on its own timers;
        // each cycle used to read as a brand-new need.
        let session = bareSession()
        var fired: [AgentAlertPolicy.Trigger] = []
        session.postAgentAlert = { fired.append($0) }
        let t0 = Date()

        // Real work ends: the first, legitimate notification.
        session.noteAgentStatus(.working, now: t0)
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(10))
        XCTAssertEqual(fired, [.becameWaiting])

        // The user opens the session, looks at the prompt, decides not to
        // answer yet, and leaves.
        session.markViewed()

        // The agent's own background cycles manufacture fresh edges — five
        // sustained-work cycles, all after the user already saw the wait.
        var t = 20.0
        for _ in 0..<5 {
            session.noteAgentStatus(.working, now: t0.addingTimeInterval(t))
            session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(t + 8))
            t += 20
        }
        XCTAssertEqual(fired, [.becameWaiting],
                       "a seen wait re-notified — the exact report this pins")

        // The user ANSWERS. The next wait is genuinely news again.
        session.sendInput(Data("y\r".utf8))
        session.noteAgentStatus(.working, now: t0.addingTimeInterval(t))
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(t + 8))
        XCTAssertEqual(fired, [.becameWaiting, .becameWaiting])
    }

    func testScrollingIsNotAnAnswer() throws {
        // Reading back through output is looking, not responding — wheel
        // events must not re-arm the alerts a real answer re-arms.
        let session = bareSession()
        var fired: [AgentAlertPolicy.Trigger] = []
        session.postAgentAlert = { fired.append($0) }
        let t0 = Date()

        session.noteAgentStatus(.working, now: t0)
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(10))
        session.markViewed()
        session.sendInput(Data("\u{1B}[<64;10;10M".utf8), countsAsResponse: false)
        session.noteAgentStatus(.working, now: t0.addingTimeInterval(20))
        session.noteAgentStatus(.waiting, now: t0.addingTimeInterval(30))
        XCTAssertEqual(fired, [.becameWaiting], "a scroll re-armed the alerts")
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
