import XCTest
import Citadel
import CryptoKit
import NIOSSH
@testable import aPlusTerminal

/// The wind-down state machine and the launch-time classification. The
/// watchdog kill itself (0x8badf00d) is device-only — the simulator does not
/// enforce background watchdogs — so these tests prove the *structure*: the
/// record written at each phase, the re-entrancy guards, and that a record
/// abandoned mid-phase classifies as a suspected background kill at the next
/// launch.
@MainActor
final class BackgroundExitDiagnosticsTests: XCTestCase {
    /// Mutable test clock so elapsed-seconds text is deterministic.
    final class TestClock {
        var current = Date(timeIntervalSince1970: 1_750_000_000)
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        suiteName = "BackgroundExitDiagnosticsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        clock = TestClock()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeDiagnostics() -> BackgroundExitDiagnostics {
        BackgroundExitDiagnostics(defaults: defaults, now: { [clock] in clock!.current })
    }

    // MARK: - State machine transitions

    func testFreshLaunchHasNoPreviousRecordAndStartsForeground() {
        let diag = makeDiagnostics()
        XCTAssertEqual(diag.previousExit, .none)
        XCTAssertEqual(diag.previousExitSummary, "No previous run recorded.")
        XCTAssertEqual(diag.record.phase, .foreground)
    }

    func testHappyPathTransitions() {
        let diag = makeDiagnostics()

        diag.markBackgrounded()
        XCTAssertEqual(diag.record.phase, .backgrounded)
        XCTAssertEqual(diag.record.backgroundedAt, clock.current)
        XCTAssertNil(diag.record.windDownStartedAt)

        clock.advance(20)
        diag.markWindDownStarted(trigger: .proactive)
        XCTAssertEqual(diag.record.phase, .windDownStarted)
        XCTAssertEqual(diag.record.windDownTrigger, .proactive)
        XCTAssertEqual(diag.record.windDownStartedAt, clock.current)

        clock.advance(2)
        diag.markWindDownCompleted()
        XCTAssertEqual(diag.record.phase, .windDownCompleted)
        XCTAssertEqual(diag.record.windDownCompletedAt, clock.current)

        diag.markForegrounded()
        XCTAssertEqual(diag.record.phase, .foreground)
        XCTAssertNil(diag.record.backgroundedAt, "foreground resets the cycle")
        XCTAssertNil(diag.record.windDownTrigger)
    }

    func testWindDownRequiresBackgroundedFirst() {
        let diag = makeDiagnostics()
        // Straight from foreground: both marks must be ignored.
        diag.markWindDownStarted(trigger: .proactive)
        XCTAssertEqual(diag.record.phase, .foreground)
        diag.markWindDownCompleted()
        XCTAssertEqual(diag.record.phase, .foreground)
    }

    func testFirstWindDownTriggerWinsTheRace() {
        // Re-entrancy guard: the proactive path and the expiration handler can
        // both try to start the wind-down — the first caller's trigger sticks.
        let diag = makeDiagnostics()
        diag.markBackgrounded()
        diag.markWindDownStarted(trigger: .proactive)
        let startedAt = diag.record.windDownStartedAt
        clock.advance(5)
        diag.markWindDownStarted(trigger: .expiration)
        XCTAssertEqual(diag.record.windDownTrigger, .proactive, "second starter must be a no-op")
        XCTAssertEqual(diag.record.windDownStartedAt, startedAt)
    }

    func testCompletedIsIdempotentAndTerminalUntilNextCycle() {
        let diag = makeDiagnostics()
        diag.markBackgrounded()
        diag.markWindDownStarted(trigger: .proactive)
        diag.markWindDownCompleted()
        let completedAt = diag.record.windDownCompletedAt

        clock.advance(5)
        diag.markWindDownCompleted()
        XCTAssertEqual(diag.record.windDownCompletedAt, completedAt, "double-complete must be a no-op")
        diag.markWindDownStarted(trigger: .expiration)
        XCTAssertEqual(diag.record.phase, .windDownCompleted, "a completed cycle can't restart")

        // A new background cycle starts fresh.
        diag.markBackgrounded()
        XCTAssertEqual(diag.record.phase, .backgrounded)
        XCTAssertNil(diag.record.windDownTrigger)
    }

    // MARK: - Launch-time classification (previous process's record injected
    // via the shared UserDefaults store)

    func testDeathWhileBackgroundedClassifiesAsSuspect() {
        let previous = makeDiagnostics()
        previous.markBackgrounded()
        clock.advance(47)  // ...process killed here, nothing else recorded.

        let relaunch = makeDiagnostics()
        guard case .suspectBackgroundKill(let record) = relaunch.previousExit else {
            return XCTFail("backgrounded-without-wind-down must classify as a suspected kill")
        }
        XCTAssertEqual(record.phase, .backgrounded)
        XCTAssertTrue(relaunch.previousExitSummary.contains("SUSPECT"), relaunch.previousExitSummary)
        XCTAssertTrue(relaunch.previousExitSummary.contains("watchdog"), relaunch.previousExitSummary)
        XCTAssertTrue(relaunch.previousExitSummary.contains("sockets held"),
                      "summary must name the phase the process died in")
        XCTAssertEqual(relaunch.record.phase, .foreground, "the new run starts a fresh record")
    }

    func testDeathDuringWindDownClassifiesAsSuspectAndNamesThePhase() {
        let previous = makeDiagnostics()
        previous.markBackgrounded()
        clock.advance(42)
        previous.markWindDownStarted(trigger: .proactive)
        // ...killed mid-suspend/flush; completion never recorded.

        let relaunch = makeDiagnostics()
        guard case .suspectBackgroundKill(let record) = relaunch.previousExit else {
            return XCTFail("wind-down-started-without-completed must classify as a suspected kill")
        }
        XCTAssertEqual(record.phase, .windDownStarted)
        XCTAssertTrue(relaunch.previousExitSummary.contains("wind-down started"), relaunch.previousExitSummary)
        XCTAssertTrue(relaunch.previousExitSummary.contains("proactive"),
                      "summary must say which path started the wind-down")
        XCTAssertTrue(relaunch.previousExitSummary.contains("42s after backgrounding"),
                      "summary must place the death relative to backgrounding: \(relaunch.previousExitSummary)")
    }

    func testCompletedWindDownClassifiesAsClean() {
        let previous = makeDiagnostics()
        previous.markBackgrounded()
        clock.advance(25)
        previous.markWindDownStarted(trigger: .proactive)
        clock.advance(1)
        previous.markWindDownCompleted()
        // ...suspended app later jetsam'd/force-quit — normal, not a watchdog.

        let relaunch = makeDiagnostics()
        guard case .clean = relaunch.previousExit else {
            return XCTFail("a completed wind-down means any later death was a normal termination")
        }
        XCTAssertTrue(relaunch.previousExitSummary.hasPrefix("Clean"), relaunch.previousExitSummary)
        XCTAssertFalse(relaunch.previousExitSummary.contains("SUSPECT"))
    }

    func testForegroundExitClassifiesAsClean() {
        _ = makeDiagnostics()  // ran, stayed foreground, exited/crashed there

        let relaunch = makeDiagnostics()
        guard case .clean(let record) = relaunch.previousExit else {
            return XCTFail("a foreground record is not a background-watchdog suspect")
        }
        XCTAssertEqual(record.phase, .foreground)
        XCTAssertTrue(relaunch.previousExitSummary.contains("foreground"), relaunch.previousExitSummary)
    }

    func testExpirationTriggeredCompletionIsCleanButNamed() {
        let previous = makeDiagnostics()
        previous.markBackgrounded()
        previous.markWindDownStarted(trigger: .expiration)
        previous.markWindDownCompleted()

        let relaunch = makeDiagnostics()
        guard case .clean = relaunch.previousExit else {
            return XCTFail("an expiration-path completion still ended suspendable — clean")
        }
        XCTAssertTrue(relaunch.previousExitSummary.contains("expiration handler"),
                      "the last-resort path must be visible in the summary: \(relaunch.previousExitSummary)")
    }

    func testClassifyIsPure() {
        XCTAssertEqual(BackgroundExitDiagnostics.classify(nil), .none)
        func record(_ phase: BackgroundExitDiagnostics.Phase) -> BackgroundExitDiagnostics.Record {
            .init(phase: phase, updatedAt: clock.current)
        }
        for phase in [BackgroundExitDiagnostics.Phase.foreground, .windDownCompleted] {
            guard case .clean = BackgroundExitDiagnostics.classify(record(phase)) else {
                return XCTFail("\(phase) must classify clean")
            }
        }
        for phase in [BackgroundExitDiagnostics.Phase.backgrounded, .windDownStarted] {
            guard case .suspectBackgroundKill = BackgroundExitDiagnostics.classify(record(phase)) else {
                return XCTFail("\(phase) must classify as a suspected background kill")
            }
        }
    }
}

/// SessionManager's background choreography around the diagnostics and the
/// proactive wind-down: sockets held while the allowance is ample, clean
/// proactive suspension when it runs low, and a strictly synchronous
/// expiration handler as the last resort. Runs against a real local SSH
/// server (same harness as SessionManagerTests).
@MainActor
final class BackgroundWindDownTests: XCTestCase {
    private var server: SSHServer!
    private var shell: RecordingShell!
    private var hostKey: Curve25519.Signing.PrivateKey!
    private var clientKey: Curve25519.Signing.PrivateKey!
    private var port: Int!

    private var keyStore: KeyStore!
    private var serverStore: ServerStore!
    private var settings: AppSettings!
    private var profiles: ProfileStore!
    private var suiteName: String!
    private var diagnostics: BackgroundExitDiagnostics!
    private var manager: SessionManager!
    private var storedKey: SSHKey!

    override func setUp() async throws {
        try await super.setUp()
        hostKey = Curve25519.Signing.PrivateKey()
        clientKey = Curve25519.Signing.PrivateKey()
        shell = RecordingShell()
        for attempt in 0..<5 {
            let candidate = Int.random(in: 30000..<60000)
            do {
                server = try await SSHServer.host(
                    host: "127.0.0.1",
                    port: candidate,
                    hostKeys: [NIOSSHPrivateKey(ed25519Key: hostKey)],
                    authenticationDelegate: SingleKeyAuthDelegate(
                        allowedKey: NIOSSHPrivateKey(ed25519Key: clientKey).publicKey
                    )
                )
                server.enableShell(withDelegate: shell)
                port = candidate
                break
            } catch {
                if attempt == 4 { throw error }
            }
        }

        let suffix = UUID().uuidString
        suiteName = "BackgroundWindDownTests-\(suffix)"
        keyStore = KeyStore(
            secrets: InMemorySecretStore(),
            metadataURL: FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(suffix).json")
        )
        serverStore = ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("servers-\(suffix).json")
        )
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
        // The `none` multiplexer keeps the record-targets step inert — these
        // tests are about the wind-down timing, not reattach discovery.
        profiles = ProfileStore(
            agents: [],
            multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
        )
        diagnostics = BackgroundExitDiagnostics(defaults: defaults)
        manager = SessionManager(
            keyStore: keyStore,
            serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: profiles,
            diagnostics: diagnostics
        )
        storedKey = try keyStore.importKey(
            named: "test",
            openSSHPrivateKey: OpenSSHFixture.privateKeyPEM(for: clientKey)
        )
    }

    override func tearDown() async throws {
        // Ends any background task a test left open (idempotent) and closes
        // the sessions/sockets.
        manager?.appWillEnterForeground()
        manager?.closeAll()
        try? await server?.close()
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func openConnectedSession() async throws -> TerminalSession {
        let entry = Server(name: "test", host: "127.0.0.1", port: port, username: "aplusterminal-test", keyID: storedKey.id)
        serverStore.add(entry)
        let session = manager.open(server: entry)
        try await waitFor("session to connect") { session.state == .connected }
        return session
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 15,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(description)")
    }

    func testSocketsHeldWhileAllowanceIsAmple() async throws {
        // Build-6 intent preserved: with plenty of allowance left, backgrounding
        // must NOT tear anything down — a quick app-switch keeps the live session.
        let session = try await openConnectedSession()
        manager.backgroundTimeRemaining = { 3600 }
        manager.windDownPollInterval = 0.05

        manager.appDidEnterBackground()
        XCTAssertEqual(diagnostics.record.phase, .backgrounded)
        try await Task.sleep(for: .milliseconds(400))  // many poll ticks
        XCTAssertEqual(session.state, .connected, "sockets must stay open while the allowance is ample")
        XCTAssertEqual(diagnostics.record.phase, .backgrounded, "no wind-down while parked")

        manager.appWillEnterForeground()
        XCTAssertEqual(session.state, .connected, "quick switch back keeps the live session")
        XCTAssertEqual(session.reconnectAttempts, 0)
        XCTAssertEqual(diagnostics.record.phase, .foreground)
    }

    func testProactiveWindDownWhenAllowanceRunsLow() async throws {
        // The core watchdog fix: remaining allowance below the safety margin
        // must trigger the full clean wind-down (real disconnect + flush) from
        // the poll loop — never from the expiration handler.
        let session = try await openConnectedSession()
        manager.backgroundTimeRemaining = { SessionManager.windDownSafetyMargin - 5 }
        manager.windDownPollInterval = 0.05

        manager.appDidEnterBackground()
        try await waitFor("proactive wind-down to suspend the session") { session.state == .suspended }
        try await waitFor("wind-down record to complete") { self.diagnostics.record.phase == .windDownCompleted }
        XCTAssertEqual(diagnostics.record.windDownTrigger, .proactive,
                       "the poll loop, not the expiration handler, must have wound down")
    }

    func testExpirationHandlerIsSynchronousLastResort() async throws {
        // If the expiration handler ever fires, it must mark state and finish
        // SYNCHRONOUSLY — assertions run immediately after the plain call,
        // with no awaits in between.
        let session = try await openConnectedSession()
        manager.backgroundTimeRemaining = { 3600 }  // proactive path never trips
        manager.windDownPollInterval = 0.05
        manager.appDidEnterBackground()
        XCTAssertEqual(diagnostics.record.phase, .backgrounded)

        manager.handleBackgroundTaskExpiration()

        XCTAssertEqual(session.state, .suspended,
                       "expiration must mark the session suspended synchronously (no network teardown)")
        XCTAssertEqual(diagnostics.record.phase, .windDownCompleted)
        XCTAssertEqual(diagnostics.record.windDownTrigger, .expiration)
    }

    func testExpirationAfterProactiveWindDownIsANoOp() async throws {
        // Re-entrancy: a late expiration must not restart or re-mark anything.
        let session = try await openConnectedSession()
        manager.backgroundTimeRemaining = { 1 }
        manager.windDownPollInterval = 0.05
        manager.appDidEnterBackground()
        try await waitFor("proactive wind-down") { self.diagnostics.record.phase == .windDownCompleted }

        manager.handleBackgroundTaskExpiration()

        XCTAssertEqual(session.state, .suspended)
        XCTAssertEqual(diagnostics.record.phase, .windDownCompleted)
        XCTAssertEqual(diagnostics.record.windDownTrigger, .proactive,
                       "the proactive trigger must survive a late expiration call")
    }

    func testForegroundAfterProactiveWindDownShowsPausedSession() async throws {
        // After a full background cycle the user returns: the record flips to
        // foreground and the session stays a paused card (no auto-reconnect).
        let session = try await openConnectedSession()
        manager.backgroundTimeRemaining = { 1 }
        manager.windDownPollInterval = 0.05
        manager.appDidEnterBackground()
        try await waitFor("proactive wind-down") { session.state == .suspended }

        manager.appWillEnterForeground()
        XCTAssertEqual(diagnostics.record.phase, .foreground)
        XCTAssertEqual(session.state, .suspended, "reconnect stays the user's choice")
        XCTAssertEqual(session.reconnectAttempts, 0)
    }

    func testBackgroundWithoutConnectedSessionsIsInert() async throws {
        // No connected sessions → no background task, no diagnostics cycle:
        // an idle backgrounded app that iOS later reclaims must NOT read as a
        // watchdog suspect on the next launch.
        manager.appDidEnterBackground()
        XCTAssertEqual(diagnostics.record.phase, .foreground)
    }
}
