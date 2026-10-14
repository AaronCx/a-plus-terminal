import XCTest

/// iPhone Duo (the foldable), on the iOS 27.1 simulator: the app's window
/// fills the panel it is on (not letterboxed into a phone-sized box), and a
/// live terminal session resizes the pty the server sees when its window
/// area changes mid-session.
///
/// Runs on CI only, from `.github/workflows/duo.yml` on the iPhone Duo
/// simulator built with the iOS 27.1 SDK. That job starts a throwaway
/// loopback sshd (`scripts/duo-ci-sshd.sh`) whose login writes the pty size
/// the SERVER sees to `~/.aplus-duo/grid.txt`, and records the Duo's panel
/// sizes from its device profile in `~/.aplus-duo/display.txt`. The
/// simulator shares the host filesystem, so the seed, the key and the grid
/// all come from files and nothing secret crosses a build setting.
///
/// What this cannot do: fold or unfold. The simulator boots folded (the app
/// on the outer panel), and its only scriptable fold control, `simctl io
/// screenConfig --display=N power off`, crashed SpringBoard in CI ("The
/// system shell (SpringBoard) probably crashed", 2026-10-14) — so the inner
/// panel and the fold transition are not exercised here. Rotation is no
/// substitute either: on the outer panel it left the window unchanged.
/// The mid-session resize below hides the keyboard instead, the same
/// size-change path (window area -> SwiftTerm -> pty) a fold drives.
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

    /// The app's window is the whole panel it is on — one of the Duo's two
    /// panels, pixel for pixel — not a letterboxed phone-sized box.
    func testWindowFillsTheDuoPanelItIsOn() throws {
        try capture("01-launch")
        let displays = try XCTUnwrap(displaySizes(), "duo.yml wrote no display sizes")
        let window = app.windows.firstMatch.frame
        // The runner's own display scale (both Duo panels are @3x).
        let traitScale = UITraitCollection.current.displayScale
        let scale = traitScale > 0 ? traitScale : 3
        let px = CGSize(width: window.width * scale, height: window.height * scale)
        record("displays \(displays) px, window \(window) pt @\(scale)x = \(px) px, app \(app.frame)")
        // Either orientation of either panel.
        let panel = displays.first { _, size in
            (abs(px.width - size.width) <= scale && abs(px.height - size.height) <= scale)
                || (abs(px.width - size.height) <= scale && abs(px.height - size.width) <= scale)
        }
        XCTAssertNotNil(panel, "letterboxed: window \(window) pt = \(px) px matches no Duo panel \(displays)")
        record("window fills panel \(panel.map { "\($0.key) (\(Int($0.value.width))x\(Int($0.value.height)) px)" } ?? "none")")
        XCTAssertEqual(window.minX, 0, accuracy: 1, "window is inset from the panel: \(window)")
        XCTAssertEqual(window.minY, 0, accuracy: 1, "window is inset from the panel: \(window)")
    }

    /// A live session's pty follows its window area mid-session: hiding the
    /// keyboard gives the terminal more rows and the server sees them;
    /// raising it again gives them back. The session stays connected and the
    /// app in the foreground throughout.
    func testLiveSessionResizesThePtyMidSession() throws {
        openSession()
        let withKeyboard = try grid(after: nil)
        try capture("02-session-keyboard-up")
        record("keyboard up: grid \(withKeyboard), window \(app.windows.firstMatch.frame)")

        app.buttons["Toggle Keyboard"].tap()
        let withoutKeyboard = try grid(after: withKeyboard)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 20), "the session screen went away")
        try capture("03-session-keyboard-down")
        record("keyboard down: grid \(withoutKeyboard)")
        XCTAssertGreaterThan(withoutKeyboard.rows, withKeyboard.rows, "hiding the keyboard must give the pty more rows")
        XCTAssertEqual(withoutKeyboard.cols, withKeyboard.cols, "the keyboard changes rows, not columns")

        app.buttons["Toggle Keyboard"].tap()
        let again = try grid(after: withoutKeyboard)
        XCTAssertEqual(app.state, .runningForeground)
        try capture("04-session-keyboard-up-again")
        record("keyboard up again: grid \(again)")
        XCTAssertEqual(again, withKeyboard, "raising the keyboard again did not restore the grid")
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
