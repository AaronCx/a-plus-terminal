import XCTest

/// iPhone Duo (the foldable): unfolded, the app fills the inner display
/// instead of running letterboxed, and folding and unfolding mid-session
/// keeps the session and resizes the pty the server sees.
///
/// Runs on CI only, from `.github/workflows/duo.yml` on the iPhone Duo
/// simulator built with the iOS 27.1 SDK. That job starts a throwaway
/// loopback sshd (`scripts/duo-ci-sshd.sh`) whose login writes the pty size
/// the SERVER sees to `~/.aplus-duo/grid.txt`, records the Duo's display
/// sizes from its device profile in `~/.aplus-duo/display.txt`, and runs a
/// host-side pose driver (`scripts/duo-pose-driver.sh`) that folds and
/// unfolds the simulator when this test asks through
/// `~/.aplus-duo/pose-request` — XCUITest cannot fold a device. The
/// simulator shares the host filesystem, so the seed, the key and the grid
/// all come from files and nothing secret crosses a build setting.
///
/// Skipped unless the runner passes `APLUSTERMINAL_DUO=1`; the workflow then
/// checks the result bundle, so a skip there fails the job instead of passing.
final class DuoLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["APLUSTERMINAL_DUO"] == "1", "Duo layout runs only in duo.yml (set APLUSTERMINAL_DUO=1)")
        continueAfterFailure = false
        let server = try XCTUnwrap(FileManager.default.contents(atPath: "\(duoDir)/server.json"),
                                   "no \(duoDir)/server.json — scripts/duo-ci-sshd.sh start did not run")
        let key = try XCTUnwrap(FileManager.default.contents(atPath: "\(duoDir)/client_ed25519"),
                                "no client key in \(duoDir)")
        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = String(decoding: server, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = key.base64EncodedString()
        addUIInterruptionMonitor(withDescription: "system alert") { alert in
            for title in ["Allow", "Allow While Using App", "OK", "Continue", "Don't Allow"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        try pose("unfolded")
        print("DUO: setUp launching")
        app.launch()
        print("DUO: setUp launched, state \(app.state.rawValue)")
        // On Xcode 26 a launch has intermittently arrived without its
        // launchEnvironment (see AgentNotificationLiveUITests). The seeded
        // server row is the proof this launch got it; relaunch once if not.
        if !app.staticTexts["Duo"].waitForExistence(timeout: 10) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.staticTexts["Duo"].waitForExistence(timeout: 15),
                      "the seeded Duo server never appeared — the launch got no seed")
    }

    // MARK: - Tests

    /// Unfolded, the app's window is the whole inner display: built with the
    /// iOS 27.1 SDK it is not letterboxed into a phone-sized box.
    func testUnfoldedWindowFillsTheInnerDisplay() throws {
        try capture("01-launch")
        let displays = try XCTUnwrap(displaySizes(), "duo.yml wrote no display sizes")
        let inner = try XCTUnwrap(displays[3], "no inner display (3) among \(displays)")
        let window = app.windows.firstMatch.frame
        // The runner's own display scale (both Duo panels are @3x).
        let traitScale = UITraitCollection.current.displayScale
        let scale = traitScale > 0 ? traitScale : 3
        record("displays \(displays) px, window \(window) pt @\(scale)x, app \(app.frame)")
        // The window in pixels, in either orientation of the panel.
        let px = CGSize(width: window.width * scale, height: window.height * scale)
        let fills = (abs(px.width - inner.width) <= scale && abs(px.height - inner.height) <= scale)
            || (abs(px.width - inner.height) <= scale && abs(px.height - inner.width) <= scale)
        XCTAssertTrue(fills, "not filling the inner display: window \(window) pt = \(px) px on a \(inner.width)x\(inner.height) px panel")
        XCTAssertEqual(window.minX, 0, accuracy: 1, "window is inset from the display: \(window)")
        XCTAssertEqual(window.minY, 0, accuracy: 1, "window is inset from the display: \(window)")
    }

    /// A live session through unfolded -> folded -> unfolded -> folded: the
    /// app stays in the foreground, the session stays connected, and the pty
    /// the server sees follows the display — fewer columns on the outer
    /// panel, and each return to a pose restores that pose's grid.
    func testFoldingMidSessionResizesTheGrid() throws {
        openSession()
        let unfolded = try grid(after: nil)
        try capture("02-session-unfolded")
        record("unfolded grid \(unfolded), window \(app.windows.firstMatch.frame)")

        try pose("folded")
        let folded = try grid(after: unfolded)
        XCTAssertEqual(app.state, .runningForeground, "folding sent the app away")
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 20), "folding dropped the session screen")
        try capture("03-session-folded")
        record("folded grid \(folded), window \(app.windows.firstMatch.frame)")
        XCTAssertLessThan(folded.cols, unfolded.cols, "the outer panel must fit fewer columns than the inner one")

        try pose("unfolded")
        let reopened = try grid(after: folded)
        XCTAssertEqual(app.state, .runningForeground, "unfolding sent the app away")
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 20), "unfolding dropped the session screen")
        try capture("04-session-unfolded-again")
        record("unfolded-again grid \(reopened)")
        XCTAssertEqual(reopened.cols, unfolded.cols, "unfolding again did not restore the inner panel's columns")

        try pose("folded")
        let refolded = try grid(after: reopened)
        XCTAssertEqual(app.state, .runningForeground, "folding again sent the app away")
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 20), "folding again dropped the session screen")
        try capture("05-session-folded-again")
        record("folded-again grid \(refolded)")
        XCTAssertEqual(refolded.cols, folded.cols, "folding again did not restore the outer panel's columns")
    }

    // MARK: - Helpers

    /// The host home directory, seen from inside the simulator.
    private var hostHome: String {
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] { return home }
        let path = NSHomeDirectory()
        if let range = path.range(of: "/Library/Developer/") { return String(path[..<range.lowerBound]) }
        return path
    }

    private var duoDir: String { "\(hostHome)/.aplus-duo" }

    private struct Grid: Equatable, CustomStringConvertible {
        var rows: Int
        var cols: Int
        var description: String { "\(cols)x\(rows)" }
    }

    /// The pty size the server sees, once it differs from `previous` (or
    /// once there is one) and has held still for a second — a fold animates
    /// through intermediate sizes.
    private func grid(after previous: Grid?, timeout: TimeInterval = 30) throws -> Grid {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Grid?
        var stableSince = Date()
        while Date() < deadline {
            if let current = readGrid(), current.cols > 2, current != previous {
                if current != last {
                    last = current
                    stableSince = Date()
                } else if Date().timeIntervalSince(stableSince) >= 1 {
                    return current
                }
            }
            usleep(250_000)
        }
        throw GridTimeout(previous: previous, last: last ?? readGrid())
    }

    private struct GridTimeout: Error, CustomStringConvertible {
        var previous: Grid?
        var last: Grid?
        var description: String {
            "the server's pty size never moved off \(previous.map(\.description) ?? "nothing") (last seen \(last.map(\.description) ?? "none"))"
        }
    }

    private func readGrid() -> Grid? {
        guard let text = try? String(contentsOfFile: "\(duoDir)/grid.txt", encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Grid(rows: parts[0], cols: parts[1])
    }

    /// Asks the host-side pose driver to fold or unfold the simulator and
    /// waits for it to say the simulator is in that pose.
    private func pose(_ name: String, timeout: TimeInterval = 120) throws {
        print("DUO: pose \(name) requested")
        let request = "\(duoDir)/pose-request"
        let done = "\(duoDir)/pose-done"
        let token = "\(name) \(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: done)
        try Data((token + "\n").utf8).write(to: URL(fileURLWithPath: request), options: .atomic)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = try? String(contentsOfFile: done, encoding: .utf8) {
                let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if line == token {
                    print("DUO: pose \(name) reached")
                    return
                }
                if line.hasPrefix("error \(token)") {
                    XCTFail("the pose driver could not reach \"\(name)\": \(line)")
                    return
                }
            }
            usleep(250_000)
        }
        XCTFail("the host pose driver never answered \"\(name)\" — is scripts/duo-pose-driver.sh running?")
    }

    /// A screenshot of the app's window, kept in the result bundle (the
    /// workflow exports it as an artifact), and a progress line.
    private func capture(_ label: String) throws {
        print("DUO: capture \(label)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSession() {
        print("DUO: opening the session")
        let row = app.staticTexts["Duo"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "seeded server row missing")
        row.tap()
        // First keyboard on a fresh simulator shows the swipe-typing tutorial.
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 6) {
            tutorial.tap()
        }
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 30), "never reached a connected session")
    }

    /// Pixel sizes of the Duo's displays by screen id (1 outer, 3 inner):
    /// lines of "<id> <width> <height>", which duo.yml copies from the iPhone
    /// Duo simulator's device profile.
    private func displaySizes() -> [Int: CGSize]? {
        guard let text = try? String(contentsOfFile: "\(duoDir)/display.txt", encoding: .utf8) else { return nil }
        var sizes: [Int: CGSize] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").compactMap { Int($0) }
            if parts.count == 3 { sizes[parts[0]] = CGSize(width: parts[1], height: parts[2]) }
        }
        return sizes.isEmpty ? nil : sizes
    }

    private func record(_ line: String) {
        print("DUO: \(line)")
        let attachment = XCTAttachment(string: line)
        attachment.name = "duo-\(line.prefix(24))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
