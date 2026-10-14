import XCTest

/// iPhone Duo (the foldable), on the iOS 27.1 simulator, OUTER panel only:
/// the app's window fills that panel (not a letterboxed phone-sized box),
/// the terminal's column count follows the terminal's width, and a live
/// session resizes the pty the server sees when its window area changes.
///
/// Runs on CI only, from `.github/workflows/duo.yml` on the iPhone Duo
/// simulator built with the iOS 27.1 SDK. That job starts a throwaway
/// loopback sshd (`scripts/duo-ci-sshd.sh`) whose login writes the pty size
/// the SERVER sees to `~/.aplus-duo/grid.txt`, and records the Duo's panel
/// sizes (`display.txt`) and model identifier (`model.txt`) from its device
/// type in `~/.aplus-duo`. The simulator shares the host filesystem, so the
/// seed, the key and the grid all come from files and nothing secret
/// crosses a build setting. setUp fails unless the simulator it runs on IS
/// that model with two panels, so a run on another iPhone proves nothing
/// and cannot pass.
///
/// What this cannot do: fold or unfold. The simulator boots folded (the app
/// on the outer panel), and its only scriptable fold control, `simctl io
/// screenConfig --display=N power off`, crashed SpringBoard in CI ("The
/// system shell (SpringBoard) probably crashed", 2026-10-14). So the inner
/// 7.6" panel — where an iOS 26-SDK build is letterboxed — and the fold
/// transition are NOT exercised here: a build that letterboxes only on the
/// inner panel passes this suite. Rotation is no substitute either: on the
/// outer panel it left the window unchanged. The mid-session resize below
/// hides the keyboard, which changes the terminal's height (rows) only;
/// columns are checked against the terminal's measured width instead, at
/// two font sizes.
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
        // On the Duo, or the results mean nothing: the simulator's model must
        // be the iPhone Duo device type's, and that type has two panels.
        let duoModel = try XCTUnwrap(
            (try? String(contentsOfFile: "\(duoDir)/model.txt", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "no \(duoDir)/model.txt — duo.yml records the iPhone Duo's model identifier there")
        let model = env["SIMULATOR_MODEL_IDENTIFIER"]
        print("DUO: simulator model \(model ?? "nil") (\(env["SIMULATOR_DEVICE_NAME"] ?? "?")), iPhone Duo is \(duoModel)")
        XCTAssertEqual(model, duoModel, "not running on the iPhone Duo simulator")
        XCTAssertEqual(displaySizes()?.count, 2, "the iPhone Duo has two panels; display.txt says \(String(describing: displaySizes()))")
        app = XCUIApplication()
        app.launchEnvironment["APLUSTERMINAL_TEST_SERVER"] = String(decoding: server, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        app.launchEnvironment["APLUSTERMINAL_TEST_PRIVATE_KEY"] = key.base64EncodedString()
        // A known font size (a UserDefaults argument), so the column count
        // can be predicted from the terminal's width.
        app.launchArguments = ["-terminalFontSize", "\(Int(Self.fontSizes[0]))"]
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
        try launch()
        print("DUO: setUp launched, state \(app.state.rawValue)")
    }

    /// Launches with no grid on file, so the next one read is this launch's
    /// session and never one left behind by an earlier test.
    private func launch() throws {
        let gridFile = "\(duoDir)/grid.txt"
        try? FileManager.default.removeItem(atPath: gridFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gridFile), "could not clear a stale \(gridFile)")
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

    /// The terminal font sizes the column check runs at (13 is the default).
    private static let fontSizes: [Double] = [13, 20]

    // MARK: - Tests

    /// The app's window is the whole OUTER panel (screen 1), pixel for
    /// pixel — not a letterboxed phone-sized box. The simulator boots
    /// folded, so the inner panel is never measured (see the file header).
    func testWindowFillsTheOuterPanel() throws {
        try capture("01-launch")
        let displays = try XCTUnwrap(displaySizes(), "duo.yml wrote no display sizes")
        let outer = try XCTUnwrap(displays[Self.outerPanel], "display.txt has no outer panel (screen \(Self.outerPanel)): \(displays)")
        let window = app.windows.firstMatch.frame
        let scale = displayScale
        let px = CGSize(width: window.width * scale, height: window.height * scale)
        record("displays \(displays) px, window \(window) pt @\(scale)x = \(px) px, app \(app.frame)")
        // Either orientation of the outer panel.
        let fills = (abs(px.width - outer.width) <= scale && abs(px.height - outer.height) <= scale)
            || (abs(px.width - outer.height) <= scale && abs(px.height - outer.width) <= scale)
        XCTAssertTrue(fills, "letterboxed: window \(window) pt = \(px) px is not the outer panel's \(outer) px")
        record("window fills outer panel \(Self.outerPanel) (\(Int(outer.width))x\(Int(outer.height)) px)")
        XCTAssertEqual(window.minX, 0, accuracy: 1, "window is inset from the panel: \(window)")
        XCTAssertEqual(window.minY, 0, accuracy: 1, "window is inset from the panel: \(window)")
    }

    /// The column count the server sees is the terminal's measured width in
    /// cells, at two font sizes: a fixed column count, or a terminal pinned
    /// narrower than the space it is given, fails. (A cap wider than this
    /// panel's terminal area would only show on the inner panel.)
    func testColumnsFollowTheTerminalWidth() throws {
        var previous: Grid?
        for (index, size) in Self.fontSizes.enumerated() {
            if index > 0 {
                app.terminate()
                app.launchArguments = ["-terminalFontSize", "\(Int(size))"]
                try launch()
            }
            openSession()
            let grid = try grid(after: nil)
            let window = app.windows.firstMatch.frame
            let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
            XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal view on screen")
            let frame = terminal.frame
            let cell = cellWidth(fontSize: size)
            let expected = Int((frame.width / cell).rounded(.down))
            try capture("05-columns-\(Int(size))pt")
            record("\(Int(size))pt: grid \(grid), terminal \(frame) in window \(window) (space ends at x=\(trailingNeighbourEdge(of: frame, in: window))), cell \(cell) pt -> \(expected) cols expected")
            XCTAssertEqual(frame.minX, window.minX, accuracy: 1, "the terminal does not start at the window's edge: \(frame) in \(window)")
            // It reaches the window's trailing edge, or whatever sits beside
            // it there (the iOS 27.1 layout puts the toolbar in a column to
            // the right of the terminal on the Duo's outer panel).
            let trailing = trailingNeighbourEdge(of: frame, in: window)
            XCTAssertLessThanOrEqual(trailing - frame.maxX, 24,
                                     "the terminal stops \(trailing - frame.maxX) pt short of \(trailing): pinned narrower than its space? \(frame) in \(window)")
            XCTAssertLessThanOrEqual(abs(grid.cols - expected), 1,
                                     "\(grid.cols) columns at \(Int(size))pt, but the terminal is \(frame.width) pt wide = \(expected) cells")
            if let previous {
                XCTAssertLessThan(grid.cols, previous.cols, "a larger font must give fewer columns: \(previous) -> \(grid)")
            }
            previous = grid
        }
    }

    /// A live session's pty follows its window area mid-session: hiding the
    /// keyboard gives the terminal more rows and the server sees them;
    /// raising it again gives them back. The session stays connected and the
    /// app in the foreground throughout. This changes the height only; the
    /// columns-to-width path is `testColumnsFollowTheTerminalWidth`.
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

    /// The Duo's outer panel's screen id in its device profile (3 is inner).
    private static let outerPanel = 1

    /// The runner's own display scale (both Duo panels are @3x).
    private var displayScale: CGFloat {
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 3
    }

    /// The x where the space to the terminal's right ends: the nearest
    /// button lying wholly to its right and level with it, else the window's
    /// trailing edge.
    private func trailingNeighbourEdge(of terminal: CGRect, in window: CGRect) -> CGFloat {
        var edge = window.maxX
        for button in app.buttons.allElementsBoundByIndex {
            let f = button.frame
            guard !f.isEmpty, f.minX >= terminal.maxX - 1, f.minX < edge,
                  f.maxY > terminal.minY, f.minY < terminal.maxY else { continue }
            edge = f.minX
        }
        return edge
    }

    /// One terminal cell's width, as SwiftTerm computes it: the advance of
    /// "W" in the system monospaced font, rounded up to whole pixels.
    private func cellWidth(fontSize: Double) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        return ceil(width * displayScale) / displayScale
    }

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
