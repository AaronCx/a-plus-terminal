import CoreGraphics
import RoyalVNCKit
import XCTest
@testable import aPlusTerminal

/// Scripted `VNCConnecting` for driving the session state machine without a
/// network (brief §4.7).
@MainActor
private final class MockVNCConnection: VNCConnecting {
    weak var delegate: VNCConnectingDelegate?
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0

    func connect() { connectCalls += 1 }
    func disconnect() { disconnectCalls += 1 }

    func emit(_ state: VNCWireState) {
        delegate?.vncConnection(self, didChangeState: state)
    }

    func requestCredential(
        _ type: VNCAuthenticationType,
        completion: @escaping (VNCSuppliedCredential?) -> Void
    ) {
        delegate?.vncConnection(self, credentialFor: type, completion: completion)
    }

    func emitFrame(_ image: CGImage, size: CGSize) {
        delegate?.vncConnection(self, didUpdateFrame: image, size: size)
    }
}

@MainActor
private final class MockConnectionFactory {
    private(set) var created: [MockVNCConnection] = []
    var latest: MockVNCConnection { created.last! }

    func make(_ server: Server) -> VNCConnecting {
        let connection = MockVNCConnection()
        created.append(connection)
        return connection
    }
}

private func testImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    )!
    return context.makeImage()!
}

@MainActor
final class VNCMonitorSessionTests: XCTestCase {
    private var passwords: PasswordStore!
    private var factory: MockConnectionFactory!

    override func setUp() {
        super.setUp()
        passwords = PasswordStore(secrets: InMemorySecretStore())
        factory = MockConnectionFactory()
    }

    private func makeSession(authMethod: VNCAuthMethod = .ard, password: String? = "sekret") throws -> VNCMonitorSession { // lastgate-ignore (test fixture)
        var server = Server(
            name: "studio", host: "studio.local", port: 5900, username: "aaron",
            kind: .vncMonitor, vncAuthMethod: authMethod
        )
        if let password {
            let ref = UUID()
            try passwords.setPassword(password, for: ref)
            server.passwordRef = ref
        }
        return VNCMonitorSession(server: server, passwords: passwords, makeConnection: factory.make)
    }

    func testConnectFlowReachesConnectedThroughAuthentication() throws {
        let session = try makeSession()
        XCTAssertEqual(session.state, .idle)
        session.connect()
        XCTAssertEqual(session.state, .connecting)
        XCTAssertEqual(factory.latest.connectCalls, 1)

        var supplied: VNCSuppliedCredential??
        factory.latest.requestCredential(.appleRemoteDesktop) { supplied = $0 }
        XCTAssertEqual(session.state, .authenticating, "a credential request marks the session authenticating")
        XCTAssertEqual(supplied, .usernamePassword(username: "aaron", password: "sekret")) // lastgate-ignore (test fixture)

        factory.latest.emit(.connected)
        XCTAssertEqual(session.state, .connected)
    }

    func testClassicVNCAuthSuppliesPasswordOnly() throws {
        let session = try makeSession(authMethod: .vncPassword)
        session.connect()
        var supplied: VNCSuppliedCredential??
        factory.latest.requestCredential(.vnc) { supplied = $0 }
        XCTAssertEqual(supplied, .password("sekret")) // lastgate-ignore (test fixture)
    }

    func testMissingCredentialCompletesNil() throws {
        let session = try makeSession(password: nil)
        session.connect()
        var supplied: VNCSuppliedCredential? = .password("sentinel")
        factory.latest.requestCredential(.appleRemoteDesktop) { supplied = $0 }
        XCTAssertNil(supplied, "no stored password → nil credential, auth failure surfaces normally")
    }

    func testAuthFailureProducesReadableError() throws {
        let session = try makeSession()
        session.connect()
        factory.latest.emit(.disconnected(VNCError.authentication(.ardAuthenticationFailed)))
        guard case .failed(let message) = session.state else {
            return XCTFail("expected .failed, got \(session.state)")
        }
        XCTAssertTrue(message.contains("Authentication failed"), "auth failures name the problem: \(message)")
    }

    func testTransportDropRetriesOnceThenFails() throws {
        let session = try makeSession()
        session.connect()
        factory.latest.emit(.connected)
        XCTAssertEqual(session.state, .connected)

        factory.latest.emit(.disconnected(VNCError.connection(.failed(nil))))
        XCTAssertEqual(session.state, .reconnecting, "an established monitor retries a transport drop once")
        XCTAssertEqual(factory.created.count, 2, "the retry opens a fresh connection")
        XCTAssertEqual(factory.latest.connectCalls, 1)

        factory.latest.emit(.disconnected(VNCError.connection(.failed(nil))))
        guard case .failed = session.state else {
            return XCTFail("second failure surfaces, got \(session.state)")
        }
    }

    func testHostClosingTheConnectionSurfacesAsFailure() throws {
        let session = try makeSession()
        session.connect()
        factory.latest.emit(.connected)
        factory.latest.emit(.disconnected(nil))
        XCTAssertEqual(session.state, .failed("The host closed the connection."))
    }

    func testSuspendThenRetryReconnects() throws {
        let session = try makeSession()
        session.connect()
        factory.latest.emit(.connected)
        let first = factory.latest

        session.suspend()
        XCTAssertEqual(session.state, .suspended)
        XCTAssertEqual(first.disconnectCalls, 1)
        first.emit(.disconnected(nil))
        XCTAssertEqual(session.state, .suspended, "the wire's late disconnect event keeps the suspended state")

        session.retry()
        XCTAssertEqual(session.state, .connecting)
        XCTAssertEqual(factory.created.count, 2)
    }

    func testCloseIsTerminal() throws {
        let session = try makeSession()
        session.connect()
        let connection = factory.latest
        factory.latest.emit(.connected)
        session.close()
        XCTAssertEqual(session.state, .closed)
        XCTAssertEqual(connection.disconnectCalls, 1)
        connection.emit(.disconnected(nil))
        XCTAssertEqual(session.state, .closed, "events after close never resurrect the session")
    }

    func testFrameUpdatesStoreImageAndFirePipInvalidate() throws {
        let session = try makeSession()
        session.connect()
        factory.latest.emit(.connected)
        var invalidations = 0
        session.pipInvalidate = { invalidations += 1 }
        factory.latest.emitFrame(testImage(), size: CGSize(width: 4, height: 4))
        XCTAssertNotNil(session.lastFrame)
        XCTAssertEqual(session.framebufferSize, CGSize(width: 4, height: 4))
        XCTAssertEqual(invalidations, 1)
    }
}

/// Frame pacing with a trailing edge (build-31 lag fix): bursts suppress to
/// one emit per window plus ONE trailing re-emit, so the last frame of a
/// burst always lands.
final class VNCFrameThrottleTests: XCTestCase {
    func testBurstEmitsLeadingThenSchedulesExactlyOneTrailing() {
        let throttle = VNCFrameThrottle(minInterval: 10)
        XCTAssertEqual(throttle.decide(force: false), .emit, "first frame emits immediately")
        XCTAssertEqual(throttle.decide(force: false), .suppressed(scheduleTrailing: true),
                       "first suppression schedules the trailing re-emit")
        XCTAssertEqual(throttle.decide(force: false), .suppressed(scheduleTrailing: false),
                       "later suppressions in the same window schedule nothing")
    }

    func testTrailingGateEmitsAfterWindowAndIsRedundantAfterFreshEmit() async throws {
        let throttle = VNCFrameThrottle(minInterval: 0.05)
        XCTAssertEqual(throttle.decide(force: false), .emit)
        XCTAssertEqual(throttle.decide(force: false), .suppressed(scheduleTrailing: true))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(throttle.trailingGate(), "past the window, the trailing pass emits")

        // A regular emit right before the trailing fire makes it redundant.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(throttle.decide(force: false), .emit)
        XCTAssertEqual(throttle.decide(force: false), .suppressed(scheduleTrailing: true))
        XCTAssertFalse(throttle.trailingGate(), "inside the window after an emit, trailing skips")
    }

    func testForceBypassesTheWindow() {
        let throttle = VNCFrameThrottle(minInterval: 10)
        XCTAssertEqual(throttle.decide(force: false), .emit)
        XCTAssertEqual(throttle.decide(force: true), .emit, "framebuffer create/resize always emits")
    }
}

/// Single-slot delivery (build-31 lag fix): only the newest frame hops to
/// the main actor, one hop in flight.
final class VNCLatestFrameBoxTests: XCTestCase {
    func testOnlyNewestFrameSurvivesAndOneHopRuns() {
        let box = VNCLatestFrameBox()
        let img = testImage()
        XCTAssertTrue(box.submit(img, size: CGSize(width: 1, height: 1)), "first submit starts a hop")
        XCTAssertFalse(box.submit(img, size: CGSize(width: 2, height: 2)), "second submit coalesces")
        XCTAssertFalse(box.submit(img, size: CGSize(width: 3, height: 3)))
        XCTAssertEqual(box.take()?.size, CGSize(width: 3, height: 3), "the newest frame wins")
        XCTAssertNil(box.take(), "drained — in-flight cleared")
        XCTAssertTrue(box.submit(img, size: CGSize(width: 4, height: 4)), "next submit starts a fresh hop")
    }
}

/// Session reuse rules: an edited monitor must reconnect with the NEW
/// config, not re-present a stale session (review finding).
@MainActor
final class VNCMonitorManagerTests: XCTestCase {
    func testOpenAfterEditReplacesStaleSessionSoRetryUsesNewConfig() {
        let passwords = PasswordStore(secrets: InMemorySecretStore())
        let manager = VNCMonitorManager(passwords: passwords, makeConnection: { _ in MockVNCConnection() })
        var server = Server(name: "studio", host: "studio.local", port: 5901, username: "",
                            kind: .vncMonitor, vncAuthMethod: VNCAuthMethod.none)
        let stale = manager.open(server: server)
        XCTAssertEqual(manager.sessions.count, 1)

        server.port = 5900
        let fresh = manager.open(server: server)
        XCTAssertFalse(fresh === stale, "a config edit opens a fresh session")
        XCTAssertEqual(fresh.server.port, 5900, "the fresh session carries the edited config")
        XCTAssertEqual(stale.state, .closed, "the stale session was closed, not leaked")
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.presented === fresh)
    }

    func testOpenWithUnchangedConfigReusesTheExistingSession() {
        let passwords = PasswordStore(secrets: InMemorySecretStore())
        let manager = VNCMonitorManager(passwords: passwords, makeConnection: { _ in MockVNCConnection() })
        let server = Server(name: "studio", host: "studio.local", port: 5900, username: "",
                            kind: .vncMonitor, vncAuthMethod: VNCAuthMethod.none)
        let first = manager.open(server: server)
        let second = manager.open(server: server)
        XCTAssertTrue(first === second, "same config re-presents the running monitor")
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testCloseNotifiesThePopOutHook() {
        let passwords = PasswordStore(secrets: InMemorySecretStore())
        let manager = VNCMonitorManager(passwords: passwords, makeConnection: { _ in MockVNCConnection() })
        let server = Server(name: "studio", host: "studio.local", port: 5900, username: "",
                            kind: .vncMonitor, vncAuthMethod: VNCAuthMethod.none)
        let session = manager.open(server: server)
        var closed: [UUID] = []
        manager.pipSessionClosed = { closed.append($0.id) }
        manager.close(session)
        XCTAssertEqual(closed, [session.id], "closing a monitor tells the PiP coordinator to let go")
    }
}

/// The VNC pop-out source paces invalidations at ≤5 fps ahead of the
/// engine's own coalescer (brief §4.3).
@MainActor
final class VNCFrameSourceTests: XCTestCase {
    func testFramePacingCapsInvalidationsAtFiveFPS() async throws {
        let passwords = PasswordStore(secrets: InMemorySecretStore())
        let server = Server(name: "m", host: "h", username: "", kind: .vncMonitor, vncAuthMethod: VNCAuthMethod.none)
        let session = VNCMonitorSession(server: server, passwords: passwords, makeConnection: { _ in MockVNCConnection() })
        let source = VNCFrameSource(session: session, maxFrameInterval: 0.2)
        var signals = 0
        source.onInvalidate = { signals += 1 }
        let start = Date()
        while Date().timeIntervalSince(start) < 0.45 {
            source.noteFrame()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThanOrEqual(signals, 1)
        XCTAssertLessThanOrEqual(signals, 4, "30 fps of frames collapse to ≤5 fps of pop-out invalidations")
        source.detach()
    }
}

/// Server model migration for the new kind/auth fields (ServerStore pattern).
final class ServerKindCodableTests: XCTestCase {
    func testLegacyJSONWithoutKindDecodesAsSSH() throws {
        let legacy = Data("""
        [{"id":"\(UUID().uuidString)","name":"box","host":"box.local","username":"acx"}]
        """.utf8)
        let servers = try JSONDecoder().decode([Server].self, from: legacy)
        XCTAssertEqual(servers.first?.kind, .ssh, "pre-VNC saved lists stay SSH servers")
        XCTAssertNil(servers.first?.vncAuthMethod)
    }

    func testVNCMonitorRoundTripsKindAndAuthMethod() throws {
        let server = Server(
            name: "studio", host: "studio.local", port: 5900, username: "aaron",
            kind: .vncMonitor, vncAuthMethod: .ard, passwordRef: UUID()
        )
        let data = try JSONEncoder().encode([server])
        let decoded = try JSONDecoder().decode([Server].self, from: data)
        XCTAssertEqual(decoded.first?.kind, .vncMonitor)
        XCTAssertEqual(decoded.first?.vncAuthMethod, .ard)
        XCTAssertEqual(decoded.first?.passwordRef, server.passwordRef)
    }

    func testStoredJSONNeverContainsPasswordMaterial() throws {
        var server = Server(
            name: "studio", host: "studio.local", username: "aaron",
            kind: .vncMonitor, vncAuthMethod: .vncPassword
        )
        server.passwordRef = UUID()
        let json = String(decoding: try JSONEncoder().encode([server]), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("password\":"), "only the UUID ref is stored")
        XCTAssertTrue(json.contains("passwordRef"))
    }

    func testDisplayAddressOmitsDefaultVNCPort() {
        let vnc = Server(name: "m", host: "studio.local", port: 5900, username: "", kind: .vncMonitor)
        XCTAssertEqual(vnc.displayAddress, "studio.local")
        let ssh = Server(name: "s", host: "studio.local", port: 22, username: "acx")
        XCTAssertEqual(ssh.displayAddress, "studio.local")
        let odd = Server(name: "m", host: "studio.local", port: 5901, username: "", kind: .vncMonitor)
        XCTAssertEqual(odd.displayAddress, "studio.local:5901")
    }
}
