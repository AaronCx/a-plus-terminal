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

    func testOnlyTheEdgeIntoWaitingFires() throws {
        let session = bareSession()
        var fired: [AgentAlertPolicy.Trigger] = []
        session.postAgentAlert = { fired.append($0) }

        session.noteAgentStatus(.none)
        session.noteAgentStatus(.working)
        XCTAssertEqual(fired, [], "working must never alert — it fires constantly")
        session.noteAgentStatus(.waiting)
        XCTAssertEqual(fired, [.becameWaiting])
        session.noteAgentStatus(.waiting)
        XCTAssertEqual(fired, [.becameWaiting], "still waiting is not newly waiting")
        session.noteAgentStatus(.working)
        session.noteAgentStatus(.waiting)
        XCTAssertEqual(fired, [.becameWaiting, .becameWaiting],
                       "a fresh edge is a fresh alert (the policy rate-limits it)")
    }
}

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
