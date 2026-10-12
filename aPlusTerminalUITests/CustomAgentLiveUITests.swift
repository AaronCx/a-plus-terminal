import UIKit
import XCTest

/// A custom agent end to end in the real app against a real SSH server (the
/// build machine's sshd): a "Fake Agent" seeded the way Settings › Agents
/// stores one (user profiles file + an icon through the crop pipeline), a
/// session opened from the server list, and a command whose OUTPUT carries
/// the agent's marker while its echo does not. Asserts the session row draws
/// the CUSTOM icon (not the bundled or generic doodle), then backgrounds the
/// app so the Live Activity / Dynamic Island shows it, holding long enough
/// for a host-side `simctl io screenshot`.
///
/// The Live Activity's content state and the App Group PNG are asserted
/// in-process by `CustomAgentLiveTests` (unit target); a UI test can't read
/// ActivityKit state.
///
/// Skipped unless `APLUSTERMINAL_LIVE_QA=1`; CI never runs it. Pass the
/// settings unprefixed to xcodebuild (the scheme forwards them):
///   xcodebuild test ... -only-testing:aPlusTerminalUITests/CustomAgentLiveUITests \
///     APLUSTERMINAL_LIVE_QA=1 \
///     APLUSTERMINAL_TEST_SERVER='{"name":"LiveQA","host":"127.0.0.1","port":22,"username":"<user>"}' \
///     APLUSTERMINAL_TEST_PRIVATE_KEY='<base64 OpenSSH pem>'
final class CustomAgentLiveUITests: XCTestCase {
    /// Unique per run: a launch that skipped its seed can't pass on an agent
    /// (and icon) an earlier run left behind.
    private let agentID = "custom-fake-agent-" + UUID().uuidString.prefix(8).lowercased()
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_LIVE_QA"] == "1", "live QA disabled (set APLUSTERMINAL_LIVE_QA=1)")
        continueAfterFailure = false
        // Opted in: from here on, a missing input is a FAILURE, never a skip.
        let server = try XCTUnwrap(env["APLUSTERMINAL_TEST_SERVER"].flatMap { $0.isEmpty ? nil : $0 },
                                   "APLUSTERMINAL_TEST_SERVER not forwarded to the runner")
        let key = try XCTUnwrap(env["APLUSTERMINAL_TEST_PRIVATE_KEY"].flatMap { $0.isEmpty ? nil : $0 },
                                "APLUSTERMINAL_TEST_PRIVATE_KEY not forwarded to the runner")

        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = server
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = key
        app.launchEnvironment["APLUSTERMINAL_TEST_RESET_AGENTS"] = "1"
        app.launchEnvironment["APLUSTERMINAL_TEST_AGENT_PROFILES"] = """
            {"agents":[{"id":"\(agentID)","displayName":"Fake Agent","detectionMarkers":["fakeagent v1 ready"]}]}
            """
        app.launchEnvironment["APLUSTERMINAL_TEST_AGENT_ICON_ID"] = agentID
        app.launchEnvironment["APLUSTERMINAL_TEST_AGENT_ICON_BASE64"] = Self.iconPNG().base64EncodedString()
        XCTAssertNotNil(app.launchProvingAgentSeed(),
                        "the app never proved it applied the Fake Agent seed (profiles file + icon)")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Non-square on purpose (the store must crop it), and loud enough to
    /// spot in a Dynamic Island screenshot: a yellow square on magenta.
    private static func iconPNG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).pngData { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.systemYellow.setFill()
            ctx.fill(CGRect(x: 100, y: 50, width: 100, height: 100))
        }
    }

    private func shot(_ name: String, screen: Bool = false) {
        let attachment = XCTAttachment(screenshot: screen ? XCUIScreen.main.screenshot() : app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var seededServerName: String {
        let json = ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_SERVER"] ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return obj?["name"] as? String ?? "LiveQA"
    }

    /// Same input path as TerminalLiveQAUITests: the shared pasteboard and
    /// the accessory bar's Paste button.
    private func paste(_ text: String) {
        UIPasteboard.general.string = text
        app.buttons["Paste"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    func testCustomAgentIconOnSessionRowAndLiveActivity() throws {
        let row = app.staticTexts[seededServerName]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded server row \(seededServerName)")
        row.tap()
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 20), "connected (accessory bar up)")
        let tutorial = app.buttons["Continue"]  // first keyboard on a fresh simulator
        if tutorial.waitForExistence(timeout: 2) { tutorial.tap() }
        sleep(2)  // login banner + prompt settle

        // The echo reads "printf 'Fake%sAgent v1 ready…" — no marker. Only
        // the command's OUTPUT says "FakeAgent v1 ready".
        paste("printf 'Fake%sAgent v1 ready\\n' '' ; sleep 600\n")
        sleep(3)
        shot("01-marker-printed")

        // Back to the session list: the row must draw the user's PNG.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let customIcon = app.descendants(matching: .any)["agentIcon.custom.\(agentID)"]
        XCTAssertTrue(customIcon.waitForExistence(timeout: 10),
                      "session row draws the custom agent's own icon")
        XCTAssertFalse(app.descendants(matching: .any)["agentIcon.generic.\(agentID)"].exists)
        XCTAssertEqual(customIcon.label, "Fake Agent")
        shot("02-session-row-custom-icon")

        // Dynamic Island / Live Activity: leave the app and hold, so the
        // host can capture it with `simctl io <udid> screenshot`.
        XCUIDevice.shared.press(.home)
        sleep(6)
        shot("03-island-custom-icon", screen: true)
        sleep(14)
        shot("04-island-later", screen: true)
    }
}
