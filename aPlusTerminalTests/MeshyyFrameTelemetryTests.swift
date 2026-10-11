import MeshyyKit
import XCTest
@testable import aPlusTerminal

// MARK: - meshyy frame telemetry

@MainActor
final class MeshyyFrameTelemetryTests: XCTestCase {
    /// `.screenMode` is RECORDED for the trace and must still never reach the
    /// emulator (acting on it is a routing change, deferred to the audit).
    func testScreenModeFrameIsRecordedButNotFedToTheEmulator() async {
        let transport = MeshyyTransport.makeForTesting()
        var callbacks: [Bool] = []
        transport.onScreenModeFrame = { alt, _ in callbacks.append(alt) }

        XCTAssertTrue(transport.handle(.screenMode(alt: true)))
        XCTAssertEqual(transport.lastScreenModeFrame?.alt, true)
        XCTAssertEqual(callbacks, [true])

        // A sentinel behind it: if the frame had produced bytes, they would
        // be first in the emulator's stream.
        transport.handle(.output([0x41]))
        var iterator = transport.output.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, Data([0x41]))
    }

    func testModesFrameIsRecordedAndStillApplied() async {
        let transport = MeshyyTransport.makeForTesting()
        var callbacks: [Set<Int>] = []
        transport.onModesFrame = { active, _ in callbacks.append(active) }
        transport.handle(.modes(active: [1000, 1006]))
        XCTAssertEqual(transport.lastModesFrame?.active, [1000, 1006])
        XCTAssertEqual(callbacks, [[1000, 1006]])
        var iterator = transport.output.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, MeshyyTransport.modeEscapes(active: [1000, 1006]))
    }

    func testTerminalEventsStopThePump() {
        XCTAssertFalse(MeshyyTransport.makeForTesting().handle(.ended(reason: "test")))
        XCTAssertFalse(MeshyyTransport.makeForTesting().handle(.failed(reason: "test")))
        let exited = MeshyyTransport.makeForTesting()
        XCTAssertFalse(exited.handle(.exited(status: 0)))
        XCTAssertEqual(exited.cleanExitStatus, 0)
    }
}
