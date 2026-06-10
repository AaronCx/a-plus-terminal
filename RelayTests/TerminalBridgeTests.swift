import XCTest
@testable import Relay

/// Sticky-Ctrl chord behavior (§4.2): tap ctrl, tap C → 0x03.
@MainActor
final class TerminalBridgeTests: XCTestCase {
    private func makeBridge() -> (TerminalBridge, sent: () -> [Data]) {
        let bridge = TerminalBridge()
        var sent: [Data] = []
        bridge.sendData = { sent.append($0) }
        return (bridge, { sent })
    }

    func testCtrlCSendsETXOnce() {
        let (bridge, sent) = makeBridge()
        bridge.ctrlActive = true

        XCTAssertTrue(bridge.handleInsert("c"), "chord must consume the keystroke")
        XCTAssertEqual(sent(), [Data([0x03])], "Ctrl-C is the Claude Code interrupt")
        XCTAssertFalse(bridge.ctrlActive, "sticky Ctrl disarms after one use")

        XCTAssertFalse(bridge.handleInsert("c"), "next keystroke passes through")
        XCTAssertEqual(sent().count, 1)
    }

    func testCtrlChordsAcrossTheControlRange() {
        let (bridge, sent) = makeBridge()
        for (key, expected) in [("a", 0x01), ("z", 0x1A), ("[", 0x1B), ("_", 0x1F)] {
            bridge.ctrlActive = true
            XCTAssertTrue(bridge.handleInsert(key))
            XCTAssertEqual(sent().last, Data([UInt8(expected)]), "ctrl-\(key)")
        }
    }

    func testCtrlSpaceAndQuestionMark() {
        let (bridge, sent) = makeBridge()
        bridge.ctrlActive = true
        XCTAssertTrue(bridge.handleInsert(" "))
        XCTAssertEqual(sent().last, Data([0x00]), "Ctrl-Space is NUL")

        bridge.ctrlActive = true
        XCTAssertTrue(bridge.handleInsert("?"))
        XCTAssertEqual(sent().last, Data([0x7F]), "Ctrl-? is DEL")
    }

    func testUnmappableCharacterDisarmsAndPassesThrough() {
        let (bridge, sent) = makeBridge()
        bridge.ctrlActive = true
        XCTAssertFalse(bridge.handleInsert("é"), "non-ASCII inserts normally")
        XCTAssertTrue(sent().isEmpty)
        XCTAssertFalse(bridge.ctrlActive, "ctrl still disarms — no surprise control codes later")
    }

    func testInactiveCtrlNeverIntercepts() {
        let (bridge, sent) = makeBridge()
        XCTAssertFalse(bridge.handleInsert("c"))
        XCTAssertTrue(sent().isEmpty)
    }

    func testArrowKeysHonorApplicationCursorMode() {
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursor: false), [0x1B, 0x5B, 0x41])  // ESC [ A
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursor: true), [0x1B, 0x4F, 0x41])   // ESC O A
    }
}
