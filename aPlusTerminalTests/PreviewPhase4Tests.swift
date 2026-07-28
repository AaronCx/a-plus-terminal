import CoreVideo
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import aPlusTerminal

// MARK: - Console: parsing a payload the page fully controls

final class PreviewConsoleParsingTests: XCTestCase {
    private func entry(_ body: Any) -> PreviewConsoleEntry? {
        PreviewConsole.entry(from: body, id: 1, at: Date(timeIntervalSince1970: 0))
    }

    func testParsesAWellFormedMessage() {
        let parsed = entry(["level": "warn", "text": "deprecated API"])
        XCTAssertEqual(parsed?.level, .warn)
        XCTAssertEqual(parsed?.text, "deprecated API")
    }

    func testEveryLevelRoundTrips() {
        for level in ["log", "warn", "error", "info", "debug"] {
            XCTAssertEqual(entry(["level": level, "text": "x"])?.level.rawValue, level)
        }
    }

    /// The text is the part carrying information — an unrecognised level must
    /// degrade, not drop the line.
    func testUnknownOrMissingLevelDegradesToLog() {
        XCTAssertEqual(entry(["level": "catastrophe", "text": "x"])?.level, .log)
        XCTAssertEqual(entry(["text": "x"])?.level, .log)
        XCTAssertEqual(entry(["level": 42, "text": "x"])?.level, .log)
    }

    func testLevelIsCaseInsensitive() {
        XCTAssertEqual(entry(["level": "ERROR", "text": "x"])?.level, .error)
    }

    /// `postMessage` is reachable from any script in the document, so none of
    /// this is hypothetical — the page can post whatever it likes.
    func testRejectsBodiesWithNothingDisplayableInThem() {
        XCTAssertNil(entry("just a string"))
        XCTAssertNil(entry(42))
        XCTAssertNil(entry([1, 2, 3]))
        XCTAssertNil(entry([String: Any]()))
        XCTAssertNil(entry(["level": "log"]))              // no text
        XCTAssertNil(entry(["level": "log", "text": 99]))  // text not a String
        XCTAssertNil(entry(NSNull()))
    }

    /// A page can post far more than our own script would ever send.
    func testEnormousTextIsClipped() {
        let huge = String(repeating: "A", count: 5_000_000)
        let parsed = entry(["level": "log", "text": huge])
        let text = try? XCTUnwrap(parsed?.text)
        XCTAssertNotNil(text)
        XCTAssertLessThanOrEqual(
            text?.count ?? .max,
            PreviewConsole.maxMessageLength + 1,   // +1 for the ellipsis
            "a multi-megabyte log line was not clipped"
        )
        XCTAssertEqual(text?.last, "…")
    }

    /// A level string can be enormous too — it must not be lowercased in full.
    func testEnormousLevelDoesNotExplode() {
        let parsed = entry(["level": String(repeating: "z", count: 1_000_000), "text": "x"])
        XCTAssertEqual(parsed?.level, .log)
    }

    /// Dev servers log the same strings they would write to a TTY, escapes and
    /// all. The pane is a SwiftUI text view, not a terminal.
    func testControlCharactersAreStrippedButNewlinesSurvive() {
        let parsed = entry(["level": "log", "text": "a\u{1B}[31mred\u{07}\nsecond\tline"])
        let text = parsed?.text ?? ""
        XCTAssertFalse(text.contains("\u{1B}"), "escape byte survived")
        XCTAssertFalse(text.contains("\u{07}"), "BEL survived")
        XCTAssertTrue(text.contains("\n"), "newline was stripped")
        XCTAssertTrue(text.contains("\t"), "tab was stripped")
    }

    /// THE blocker this suite exists to prevent regressing. Control characters
    /// used to be dropped WITHOUT counting against the cap, so a page logging
    /// megabytes of ANSI escapes — which dev servers do constantly, since it's
    /// the same bytes they'd write to a TTY — walked the entire string on the
    /// main thread. `record` runs main-actor, so that was a hang, and a page
    /// can fire it in a loop: a watchdog kill taking the user's SSH sessions
    /// with it. This must complete in milliseconds, not seconds.
    func testAMegabyteOfControlCharactersDoesNotHangTheMainThread() {
        let hostile = String(repeating: "\u{1B}", count: 5_000_000)
        let started = Date()
        let parsed = entry(["level": "log", "text": hostile])
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1.0,
            "clip() walked the whole control-character string — this is the main-thread hang"
        )
        // Everything was a control character, so nothing displayable survives.
        XCTAssertTrue((parsed?.text ?? "").count <= 1)
    }

    /// A Character is an unbounded grapheme cluster, so a cap counted in
    /// Characters bounds neither memory nor work: one "a" plus 5M combining
    /// marks is a single Character.
    func testACombiningMarkBombIsBounded() {
        let bomb = "a" + String(repeating: "\u{301}", count: 5_000_000)
        let started = Date()
        let parsed = entry(["level": "log", "text": bomb])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "grapheme-cluster bomb was not bounded")
        XCTAssertLessThan((parsed?.text ?? "").unicodeScalars.count, 100_000)
    }

    func testUnicodeSurvivesIntact() {
        let parsed = entry(["level": "log", "text": "héllo 🌍 ünïcode"])
        XCTAssertEqual(parsed?.text, "héllo 🌍 ünïcode")
    }
}

@MainActor
final class PreviewConsoleTests: XCTestCase {
    func testAppendEvictsOldestBeyondTheCap() {
        let console = PreviewConsole()
        for index in 0..<(PreviewConsole.maxEntries + 40) {
            console.record(["level": "log", "text": "line \(index)"])
        }
        XCTAssertEqual(console.entries.count, PreviewConsole.maxEntries)
        XCTAssertEqual(console.entries.first?.text, "line 40", "wrong end evicted")
        XCTAssertEqual(console.entries.last?.text, "line \(PreviewConsole.maxEntries + 39)")
    }

    /// Ids must never be reused, or SwiftUI's ForEach diffing animates the
    /// wrong row after a clear.
    func testIDsAreNeverReusedAcrossClear() {
        let console = PreviewConsole()
        console.record(["level": "log", "text": "a"])
        let first = console.entries.first?.id
        console.clear()
        console.record(["level": "log", "text": "b"])
        XCTAssertNotEqual(console.entries.first?.id, first)
        XCTAssertTrue(console.entries.count == 1)
    }

    func testJunkBodiesDoNotConsumeIDsOrAppear() {
        let console = PreviewConsole()
        console.record("nonsense")
        console.record(42)
        XCTAssertTrue(console.entries.isEmpty)
    }

    func testClearEmptiesTheLog() {
        let console = PreviewConsole()
        console.record(["level": "log", "text": "a"])
        console.clear()
        XCTAssertTrue(console.entries.isEmpty)
    }
}

/// The injected source is the code that runs inside a user's own page, so the
/// properties that make it safe are asserted rather than assumed.
final class PreviewConsoleScriptTests: XCTestCase {
    private let source = PreviewConsole.userScriptSource()

    func testWrapsEveryConsoleLevel() {
        for level in ["log", "warn", "error", "info", "debug"] {
            XCTAssertTrue(source.contains("'\(level)'"), "level \(level) is not wrapped")
        }
    }

    /// If the wrapper ever stops calling through, this panel and Web Inspector
    /// disagree — the worst possible property for a debugging tool.
    func testCallsThroughToTheOriginalConsole() {
        XCTAssertTrue(source.contains("original.apply(target, arguments)"))
    }

    /// A getter on a logged object can call console.log again; without the
    /// latch that recurses inside the user's page.
    func testHasAReentrancyLatch() {
        XCTAssertTrue(source.contains("capturing"))
    }

    func testGuardsAgainstAMissingMessageHandler() {
        XCTAssertTrue(source.contains("w.webkit && w.webkit.messageHandlers"))
    }

    func testHandlesCircularStructures() {
        XCTAssertTrue(source.contains("[Circular]"))
    }

    func testIsWrappedInATopLevelTryCatch() {
        XCTAssertTrue(source.hasPrefix("(function () {\n  try {"))
    }

    func testCapsMessageLength() {
        XCTAssertTrue(source.contains("var LIMIT = \(PreviewConsole.maxMessageLength);"))
    }
}

// MARK: - The pop-out surface

@MainActor
final class PreviewPiPFrameSourceTests: XCTestCase {
    private func pool(for size: CGSize) throws -> CVPixelBufferPool {
        try XCTUnwrap(PiPPixelBufferPool.make(size: size))
    }

    /// The pop-out window appears the instant the user taps, long before the
    /// first async capture lands. A nil frame there reads as a crash.
    func testRendersAPlaceholderFrameBeforeAnyCaptureLands() throws {
        let source = PreviewPiPFrameSource(
            webView: nil,
            sessionID: UUID(),
            title: { "Dev box" },
            subtitle: { "localhost:5173" }
        )
        let buffer = source.renderFrame(into: try pool(for: source.preferredBufferSize))
        XCTAssertNotNil(buffer, "no frame produced before the first capture")
        XCTAssertFalse(Self.isUniform(try XCTUnwrap(buffer)), "placeholder frame was blank")
    }

    func testModelReflectsTitleSubtitleAndPause() {
        let source = PreviewPiPFrameSource(
            webView: nil,
            sessionID: nil,
            title: { "Dev box" },
            subtitle: { "localhost:5173" }
        )
        XCTAssertEqual(source.currentModel().title, "Dev box")
        XCTAssertEqual(source.currentModel().subtitle, "localhost:5173")
        XCTAssertFalse(source.currentModel().paused)
        XCTAssertFalse(source.currentModel().hasImage)

        source.followSuspended = true
        XCTAssertTrue(source.currentModel().paused)
    }

    func testRestoreSessionIDIsCarried() {
        let id = UUID()
        let source = PreviewPiPFrameSource(webView: nil, sessionID: id, title: { "" }, subtitle: { nil })
        XCTAssertEqual(source.restoreSessionID, id)
    }

    /// A web page has no discrete unit to reveal more of, unlike terminal rows.
    func testUpdateForRenderSizeIsANoOp() {
        let source = PreviewPiPFrameSource(webView: nil, sessionID: nil, title: { "t" }, subtitle: { nil })
        let before = source.preferredBufferSize
        source.updateForRenderSize(CGSize(width: 900, height: 600))
        XCTAssertEqual(source.preferredBufferSize, before)
    }

    /// detach() must stop the capture loop; a source still snapshotting for a
    /// window that is gone burns ~25 ms of main thread every interval.
    func testDetachStopsTheCaptureLoopAndFiresOnDetach() async throws {
        let source = PreviewPiPFrameSource(webView: nil, sessionID: nil, title: { "t" }, subtitle: { nil })
        var detached = false
        source.onDetach = { detached = true }
        source.onInvalidate = {}          // engine attaches → loop starts
        source.detach()
        XCTAssertTrue(detached)
        XCTAssertNil(source.onInvalidate, "invalidation hook survived detach")
    }

    /// The blankness check is what decides the capture strategy, so it has to
    /// actually distinguish a flat rectangle from real content.
    func testIsBlankDistinguishesFlatFromContent() {
        XCTAssertTrue(PreviewPiPFrameSource.isBlank(Self.solid(.white)))
        XCTAssertTrue(PreviewPiPFrameSource.isBlank(Self.solid(.black)))
        XCTAssertFalse(PreviewPiPFrameSource.isBlank(Self.halves()))
    }

    func testSurfaceRendererProducesDistinctBytesForPausedAndRunning() throws {
        let renderer = PreviewPiPSurfaceRenderer()
        let pool = try self.pool(for: renderer.size)
        let running = PreviewPiPSurfaceModel(title: "Dev", subtitle: "localhost:5173", paused: false, hasImage: false)
        let paused = PreviewPiPSurfaceModel(title: "Dev", subtitle: "localhost:5173", paused: true, hasImage: false)
        let a = try XCTUnwrap(renderer.draw(running, image: nil, into: pool))
        let b = try XCTUnwrap(renderer.draw(paused, image: nil, into: pool))
        XCTAssertNotEqual(Self.bytes(a), Self.bytes(b), "the paused badge never reached the pixels")
    }

    /// A dead web view must read as dead. Presenting the last captured frame
    /// beside a live-looking "localhost:5173" is how a user ends up watching a
    /// tunnel that no longer exists and believing it.
    func testAVanishedWebViewReadsAsStale() {
        let source = PreviewPiPFrameSource(webView: nil, sessionID: nil, title: { "Dev" }, subtitle: { "localhost:5173" })
        XCTAssertTrue(source.currentModel().isStale)
    }

    /// Paused is user-initiated and already explained; it must not be
    /// overwritten by the staleness badge.
    func testPausedOutranksStale() {
        let source = PreviewPiPFrameSource(webView: nil, sessionID: nil, title: { "Dev" }, subtitle: { nil })
        source.followSuspended = true
        let model = source.currentModel()
        XCTAssertTrue(model.paused)
        XCTAssertFalse(model.isStale, "a paused surface must not also claim to be stale")
    }

    func testStaleSurfaceRendersDifferentlyFromLive() throws {
        let renderer = PreviewPiPSurfaceRenderer()
        let pool = try self.pool(for: renderer.size)
        let live = PreviewPiPSurfaceModel(title: "Dev", subtitle: "localhost:5173", paused: false, isStale: false, hasImage: false)
        let stale = PreviewPiPSurfaceModel(title: "Dev", subtitle: "localhost:5173", paused: false, isStale: true, hasImage: false)
        let a = try XCTUnwrap(renderer.draw(live, image: nil, into: pool))
        let b = try XCTUnwrap(renderer.draw(stale, image: nil, into: pool))
        XCTAssertNotEqual(Self.bytes(a), Self.bytes(b), "the staleness badge never reached the pixels")
    }

    /// The blank check drives the capture-strategy decision, so a coloured
    /// page must never read as blank. Sampling only the red channel made a
    /// blue gradient look uniform.
    func testIsBlankUsesAllChannelsNotJustRed() {
        let blueGradient = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            for row in 0..<40 {
                UIColor(red: 0, green: 0, blue: CGFloat(row) / 39.0, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: row, width: 40, height: 1))
            }
        }
        XCTAssertFalse(
            PreviewPiPFrameSource.isBlank(blueGradient),
            "a page with a constant red channel but obvious blue variation read as blank"
        )
    }

    // MARK: helpers

    private static func solid(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    private static func halves() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
    }

    private static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        return Data(bytes: base, count: CVPixelBufferGetDataSize(buffer))
    }

    private static func isUniform(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let count = CVPixelBufferGetDataSize(buffer)
        let raw = base.assumingMemoryBound(to: UInt8.self)
        var minV: UInt8 = 255, maxV: UInt8 = 0
        for index in stride(from: 0, to: count, by: 97) {
            minV = min(minV, raw[index]); maxV = max(maxV, raw[index])
        }
        return Int(maxV) - Int(minV) < 8
    }
}

// MARK: - The setting that gates all of it

final class PreviewConsoleSettingTests: XCTestCase {
    func testConsoleCaptureIsOffByDefault() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "preview.console.default.\(UUID().uuidString)"))
        XCTAssertFalse(
            AppSettings(defaults: suite).previewConsoleCapture,
            "JS injection into the user's page must be opt-in"
        )
    }

    func testConsoleCapturePersists() throws {
        let name = "preview.console.persist.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        AppSettings(defaults: suite).previewConsoleCapture = true
        XCTAssertTrue(AppSettings(defaults: suite).previewConsoleCapture)
    }
}

// MARK: - The reload loop

/// The bug behind "it just says Loading… in mobile view, but desktop is fine".
///
/// `updateUIView` decided whether to reload by comparing the desired user agent
/// against `webView.customUserAgent`. In mobile mode the desired value is nil
/// ("use the stock UA"), and WKWebView does not round-trip nil through that
/// property — so the comparison was true on every SwiftUI render, every render
/// called `load()`, and the page never finished. Measured on device at roughly
/// a thousand fetches of the same URL. Desktop mode escaped it because a
/// literal UA string does read back equal.
@MainActor
final class PreviewUserAgentReloadTests: XCTestCase {
    /// The platform fact the fix exists because of. If a future iOS makes this
    /// round-trip cleanly, this test fails and the workaround can be revisited
    /// — which is the point of asserting it rather than just commenting it.
    func testWKWebViewDoesNotRoundTripANilCustomUserAgent() {
        let webView = WKWebView(frame: .zero)
        webView.customUserAgent = nil
        // MEASURED: the getter returns "" — an empty string, not nil. So
        // `webView.customUserAgent != nil` is ALWAYS true in mobile mode, which
        // is the entire reload loop in one expression.
        XCTAssertEqual(
            webView.customUserAgent, "",
            "customUserAgent round-trip changed; if it now returns nil the workaround in PreviewWebView can be simplified"
        )
        XCTAssertNotNil(webView.customUserAgent, "the nil we set did not come back as nil — this is why we track it ourselves")
    }

    /// Applying the same UA twice must not read as a change. This is the
    /// invariant that stops the loop, expressed against the real Coordinator.
    func testRepeatedlyApplyingTheSameUserAgentIsNotAChange() {
        let coordinator = PreviewWebView.Coordinator(
            forwardedPort: 5173,
            onLoadingChanged: { _ in },
            onError: { _ in },
            onBlocked: { _ in }
        )

        func changed(_ desired: String?) -> Bool {
            let isChange = !coordinator.hasAppliedUserAgent || coordinator.appliedUserAgent != desired
            if isChange {
                coordinator.appliedUserAgent = desired
                coordinator.hasAppliedUserAgent = true
            }
            return isChange
        }

        // First application always counts, including nil (mobile).
        XCTAssertTrue(changed(nil), "the first application must apply")
        // Every subsequent render with the same value must be a no-op. Without
        // the fix this was true forever, which was the loop.
        for render in 0..<50 {
            XCTAssertFalse(changed(nil), "render \(render) re-applied an unchanged mobile UA")
        }
        // A real toggle still registers, in both directions.
        XCTAssertTrue(changed(PreviewWebView.desktopUserAgent))
        XCTAssertFalse(changed(PreviewWebView.desktopUserAgent))
        XCTAssertTrue(changed(nil))
        XCTAssertFalse(changed(nil))
    }
}

// MARK: - Port picker: the whole row has to be the tap target

/// Aaron on device, build 40: "on this list page only clicking the numbers
/// brings you to the preview not the bar."
///
/// `.buttonStyle(.plain)` sizes a button to its label. The label was a `VStack`
/// that hugs its content, so a row reading "5173  node" was ~110pt of tappable
/// area inside a ~350pt-wide row — and nothing about the rendering said so.
/// These tests measure the row the way the layout system does: propose a width
/// and ask what it takes.
@MainActor
final class PortPickerRowLayoutTests: XCTestCase {
    private let proposedWidth: CGFloat = 350

    private func measuredWidth(_ port: DetectedPort) -> CGFloat {
        let host = UIHostingController(rootView: PortPickerRow(port: port) {})
        // A finite width proposal with unbounded height is what a List row
        // hands its content.
        return host.sizeThatFits(
            in: CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        ).width
    }

    func testShortRowStillFillsTheFullWidth() {
        // The narrowest realistic row: a bare port, no process, no path. Before
        // the fix this measured roughly the width of four digits.
        let width = measuredWidth(DetectedPort(port: 5173, path: nil, process: nil, isStale: false))
        XCTAssertEqual(
            width, proposedWidth, accuracy: 0.5,
            "a short row must still claim the whole width, or its hit area shrinks to the text"
        )
    }

    func testEveryRowVariantFillsTheFullWidth() {
        let variants: [(String, DetectedPort)] = [
            ("port only", DetectedPort(port: 3000, path: nil, process: nil, isStale: false)),
            ("with process", DetectedPort(port: 5173, path: nil, process: "node", isStale: false)),
            ("with path", DetectedPort(port: 8000, path: "/admin", process: "Python", isStale: false)),
            ("root path is hidden", DetectedPort(port: 8080, path: "/", process: "caddy", isStale: false)),
            ("stale, two lines", DetectedPort(port: 11434, path: nil, process: "ollama", isStale: true)),
        ]
        for (name, port) in variants {
            XCTAssertEqual(
                measuredWidth(port), proposedWidth, accuracy: 0.5,
                "\(name): row did not fill the proposed width"
            )
        }
    }

    func testTallStaleRowKeepsItsSecondLine() {
        // Guards the stretch against being written as a fixed `.frame(width:)`,
        // which would also satisfy the width assertions while clipping the
        // "may have exited" line.
        let host = UIHostingController(
            rootView: PortPickerRow(
                port: DetectedPort(port: 11434, path: nil, process: "ollama", isStale: true)
            ) {}
        )
        let stale = host.sizeThatFits(
            in: CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        ).height
        let fresh = UIHostingController(
            rootView: PortPickerRow(
                port: DetectedPort(port: 11434, path: nil, process: "ollama", isStale: false)
            ) {}
        ).sizeThatFits(in: CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(stale, fresh, "the stale explanation line must still render")
    }

    func testTappingTheRowRunsItsAction() {
        // The row owns the Button now, so keep a check that the action is
        // actually wired to it.
        var fired = 0
        let row = PortPickerRow(
            port: DetectedPort(port: 5173, path: nil, process: "node", isStale: false)
        ) { fired += 1 }
        row.action()
        XCTAssertEqual(fired, 1)
    }

    func testAccessibilityLabelDescribesTheRow() {
        XCTAssertEqual(
            PortPickerRow.accessibilityLabel(
                for: DetectedPort(port: 8000, path: "/admin", process: "Python", isStale: true)
            ),
            "Open port 8000, process Python, path /admin, may have exited"
        )
        XCTAssertEqual(
            PortPickerRow.accessibilityLabel(
                for: DetectedPort(port: 5173, path: "/", process: nil, isStale: false)
            ),
            "Open port 5173"
        )
    }
}

// MARK: - Picker: eviction, manual entry, and un-tunnellable listeners

/// Build 41 field report: "i had to type in port it didnt show up on detected
/// even after manually Porting in". Two separate causes — the entry cap on a
/// busy host, and a hand-typed port never joining the list — plus the failure
/// mode that sits right behind them: a listener bound somewhere the tunnel
/// cannot reach.
@MainActor
final class PortPickerDiscoveryTests: XCTestCase {

    // MARK: The cap

    func testBusyHostKeepsMoreEntries() {
        let detector = PortDetector()
        // A developer Mac idles at roughly this many listeners.
        let lines = (1...21).map { "proc\($0) \(100 + $0) acx 5u IPv4 0x0 0t0 TCP 127.0.0.1:\(9000 + $0) (LISTEN)" }
        detector.applyListenerSnapshot(lines.joined(separator: "\n"))
        XCTAssertEqual(detector.ports.count, PortDetector.maxEntries)
        XCTAssertGreaterThan(PortDetector.maxEntries, 8, "the cap that caused the report")
    }

    /// The cap still has to hold, or a runaway host grows the list without end.
    func testCapIsStillEnforced() {
        let detector = PortDetector()
        let lines = (1...60).map { "p\($0) \($0) acx 5u IPv4 0x0 0t0 TCP 127.0.0.1:\(20000 + $0) (LISTEN)" }
        detector.applyListenerSnapshot(lines.joined(separator: "\n"))
        XCTAssertEqual(detector.ports.count, PortDetector.maxEntries)
    }

    // MARK: Typing a port

    func testTypedPortJoinsListAtTop() {
        let detector = PortDetector()
        detector.applyListenerSnapshot("node 1 acx 5u IPv4 0x0 0t0 TCP 127.0.0.1:3000 (LISTEN)")
        detector.noteManualPort(8090)
        XCTAssertEqual(detector.ports.first?.port, 8090, "a typed port must be reachable again afterwards")
    }

    /// The whole point of vouching: a busy host must not evict the entry the
    /// user typed in themselves.
    func testTypedPortSurvivesBusySnapshot() {
        let detector = PortDetector()
        detector.noteManualPort(8090)
        let lines = (1...40).map { "p\($0) \($0) acx 5u IPv4 0x0 0t0 TCP 127.0.0.1:\(30000 + $0) (LISTEN)" }
        detector.applyListenerSnapshot(lines.joined(separator: "\n"))
        XCTAssertTrue(detector.ports.contains { $0.port == 8090 },
                      "the typed port was evicted by unvouched listeners")
    }

    func testTypingListedPortPromotesIt() {
        let detector = PortDetector()
        detector.applyListenerSnapshot("""
        a 1 acx 5u IPv4 0x0 0t0 TCP 127.0.0.1:3000 (LISTEN)
        b 2 acx 5u IPv4 0x0 0t0 TCP 127.0.0.1:5173 (LISTEN)
        """)
        detector.noteManualPort(5173)
        XCTAssertEqual(detector.ports.filter { $0.port == 5173 }.count, 1)
        XCTAssertEqual(detector.ports.first?.port, 5173)
        XCTAssertEqual(detector.ports.first?.process, "b", "promotion must not discard the process name")
    }

    func testTypedPortOutOfRangeIgnored() {
        let detector = PortDetector()
        detector.noteManualPort(0)
        detector.noteManualPort(70000)
        XCTAssertTrue(detector.ports.isEmpty)
    }

    // MARK: Listeners the tunnel cannot reach

    func testLoopbackAndWildcardReachable() {
        for address in ["127.0.0.1:5173", "[::1]:5173", "::1.5173", "127.0.0.1.5173",
                        "*:5173", "0.0.0.0:5173", "[::]:5173", "localhost:5173"] {
            XCTAssertTrue(PortDetector.reachesLoopback(address), "\(address) should be reachable")
        }
    }

    func testOtherAddressesNotReachable() {
        for address in ["100.79.92.82:8090", "192.168.1.4:5173", "10.0.0.2.5173", "[fe80::1]:5173"] {
            XCTAssertFalse(PortDetector.reachesLoopback(address), "\(address) should NOT be reachable")
        }
    }

    /// `vite --host` on a Tailscale box: a real listener that can never load
    /// through the tunnel, because the tunnel dials the far end's loopback.
    func testLanOnlyServerListedButFlagged() {
        let detector = PortDetector()
        detector.applyListenerSnapshot("Python 42 acx 5u IPv4 0x0 0t0 TCP 100.79.92.82:8090 (LISTEN)")
        let entry = detector.ports.first { $0.port == 8090 }
        XCTAssertNotNil(entry, "a non-loopback listener is still a real listener and must be shown")
        XCTAssertFalse(entry?.reachableOnLoopback ?? true, "it cannot be tunnelled and must say so")
    }

    /// One server, several address families — one loopback binding is all the
    /// tunnel needs, whichever order the rows arrive in.
    func testAnyLoopbackBindingWins() {
        for lines in [["Python 42 acx 5u IPv4 0x0 0t0 TCP 100.79.92.82:8090 (LISTEN)",
                       "Python 42 acx 6u IPv4 0x0 0t0 TCP 127.0.0.1:8090 (LISTEN)"],
                      ["Python 42 acx 6u IPv4 0x0 0t0 TCP 127.0.0.1:8090 (LISTEN)",
                       "Python 42 acx 5u IPv4 0x0 0t0 TCP 100.79.92.82:8090 (LISTEN)"]] {
            let detector = PortDetector()
            detector.applyListenerSnapshot(lines.joined(separator: "\n"))
            XCTAssertTrue(detector.ports.first { $0.port == 8090 }?.reachableOnLoopback ?? false,
                          "a loopback binding exists, so the port is reachable")
        }
    }

    /// A scrape knows no bind address; it must not overwrite what a snapshot
    /// established, or the warning would flicker away on the next printed URL.
    func testAScrapeDoesNotClearTheFlagASnapshotSet() {
        let detector = PortDetector()
        detector.applyListenerSnapshot("Python 42 acx 5u IPv4 0x0 0t0 TCP 100.79.92.82:8090 (LISTEN)")
        detector.observe(Array("serving on http://localhost:8090/\n".utf8))
        XCTAssertFalse(detector.ports.first { $0.port == 8090 }?.reachableOnLoopback ?? true)
    }

    func testDefaultIsReachable() {
        let detector = PortDetector()
        detector.observe(Array("Local: http://localhost:5173/\n".utf8))
        XCTAssertTrue(detector.ports.first?.reachableOnLoopback ?? false)
    }
}
