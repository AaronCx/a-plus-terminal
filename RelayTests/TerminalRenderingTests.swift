import XCTest
import SwiftTerm
@testable import Relay

/// Text-snapshot tests for terminal rendering (PR 12 hardening): feed known
/// byte streams into the emulator and assert the resulting screen buffer.
/// No image-snapshot dependency — the dependency budget is spent.
@MainActor
final class TerminalRenderingTests: XCTestCase {
    private func makeTerminalView(cols: Int = 40, rows: Int = 10) -> RelayTerminalView {
        let view = RelayTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = view.getTerminal()
        terminal.resize(cols: cols, rows: rows)
        return view
    }

    private func feed(_ view: RelayTerminalView, _ text: String) {
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    private func line(_ view: RelayTerminalView, _ index: Int) -> String {
        let terminal = view.getTerminal()
        guard let line = terminal.getLine(row: index) else { return "" }
        var result = ""
        for col in 0..<terminal.cols {
            result.append(line[col].getCharacter())
        }
        return result.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\0", with: "")
    }

    func testPlainTextRendersOnFirstLine() {
        let view = makeTerminalView()
        feed(view, "hello relay")
        XCTAssertEqual(line(view, 0), "hello relay")
    }

    func testCRLFAdvancesLines() {
        let view = makeTerminalView()
        feed(view, "one\r\ntwo\r\nthree")
        XCTAssertEqual(line(view, 0), "one")
        XCTAssertEqual(line(view, 1), "two")
        XCTAssertEqual(line(view, 2), "three")
    }

    func testSGRColorSequencesDoNotLeakIntoText() {
        let view = makeTerminalView()
        feed(view, "\u{1B}[31mred\u{1B}[0m plain")
        XCTAssertEqual(line(view, 0), "red plain", "escape bytes must be consumed, not rendered")
    }

    func testAlternateScreenDetection() {
        let view = makeTerminalView()
        let terminal = view.getTerminal()
        XCTAssertFalse(terminal.isCurrentBufferAlternate)
        feed(view, "\u{1B}[?1049h")  // enter alt screen (tmux/vim)
        XCTAssertTrue(terminal.isCurrentBufferAlternate)
        feed(view, "\u{1B}[?1049l")  // leave alt screen
        XCTAssertFalse(terminal.isCurrentBufferAlternate)
    }

    func testMouseModeDetection() {
        let view = makeTerminalView()
        let terminal = view.getTerminal()
        XCTAssertEqual(terminal.mouseMode, .off)
        feed(view, "\u{1B}[?1000h\u{1B}[?1006h")  // VT200 mouse + SGR encoding (tmux `mouse on`)
        XCTAssertNotEqual(terminal.mouseMode, .off)
        feed(view, "\u{1B}[?1000l")
        XCTAssertEqual(terminal.mouseMode, .off)
    }

    func testCursorPositioningSnapshot() {
        let view = makeTerminalView()
        feed(view, "\u{1B}[2;5HX")  // row 2, col 5
        XCTAssertEqual(line(view, 1), "X")
        let terminal = view.getTerminal()
        XCTAssertEqual(terminal.buffer.y, 1)
        XCTAssertEqual(terminal.buffer.x, 5)
    }

    func testUnicodeRendering() {
        let view = makeTerminalView()
        feed(view, "naïve → 日本")
        XCTAssertTrue(line(view, 0).contains("naïve"))
        XCTAssertTrue(line(view, 0).contains("日本"))
    }
}
