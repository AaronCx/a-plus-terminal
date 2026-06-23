import XCTest
@testable import aPlusTerminal

final class ScrollBridgeCoreTests: XCTestCase {
    func testModeSelectionMatrix() {
        // Mode A: app requested mouse and the bridge is enabled — alt screen or not (htop, tmux).
        XCTAssertEqual(ScrollBridgeCore.mode(altScreen: true, mouseReporting: true, wheelBridgeEnabled: true), .sgrWheel)
        XCTAssertEqual(ScrollBridgeCore.mode(altScreen: false, mouseReporting: true, wheelBridgeEnabled: true), .sgrWheel)
        // Mode B: alternate screen without mouse (vim, less, tmux without `mouse on`).
        XCTAssertEqual(ScrollBridgeCore.mode(altScreen: true, mouseReporting: false, wheelBridgeEnabled: true), .arrowKeys)
        // Bridge toggle off: never send wheel events; alt screen still gets arrows.
        XCTAssertEqual(ScrollBridgeCore.mode(altScreen: true, mouseReporting: true, wheelBridgeEnabled: false), .arrowKeys)
        // Mode C: plain shell prompt scrolls local scrollback.
        XCTAssertEqual(ScrollBridgeCore.mode(altScreen: false, mouseReporting: false, wheelBridgeEnabled: true), .native)
        XCTAssertEqual(ScrollBridgeCore.mode(altScreen: false, mouseReporting: true, wheelBridgeEnabled: false), .native)
    }

    func testTickAccumulationKeepsResidual() {
        var core = ScrollBridgeCore()
        XCTAssertEqual(core.ticks(forDeltaY: 10), 0, "below one tick of travel")
        XCTAssertEqual(core.ticks(forDeltaY: 10), 1, "accumulated 20pt → one tick")
        XCTAssertEqual(core.ticks(forDeltaY: 16), 1, "2pt residual + 16pt → one tick")
        XCTAssertEqual(core.ticks(forDeltaY: 54), 3, "54pt → three ticks")
    }

    func testNegativeDeltasProduceNegativeTicks() {
        var core = ScrollBridgeCore()
        XCTAssertEqual(core.ticks(forDeltaY: -36), -2)
    }

    func testNegativeResidualAccumulatesAndTruncatesTowardZero() {
        // Mirror of the positive residual matrix: truncation toward zero means a
        // sub-tick negative delta yields 0, and residual carries to the next.
        var core = ScrollBridgeCore()
        XCTAssertEqual(core.ticks(forDeltaY: -10), 0, "below one tick of travel")
        XCTAssertEqual(core.ticks(forDeltaY: -10), -1, "accumulated -20pt → one tick down")
        XCTAssertEqual(core.ticks(forDeltaY: -16), -1, "-2pt residual + -16pt → one tick down")

        // Mixed sign: a positive delta nets the negative residual back toward zero.
        var mixed = ScrollBridgeCore()
        XCTAssertEqual(mixed.ticks(forDeltaY: -10), 0)
        XCTAssertEqual(mixed.ticks(forDeltaY: 28), 1, "−10 + 28 = 18pt → one tick up")
    }

    func testResetClearsResidual() {
        var core = ScrollBridgeCore()
        _ = core.ticks(forDeltaY: 17)
        core.reset()
        XCTAssertEqual(core.ticks(forDeltaY: 17), 0, "residual must not survive a new gesture")
    }

    func testWheelEventEncoding() {
        XCTAssertEqual(
            String(decoding: ScrollBridgeCore.wheelEvent(up: true, col: 5, row: 10), as: UTF8.self),
            "\u{1B}[<64;5;10M"
        )
        XCTAssertEqual(
            String(decoding: ScrollBridgeCore.wheelEvent(up: false, col: 1, row: 1), as: UTF8.self),
            "\u{1B}[<65;1;1M"
        )
    }

    /// §4.3 regression: nothing the bridge emits may leak as text input. Every
    /// emitted byte must belong to a complete SGR wheel sequence — no stray
    /// `M` characters or partial escapes.
    func testWheelEventsAreOnlyCompleteSGRSequences() throws {
        let payload = String(
            decoding: ScrollBridgeCore.wheelEvents(up: true, count: 7, col: 42, row: 13),
            as: UTF8.self
        )
        let pattern = /\u{1B}\[<6[45];\d+;\d+M/
        let stripped = payload.replacing(pattern, with: "")
        XCTAssertTrue(stripped.isEmpty, "leftover bytes would leak as input: \(stripped.debugDescription)")
        XCTAssertEqual(payload.matches(of: pattern).count, 7, "one event per tick")
    }

    func testArrowEventsSendThreeLinesPerTick() {
        let up = ScrollBridgeCore.arrowEvents(up: true, ticks: 2, applicationCursor: false)
        XCTAssertEqual(String(decoding: up, as: UTF8.self), String(repeating: "\u{1B}[A", count: 6))

        let downAppCursor = ScrollBridgeCore.arrowEvents(up: false, ticks: 1, applicationCursor: true)
        XCTAssertEqual(String(decoding: downAppCursor, as: UTF8.self), String(repeating: "\u{1B}OB", count: 3))
    }
}
