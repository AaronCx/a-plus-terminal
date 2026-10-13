import XCTest

/// iPhone Duo (the foldable): the app fills the inner display instead of
/// running letterboxed, a live terminal re-sizes its grid to the display it is
/// on, and folding and unfolding mid-session keeps the session and resizes
/// the pty the server sees.
///
/// Runs on CI only, from `.github/workflows/duo.yml` on the iPhone Duo
/// simulator built with the iOS 27.1 SDK. That job starts a throwaway
/// loopback sshd (`scripts/duo-ci-sshd.sh`) whose login writes the pty size
/// the SERVER sees to `~/.aplus-duo/grid.txt`, and a host-side pose driver
/// (`scripts/duo-pose-driver.sh`) that folds and unfolds the simulator when
/// this test asks through `~/.aplus-duo/pose-request` — XCUITest itself cannot
/// fold a device. The simulator shares the host filesystem, so the seed, the
/// key and the grid all come from files and nothing secret crosses a build
/// setting.
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
        app.launch()
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
        shot("unfolded-servers")
        let screen = screenPoints()
        let window = app.windows.firstMatch.frame
        record("unfolded screen \(screen) window \(window) app \(app.frame)")
        XCTAssertGreaterThan(min(screen.width, screen.height), 600,
                             "this is not the Duo's inner display (\(screen)) — the pose driver did not unfold it")
        XCTAssertEqual(window.minX, 0, accuracy: 1, "window is inset from the display: \(window) on \(screen)")
        XCTAssertEqual(window.minY, 0, accuracy: 1, "window is inset from the display: \(window) on \(screen)")
        XCTAssertEqual(window.width, screen.width, accuracy: 1, "letterboxed: window \(window) on display \(screen)")
        XCTAssertEqual(window.height, screen.height, accuracy: 1, "letterboxed: window \(window) on display \(screen)")
        XCTAssertEqual(app.frame.size.width, screen.width, accuracy: 1)
        XCTAssertEqual(app.frame.size.height, screen.height, accuracy: 1)
    }

    /// A live session through folded -> unfolded -> folded: the app stays in
    /// the foreground, the session stays connected, and the pty the server
    /// sees follows the display — more columns unfolded than folded.
    func testFoldingMidSessionResizesTheGrid() throws {
        openSession()
        let unfolded = try grid(after: nil)
        shot("unfolded-terminal")
        record("unfolded grid \(unfolded.cols)x\(unfolded.rows), window \(app.windows.firstMatch.frame)")

        try pose("folded")
        let folded = try grid(after: unfolded)
        XCTAssertEqual(app.state, .runningForeground, "folding sent the app away")
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 10), "folding dropped the session screen")
        shot("folded-terminal")
        record("folded grid \(folded.cols)x\(folded.rows), window \(app.windows.firstMatch.frame), screen \(screenPoints())")
        XCTAssertLessThan(folded.cols, unfolded.cols, "the outer display fits fewer columns than the inner one")

        try pose("unfolded")
        let reopened = try grid(after: folded)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 10), "unfolding dropped the session screen")
        shot("unfolded-again-terminal")
        record("unfolded-again grid \(reopened.cols)x\(reopened.rows), window \(app.windows.firstMatch.frame)")
        XCTAssertEqual(reopened.cols, unfolded.cols, "unfolding again did not restore the inner display's columns")

        try pose("folded")
        let refolded = try grid(after: reopened)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 10), "folding again dropped the session screen")
        shot("folded-again-terminal")
        record("folded-again grid \(refolded.cols)x\(refolded.rows)")
        XCTAssertEqual(refolded.cols, folded.cols, "folding again did not return to the outer display's columns")
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

    /// Asks the host-side pose driver for a pose and waits for it to say the
    /// simulator is in it.
    private func pose(_ name: String, timeout: TimeInterval = 60) throws {
        let request = "\(duoDir)/pose-request"
        let done = "\(duoDir)/pose-done"
        let token = "\(name) \(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: done)
        try Data((token + "\n").utf8).write(to: URL(fileURLWithPath: request), options: .atomic)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = try? String(contentsOfFile: done, encoding: .utf8) {
                let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if line == token { return }
                if line.hasPrefix("error \(token)") {
                    XCTFail("the pose driver could not reach \"\(name)\": \(line)")
                    return
                }
            }
            usleep(250_000)
        }
        XCTFail("the host pose driver never answered \"\(name)\" — is scripts/duo-pose-driver.sh running?")
    }

    private func openSession() {
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

    /// The size in points of the display the app is on: the largest lit
    /// screen XCUITest can see (a dark one screenshots as nothing useful).
    /// Every screen is recorded, so a wrong pick shows in the log.
    private func screenPoints() -> CGSize {
        let sizes = XCUIScreen.screens.map { $0.screenshot().image.size }
        record("screens \(sizes) main \(XCUIScreen.main.screenshot().image.size)")
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }

    /// One attachment per screen XCUITest can see (the Duo has two).
    private func shot(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = "\(name)-screen\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func record(_ line: String) {
        print("DUO: \(line)")
        let attachment = XCTAttachment(string: line)
        attachment.name = "duo-\(line.prefix(24))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
