import ActivityKit
import UIKit
import XCTest
@testable import aPlusTerminal

/// A custom agent end to end against a REAL SSH server and a REAL Live
/// Activity in the simulator: a profile made the way Settings › Agents makes
/// one (user profiles file + an icon through the crop pipeline), a session
/// to the build machine's sshd, and a command whose OUTPUT carries the
/// agent's marker while its echo does not. Asserts the running Activity's
/// content names the custom icon and that the PNG sits where the widget
/// reads it.
///
/// Skipped unless `APLUSTERMINAL_LIVE_QA=1`; CI never runs it. App-hosted, so
/// the scheme forwards the settings into the host app (pass them unprefixed):
///   xcodebuild test ... -only-testing:aPlusTerminalTests/CustomAgentLiveTests \
///     APLUSTERMINAL_LIVE_QA=1 \
///     APLUSTERMINAL_TEST_SERVER='{"name":"LiveQA","host":"127.0.0.1","port":22,"username":"<user>"}'
/// The SSH key is NOT passed on that command line: xcodebuild echoes every
/// build setting into its log. The test reads `~/.ssh/aplus_probe` from the
/// host itself (the simulator shares the host filesystem).
@MainActor
final class CustomAgentLiveTests: XCTestCase {
    private struct Seed: Decodable {
        let host: String
        let port: Int
        let username: String
    }

    private let agentID = "custom-fake-agent-live01"
    private var dir: URL!
    private var manager: SessionManager?

    override func tearDown() async throws {
        manager?.closeAll()
        CustomAgentIconStore.clear(for: agentID)
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    /// The probe key's OpenSSH file, read straight from the host's
    /// `~/.ssh/aplus_probe`. A base64 key given the old way, as a build
    /// setting, still wins, but that way echoes it into the log.
    private static func probeKey(env: [String: String]) throws -> Data {
        if let legacy = env["APLUSTERMINAL_TEST_PRIVATE_KEY"], !legacy.isEmpty {
            return try XCTUnwrap(Data(base64Encoded: legacy), "APLUSTERMINAL_TEST_PRIVATE_KEY is not base64")
        }
        var home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        if env["SIMULATOR_HOST_HOME"] == nil, let range = home.range(of: "/Library/Developer/") {
            home = String(home[..<range.lowerBound])
        }
        let path = "\(home)/.ssh/aplus_probe"
        return try XCTUnwrap(FileManager.default.contents(atPath: path),
                             "no probe key at \(path) — live QA needs it to log in to this Mac")
    }

    func testCustomAgentOverRealSSHReachesLiveActivityWithIcon() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        // Opted in: from here on, a missing input is a FAILURE, never a skip.
        let seedJSON = try XCTUnwrap(
            env["APLUSTERMINAL_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 },
            "APLUSTERMINAL_TEST_SERVER not forwarded into the host app")
        let seed = try JSONDecoder().decode(Seed.self, from: Data(seedJSON.utf8))
        let pemData = try Self.probeKey(env: env)
        XCTAssertTrue(ActivityAuthorizationInfo().areActivitiesEnabled,
                      "Live Activities must be enabled in this simulator for the live run")

        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The agent, as the Agents screen saves it.
        let profiles = ProfileStore(userFileURL: dir.appendingPathComponent("profiles.json"))
        try profiles.upsert(AgentProfile(
            id: agentID, displayName: "Fake Agent", detectionMarkers: ["FakeAgent v1 ready"],
            attachTemplate: "{path} ", builtIn: false))
        XCTAssertNotNil(profiles.agent(id: "claude-code"), "auto mode still carries the built-ins")
        // A non-square source: the store must crop it to the 360px square.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).pngData { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.systemYellow.setFill()
            ctx.fill(CGRect(x: 100, y: 50, width: 100, height: 100))
        }
        XCTAssertTrue(CustomAgentIconStore.save(icon, for: agentID))

        let keyStore = KeyStore(secrets: InMemorySecretStore(), metadataURL: dir.appendingPathComponent("keys.json"))
        let key = try keyStore.importKey(named: "live", openSSHPrivateKey: String(decoding: pemData, as: UTF8.self))
        let serverStore = ServerStore(fileURL: dir.appendingPathComponent("servers.json"))
        let server = Server(name: "agents-live", host: seed.host, port: seed.port, username: seed.username, keyID: key.id)
        serverStore.add(server)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "CustomAgentLiveTests-\(UUID().uuidString)")!)
        settings.defaultMultiplexerProfileID = "none"  // a plain shell: nothing but our command on screen
        XCTAssertEqual(settings.defaultAgentProfileID, "auto")
        XCTAssertTrue(settings.agentMascotIcons)

        let manager = SessionManager(
            keyStore: keyStore, serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings, profiles: profiles)
        self.manager = manager
        let session = manager.open(server: server)
        try await waitFor("connect", timeout: 30) { session.state == .connected }
        try await Task.sleep(for: .seconds(2))  // login banner + prompt settle
        XCTAssertNil(session.agentMonitor.detected, "nothing named before the agent starts")

        // The marker is in the OUTPUT only: the echoed command reads
        // "printf 'Fake%sAgent v1 ready…", which never matches.
        session.sendInput(Data("printf 'Fake%sAgent v1 ready\\n' ''; sleep 600\r".utf8))
        try await waitFor("custom agent to latch", timeout: 10) { session.agentMonitor.detected?.id == self.agentID }
        XCTAssertEqual(session.effectiveAgentIconName, "agent-\(agentID)")

        let expected = "agent-\(agentID)"
        try await waitFor("Live Activity content to carry \(expected)", timeout: 10) {
            Activity<SessionActivityAttributes>.activities.contains { activity in
                activity.content.state.sessions.contains { $0.id == session.id && $0.agentIconName == expected }
            }
        }

        // …and the widget process can draw it: the PNG is at the App Group
        // path AgentGlyph reads, square and normalized.
        let container = try XCTUnwrap(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.aaroncx.aplusterminal"))
        let widgetPath = container.appendingPathComponent("AgentIcons/\(agentID).png").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: widgetPath), "PNG at \(widgetPath)")
        let stored = try XCTUnwrap(UIImage(contentsOfFile: widgetPath)?.cgImage)
        XCTAssertEqual(stored.width, 360)
        XCTAssertEqual(stored.height, 360)
        XCTAssertEqual(CustomAgentIconStore.source(forIconName: expected), .custom(URL(fileURLWithPath: widgetPath)))

        session.sendInput(Data([0x03]))  // ^C the sleep
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(description)")
        throw XCTSkip("stopping after a failed wait")  // already failed above; don't cascade
    }
}
