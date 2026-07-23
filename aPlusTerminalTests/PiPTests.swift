import CoreMedia
import CryptoKit
import XCTest
@testable import aPlusTerminal

/// Frame coalescing policy for the pop-out surface (brief §3.2/§3.5): bursts
/// render at most once per interval; a lone invalidation renders promptly.
@MainActor
final class PiPFrameCoalescerTests: XCTestCase {
    func testBurstOfInvalidationsWithinOneSecondYieldsAtMostTenAndAtLeastOneRender() async throws {
        let coalescer = PiPFrameCoalescer(minInterval: 0.1)
        var renders = 0
        coalescer.render = { renders += 1 }
        // Feed a dense burst for well under a second, then let any trailing
        // scheduled render land — total window stays within 1s.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.8 {
            coalescer.invalidate()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThanOrEqual(renders, 1, "a burst must render at least once (§3.5)")
        XCTAssertLessThanOrEqual(renders, 10, "renders are hard-capped at 10 fps (§3.2)")
        coalescer.cancel()
    }

    func testSynchronousBurstCoalescesToASingleScheduledRender() async throws {
        let coalescer = PiPFrameCoalescer(minInterval: 0.05)
        var renders = 0
        coalescer.render = { renders += 1 }
        for _ in 0..<100 {
            coalescer.invalidate()
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(renders, 1, "invalidations with no scheduling gap coalesce into one render")
    }

    func testRenderNowFiresImmediatelyAndCancelsThePendingRender() async throws {
        let coalescer = PiPFrameCoalescer(minInterval: 10)
        var renders = 0
        coalescer.render = { renders += 1 }
        coalescer.renderNow()
        XCTAssertEqual(renders, 1, "renderNow is synchronous (start / render-size change)")
        coalescer.invalidate()
        coalescer.renderNow()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(renders, 2, "the pending debounced render was superseded, not queued behind")
        coalescer.cancel()
    }
}

/// Last-N-rows extraction (brief §3.5): correct across line wraps and
/// terminal resizes. Uses the real SwiftTerm emulator like
/// TerminalRenderingTests.
@MainActor
final class TerminalTailWindowTests: XCTestCase {
    private func makeTerminalView(cols: Int, rows: Int) -> TerminalEmulatorView {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.getTerminal().resize(cols: cols, rows: rows)
        return view
    }

    private func feed(_ view: TerminalEmulatorView, _ text: String) {
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    func testLastRowsExtractionAcrossLineWraps() {
        let view = makeTerminalView(cols: 10, rows: 8)
        // 20 chars into a 10-col grid wrap onto two rows.
        feed(view, "0123456789ABCDEFGHIJ\r\ntail")
        let rows = TerminalTailWindow.text(from: view.getTerminal(), tail: 3)
        XCTAssertEqual(rows, ["0123456789", "ABCDEFGHIJ", "tail"],
                       "wrapped continuation rows count as rows of the tail window")
    }

    func testTailEndsAtCursorRowSkippingBlankRowsBelow() {
        let view = makeTerminalView(cols: 20, rows: 10)
        feed(view, "only line")
        let rows = TerminalTailWindow.text(from: view.getTerminal(), tail: 3)
        XCTAssertEqual(rows, ["only line"],
                       "a short transcript shows content ending at the cursor, not blank grid rows")
    }

    func testExtractionAfterScrollTracksTheLiveTail() {
        let view = makeTerminalView(cols: 20, rows: 4)
        feed(view, "A\r\nB\r\nC\r\nD\r\nE")
        let rows = TerminalTailWindow.text(from: view.getTerminal(), tail: 2)
        XCTAssertEqual(rows, ["D", "E"], "the window follows the tail through scrollback")
    }

    func testExtractionSurvivesTerminalResize() {
        let view = makeTerminalView(cols: 40, rows: 10)
        feed(view, "before resize")
        view.getTerminal().resize(cols: 20, rows: 6)
        feed(view, "\r\nafter resize")
        let rows = TerminalTailWindow.text(from: view.getTerminal(), tail: 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last, "after resize", "the tail window tracks the resized grid")
    }

    func testAlternateBufferWindowsTheBottomOfTheGridRegardlessOfCursor() {
        // Full-screen apps park the cursor anywhere; the bottom rows are the
        // action. Pure range check — no emulator needed.
        XCTAssertEqual(TerminalTailWindow.range(rows: 24, cursorRow: 2, isAlternate: true, tail: 10),
                       14..<24)
        XCTAssertEqual(TerminalTailWindow.range(rows: 24, cursorRow: 2, isAlternate: false, tail: 10),
                       0..<3)
        XCTAssertEqual(TerminalTailWindow.range(rows: 5, cursorRow: 4, isAlternate: false, tail: 10),
                       0..<5, "a tail larger than the grid clamps to the grid")
        XCTAssertEqual(TerminalTailWindow.range(rows: 0, cursorRow: 0, isAlternate: false, tail: 10),
                       0..<0)
    }
}

/// followSuspended semantics (brief §3.2/§3.5): pause freezes the visible row
/// window; clearing it jumps back to the tail.
@MainActor
final class TerminalPiPFrameSourceTests: XCTestCase {
    private func makeSource(view: TerminalEmulatorView, tailRows: Int = 3) -> TerminalPiPFrameSource {
        TerminalPiPFrameSource(
            terminalView: view,
            sessionID: UUID(),
            title: { "mac-mini" },
            chip: { .running },
            tailRows: tailRows
        )
    }

    func testFollowSuspendedFreezesRowWindowAndClearingJumpsToTail() {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.getTerminal().resize(cols: 20, rows: 6)
        view.feed(byteArray: ArraySlice(Array("one\r\ntwo".utf8)))
        let source = makeSource(view: view)

        let live = source.currentModel()
        XCTAssertFalse(live.paused)
        XCTAssertEqual(live.rows, ["one", "two"])

        source.followSuspended = true
        view.feed(byteArray: ArraySlice(Array("\r\nthree".utf8)))
        let frozen = source.currentModel()
        XCTAssertTrue(frozen.paused, "pause draws the paused indicator")
        XCTAssertEqual(frozen.rows, live.rows, "pause freezes the visible row window")

        source.followSuspended = false
        let resumed = source.currentModel()
        XCTAssertFalse(resumed.paused)
        XCTAssertEqual(resumed.rows, ["one", "two", "three"], "resume jumps back to the tail")
    }

    func testChipMappingFollowsSessionStateAndAgentStatus() {
        XCTAssertEqual(PiPSessionChip.from(state: .connected, agentStatus: .none), .running)
        XCTAssertEqual(PiPSessionChip.from(state: .connected, agentStatus: .working), .running)
        XCTAssertEqual(PiPSessionChip.from(state: .connected, agentStatus: .waiting), .waitingForInput)
        XCTAssertEqual(PiPSessionChip.from(state: .suspended, agentStatus: .working), .disconnected)
        XCTAssertEqual(PiPSessionChip.from(state: .reconnecting, agentStatus: .none), .disconnected)
    }

    func testDetachedTerminalRendersDisconnectedPlaceholder() {
        // A source whose terminal view is gone (session closed and torn
        // down): the weak reference is nil and the surface degrades safely.
        let source = TerminalPiPFrameSource(
            terminalView: nil,
            sessionID: UUID(),
            title: { "gone" },
            chip: { .running },
            tailRows: 3
        )
        let model = source.currentModel()
        XCTAssertEqual(model.chip, .disconnected, "a dead session view reads as disconnected")
        XCTAssertEqual(model.rows, [])
    }
}

/// Buffer-text + pixel snapshot of the rendered pop-out surface (brief §3.5).
/// Pixel comparison stays within one process/run (render twice, compare) so
/// font/OS drift across simulators can't flake it.
@MainActor
final class TerminalPiPSurfaceSnapshotTests: XCTestCase {
    private func pixelHash(_ buffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "" }
        let data = Data(bytes: base, count: CVPixelBufferGetDataSize(buffer))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testFixedTerminalInputProducesAStableRenderedSurface() throws {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.getTerminal().resize(cols: 20, rows: 6)
        view.feed(byteArray: ArraySlice(Array("alpha\r\nbeta\r\ngamma".utf8)))
        let source = TerminalPiPFrameSource(
            terminalView: view,
            sessionID: UUID(),
            title: { "mac-mini" },
            chip: { .running },
            tailRows: 4
        )

        // Text-model snapshot — the repo's snapshot mechanism of record.
        let model = source.currentModel()
        XCTAssertEqual(model, TerminalPiPSurfaceModel(
            title: "mac-mini",
            chip: .running,
            rows: ["alpha", "beta", "gamma"],
            paused: false
        ))

        // Pixel stability: identical model → identical bytes, and the
        // surface actually painted something.
        let renderer = TerminalPiPSurfaceRenderer()
        let pool = try XCTUnwrap(PiPPixelBufferPool.make(size: renderer.size))
        let first = try XCTUnwrap(renderer.draw(model, into: pool))
        let second = try XCTUnwrap(renderer.draw(model, into: pool))
        XCTAssertEqual(CVPixelBufferGetWidth(first), 960)
        XCTAssertEqual(CVPixelBufferGetHeight(first), 600)
        XCTAssertEqual(pixelHash(first), pixelHash(second), "same model renders identical pixels")

        let changed = TerminalPiPSurfaceModel(
            title: "mac-mini", chip: .running, rows: ["alpha", "beta", "delta"], paused: false
        )
        let third = try XCTUnwrap(renderer.draw(changed, into: pool))
        XCTAssertNotEqual(pixelHash(first), pixelHash(third), "content changes reach the pixels")
    }

    func testSampleBufferCreationFromRenderedSurface() throws {
        let renderer = TerminalPiPSurfaceRenderer()
        let pool = try XCTUnwrap(PiPPixelBufferPool.make(size: renderer.size))
        let model = TerminalPiPSurfaceModel(title: "t", chip: .running, rows: ["x"], paused: false)
        let buffer = try XCTUnwrap(renderer.draw(model, into: pool))
        let sample = try XCTUnwrap(PiPEngine.makeSampleBuffer(for: buffer))
        XCTAssertTrue(CMSampleBufferIsValid(sample))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
    }
}
