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

/// The live session timer in the terminal pop-out header.
@MainActor
final class TerminalPiPTimerTests: XCTestCase {
    func testElapsedFormatting() {
        XCTAssertEqual(PiPElapsedFormatter.string(0), "0:00")
        XCTAssertEqual(PiPElapsedFormatter.string(5), "0:05")
        XCTAssertEqual(PiPElapsedFormatter.string(65), "1:05")
        XCTAssertEqual(PiPElapsedFormatter.string(3599), "59:59")
        XCTAssertEqual(PiPElapsedFormatter.string(3600), "1:00:00")
        XCTAssertEqual(PiPElapsedFormatter.string(3807), "1:03:27")
        XCTAssertEqual(PiPElapsedFormatter.string(-10), "0:00", "negative clamps to zero")
    }

    func testModelCarriesElapsedFromSessionStart() {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.getTerminal().resize(cols: 20, rows: 6)
        view.feed(byteArray: ArraySlice(Array("hi".utf8)))
        let start = Date(timeIntervalSince1970: 1_000_000)
        let source = TerminalPiPFrameSource(
            terminalView: view, sessionID: UUID(),
            title: { "t" }, chip: { .running },
            startedAt: { start },
            now: { start.addingTimeInterval(125) }   // 2:05
        )
        XCTAssertEqual(source.currentModel().elapsed, "2:05")
    }

    func testNoStartDateMeansNoTimer() {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let source = TerminalPiPFrameSource(
            terminalView: view, sessionID: UUID(), title: { "t" }, chip: { .running }
        )
        XCTAssertNil(source.currentModel().elapsed)
    }

    func testTickerFiresInvalidationsWhileAttached() async throws {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let source = TerminalPiPFrameSource(
            terminalView: view, sessionID: UUID(), title: { "t" }, chip: { .running },
            startedAt: { Date() }
        )
        var ticks = 0
        source.onInvalidate = { ticks += 1 }   // assignment starts the ticker
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertGreaterThanOrEqual(ticks, 1, "the 1 Hz ticker advances the timer without output")
        source.onInvalidate = nil               // stops the ticker
        let after = ticks
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(ticks, after, "detaching stops the ticker")
    }
}

/// A bigger PiP window reveals MORE terminal rows (field feedback: the
/// terminal pop-out was too zoomed and resizing only magnified).
@MainActor
final class TerminalPiPRenderSizeTests: XCTestCase {
    private func source(rows terminalRows: Int, base: Int) -> TerminalPiPFrameSource {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.getTerminal().resize(cols: 40, rows: terminalRows)
        var text = ""
        for i in 0..<terminalRows { text += "line\(i)\r\n" }
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
        return TerminalPiPFrameSource(
            terminalView: view, sessionID: UUID(),
            title: { "t" }, chip: { .running }, tailRows: base
        )
    }

    func testLargerRenderSizeShowsMoreRows() {
        let src = source(rows: 50, base: 14)
        src.updateForRenderSize(CGSize(width: 300, height: 300))
        let small = src.currentModel().rows.count
        src.updateForRenderSize(CGSize(width: 600, height: 600))
        let large = src.currentModel().rows.count
        XCTAssertGreaterThan(large, small, "growing the PiP window reveals more rows")
        XCTAssertEqual(small, 14, "at the reference size, the baseline count shows")
    }

    func testRowCountNeverExceedsTheTerminal() {
        let src = source(rows: 12, base: 14)
        src.updateForRenderSize(CGSize(width: 1200, height: 1200))
        XCTAssertLessThanOrEqual(src.currentModel().rows.count, 12,
                                 "can't show more rows than the terminal has")
    }

    func testNeverBelowBaseline() {
        let src = source(rows: 50, base: 14)
        src.updateForRenderSize(CGSize(width: 60, height: 60))
        XCTAssertGreaterThanOrEqual(src.currentModel().rows.count, 14,
                                    "a tiny window never drops below the baseline")
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
            elapsed: nil,
            rows: ["alpha", "beta", "gamma"],
            paused: false
        ))

        // Pixel stability: identical model → identical bytes, and the
        // surface actually painted something.
        let renderer = TerminalPiPSurfaceRenderer()
        let pool = try XCTUnwrap(PiPPixelBufferPool.make(size: renderer.size))
        let first = try XCTUnwrap(renderer.draw(model, into: pool))
        let second = try XCTUnwrap(renderer.draw(model, into: pool))
        XCTAssertEqual(CVPixelBufferGetWidth(first), 900)
        XCTAssertEqual(CVPixelBufferGetHeight(first), 1200)
        XCTAssertEqual(pixelHash(first), pixelHash(second), "same model renders identical pixels")

        let changed = TerminalPiPSurfaceModel(
            title: "mac-mini", chip: .running, elapsed: nil, rows: ["alpha", "beta", "delta"], paused: false
        )
        let third = try XCTUnwrap(renderer.draw(changed, into: pool))
        XCTAssertNotEqual(pixelHash(first), pixelHash(third), "content changes reach the pixels")

        // The elapsed timer reaches the pixels too (a live clock must render).
        let ticked = TerminalPiPSurfaceModel(
            title: "mac-mini", chip: .running, elapsed: "1:03:27", rows: ["alpha", "beta", "gamma"], paused: false
        )
        let withTimer = try XCTUnwrap(renderer.draw(ticked, into: pool))
        XCTAssertNotEqual(pixelHash(first), pixelHash(withTimer), "the session timer is drawn")
    }

    func testSampleBufferCreationFromRenderedSurface() throws {
        let renderer = TerminalPiPSurfaceRenderer()
        let pool = try XCTUnwrap(PiPPixelBufferPool.make(size: renderer.size))
        let model = TerminalPiPSurfaceModel(title: "t", chip: .running, elapsed: "0:05", rows: ["x"], paused: false)
        let buffer = try XCTUnwrap(renderer.draw(model, into: pool))
        let sample = try XCTUnwrap(PiPEngine.makeSampleBuffer(for: buffer))
        XCTAssertTrue(CMSampleBufferIsValid(sample))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
    }
}

// MARK: - Session timer on every pop-out surface

/// Aaron asked for the session timer on *all* pop-out windows, not just the
/// terminal one. These pin it on the two that were missing it, at both levels
/// the terminal timer is pinned at: the model carries it, and it reaches the
/// pixels.
@MainActor
final class PiPElapsedOnAllSurfacesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func pixelHash(_ buffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "" }
        let data = Data(bytes: base, count: CVPixelBufferGetDataSize(buffer))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Preview pop-out

    func testPreviewModelCarriesElapsedFromSessionStart() {
        let source = PreviewPiPFrameSource(
            webView: nil,
            sessionID: UUID(),
            title: { "mac-mini" },
            subtitle: { "localhost:5173" },
            startedAt: { self.start },
            now: { self.start.addingTimeInterval(125) }   // 2:05
        )
        XCTAssertEqual(source.currentModel().elapsed, "2:05")
    }

    func testPreviewWithoutAStartDateShowsNoTimer() {
        let source = PreviewPiPFrameSource(
            webView: nil, sessionID: UUID(), title: { "t" }, subtitle: { nil }
        )
        XCTAssertNil(source.currentModel().elapsed)
    }

    func testPreviewTimerReachesThePixels() throws {
        let renderer = PreviewPiPSurfaceRenderer()
        let pool = try XCTUnwrap(PiPPixelBufferPool.make(size: renderer.size))
        let base = PreviewPiPSurfaceModel(
            title: "mac-mini", subtitle: "localhost:5173", elapsed: nil, paused: false, hasImage: false
        )
        var ticked = base
        ticked.elapsed = "1:03:27"

        let without = try XCTUnwrap(renderer.draw(base, image: nil, into: pool))
        let with = try XCTUnwrap(renderer.draw(ticked, image: nil, into: pool))
        XCTAssertEqual(pixelHash(without), pixelHash(try XCTUnwrap(renderer.draw(base, image: nil, into: pool))),
                       "same model renders identical pixels")
        XCTAssertNotEqual(pixelHash(without), pixelHash(with), "the session timer is drawn")
    }

    /// The timer has to advance while the user has *paused* following, which
    /// is exactly when the capture loop stops driving invalidations.
    func testPreviewTickerRunsWhilePaused() async throws {
        let source = PreviewPiPFrameSource(
            webView: nil, sessionID: UUID(), title: { "t" }, subtitle: { nil },
            startedAt: { self.start }
        )
        source.followSuspended = true
        var ticks = 0
        source.onInvalidate = { ticks += 1 }
        try await Task.sleep(for: .seconds(2.2))
        source.onInvalidate = nil
        XCTAssertGreaterThanOrEqual(ticks, 1, "no 1 Hz tick while paused — the clock would freeze")
    }
}
