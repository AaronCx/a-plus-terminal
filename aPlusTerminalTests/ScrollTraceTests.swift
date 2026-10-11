import XCTest
import SwiftTerm
@testable import aPlusTerminal

// MARK: - Helpers

@MainActor
private func makeTraceSettings(enabled: Bool) -> AppSettings {
    let suite = "ScrollTraceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: defaults)
    settings.scrollTraceEnabled = enabled
    return settings
}

private func makeRecord(
    startedAt: Date = Date(timeIntervalSince1970: 1_760_000_000.125),
    route: ScrollTrace.Route = .sgrWheel
) -> ScrollTrace.Record {
    ScrollTrace.Record(
        id: UUID(),
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(0.25),
        server: "probe",
        session: "aplus-test-0",
        transport: .meshyy,
        meshyyUnavailableReason: nil,
        transportState: .connected,
        rawSessionState: "connected",
        meshyyTransportFinished: false,
        msSinceLastInboundBytes: 12,
        msSinceLastInboundFrame: nil,
        belief: .init(
            mouseMode: "vt200", altScreen: true, applicationCursor: false,
            rows: 35, cols: 100, keyboardVisible: true, isFirstResponder: true,
            msSinceMouseModeChange: 400, msSinceBufferSwitch: nil
        ),
        wheelBridgeEnabled: true,
        route: route,
        declineReason: nil,
        emissions: [.init(msFromStart: 16, ticks: 1, up: true, momentum: false, row: 10, col: 51, bytesHex: "1b5b3c36343b35313b31304d")],
        totalBytes: 12,
        lastModesFrame: .init(active: [1000, 1006], ageMs: 900),
        lastScreenModeFrame: .init(alt: true, ageMs: 900)
    )
}

// MARK: - Store

@MainActor
final class ScrollTraceStoreTests: XCTestCase {
    private var directories: [URL] = []

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollTraceStoreTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    override func tearDown() {
        for url in directories {
            try? FileManager.default.removeItem(at: url)
        }
        directories = []
        super.tearDown()
    }

    func testRingKeepsTheNewest500() {
        let store = ScrollTraceStore(settings: makeTraceSettings(enabled: true), directory: nil, observesKeyboard: false)
        var ids: [UUID] = []
        for i in 0..<510 {
            let record = makeRecord(startedAt: Date(timeIntervalSince1970: TimeInterval(i)))
            ids.append(record.id)
            store.append(record)
        }
        XCTAssertEqual(store.records.count, ScrollTraceStore.capacity)
        XCTAssertEqual(ScrollTraceStore.capacity, 500)
        XCTAssertEqual(store.records.first?.id, ids[10], "the oldest ten were evicted")
        XCTAssertEqual(store.records.last?.id, ids[509])
    }

    func testDisabledRecordsNothing() {
        let store = ScrollTraceStore(settings: makeTraceSettings(enabled: false), directory: nil, observesKeyboard: false)
        XCTAssertFalse(store.isEnabled)
        store.append(makeRecord())
        XCTAssertTrue(store.records.isEmpty)
    }

    func testPersistenceRoundTripsThroughTheDirectory() async {
        let directory = makeDirectory()
        let settings = makeTraceSettings(enabled: true)
        let first = ScrollTraceStore(settings: settings, directory: directory, observesKeyboard: false)
        let records = (0..<3).map { makeRecord(startedAt: Date(timeIntervalSince1970: 1_760_000_000.5 + Double($0))) }
        records.forEach(first.append)
        await first.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("trace.json").path))

        let second = ScrollTraceStore(settings: settings, directory: directory, observesKeyboard: false)
        XCTAssertEqual(second.records.map(\.id), records.map(\.id))
        for (loaded, original) in zip(second.records, records) {
            XCTAssertEqual(loaded.startedAt.timeIntervalSince1970, original.startedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(loaded.belief, original.belief)
            XCTAssertEqual(loaded.emissions, original.emissions)
            XCTAssertEqual(loaded.lastModesFrame, original.lastModesFrame)
            XCTAssertEqual(loaded.route, original.route)
        }
    }

    func testCorruptFileStartsEmpty() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("trace.json"))
        let settings = makeTraceSettings(enabled: true)
        let store = ScrollTraceStore(settings: settings, directory: directory, observesKeyboard: false)
        XCTAssertTrue(store.records.isEmpty)
        // And it recovers: the next write replaces the corrupt file.
        store.append(makeRecord())
        await store.flush()
        let reloaded = ScrollTraceStore(settings: settings, directory: directory, observesKeyboard: false)
        XCTAssertEqual(reloaded.records.count, 1)
    }

    func testClearEmptiesTheRingAndTheFile() async {
        let directory = makeDirectory()
        let settings = makeTraceSettings(enabled: true)
        let store = ScrollTraceStore(settings: settings, directory: directory, observesKeyboard: false)
        store.append(makeRecord())
        await store.flush()
        store.clear()
        XCTAssertTrue(store.records.isEmpty)
        await store.flush()
        let reloaded = ScrollTraceStore(settings: settings, directory: directory, observesKeyboard: false)
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    func testExportCarriesSchemaAppRecordsAndISODates() throws {
        let store = ScrollTraceStore(settings: makeTraceSettings(enabled: true), directory: nil, observesKeyboard: false)
        store.append(makeRecord())
        store.append(makeRecord(route: .native))
        let exportedAt = Date(timeIntervalSince1970: 1_760_000_100.25)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try store.exportData(now: exportedAt)) as? [String: Any]
        )
        XCTAssertEqual(json["schema"] as? Int, 1)
        XCTAssertTrue((json["app"] as? String)?.hasPrefix("a+Terminal") ?? false)
        XCTAssertEqual(json["recordCount"] as? Int, 2)
        XCTAssertNotNil(json["timeZoneOffsetSeconds"] as? Int)
        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertNotNil(device["systemVersion"] as? String)
        XCTAssertNotNil(device["model"] as? String)

        let iso = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
        func isISO(_ value: Any?) -> Bool {
            guard let string = value as? String else { return false }
            return iso.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
        }
        XCTAssertTrue(isISO(json["exportedAt"]), "\(String(describing: json["exportedAt"]))")
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(isISO(records[0]["startedAt"]))
        XCTAssertTrue(isISO(records[0]["endedAt"]))
        XCTAssertEqual(records[0]["route"] as? String, "sgrWheel")
        XCTAssertEqual(records[1]["route"] as? String, "native")
        let belief = try XCTUnwrap(records[0]["belief"] as? [String: Any])
        XCTAssertEqual(belief["mouseMode"] as? String, "vt200")
    }

    func testExportFileIsNamedForTheShareSheet() throws {
        let store = ScrollTraceStore(settings: makeTraceSettings(enabled: true), directory: nil, observesKeyboard: false)
        let url = try store.exportFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(url.lastPathComponent.range(
            of: #"^aplus-scroll-trace-\d{8}-\d{6}\.json$"#, options: .regularExpression
        ), url.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSettingFollowsTheChannelUntilOverridden() {
        let suite = "ScrollTraceTests-channel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.scrollTraceOverride)
        XCTAssertTrue(settings.scrollTraceEnabled, "DEBUG builds default ON")
        settings.applyBuildChannel(.appStore)
        XCTAssertFalse(settings.scrollTraceEnabled, "App Store default is OFF")
        settings.applyBuildChannel(.unknown)
        XCTAssertFalse(settings.scrollTraceEnabled, "an unknown channel keeps the cached default")
        settings.scrollTraceEnabled = true
        settings.applyBuildChannel(.appStore)
        XCTAssertTrue(settings.scrollTraceEnabled, "an explicit choice beats the channel")
        XCTAssertEqual(AppSettings(defaults: defaults).scrollTraceOverride, true, "the choice persists")
    }
}

// MARK: - ScrollBridge tracing

@MainActor
final class ScrollBridgeTraceTests: XCTestCase {
    private final class Sink {
        var plain: [Data] = []
        var traced: [(data: Data, id: UUID)] = []
        var modeBTriggered = 0
    }

    private struct Harness {
        let view: TerminalEmulatorView
        let bridge: ScrollBridge
        let store: ScrollTraceStore
        let sink: Sink
    }

    /// A real emulator view at 1000×700, a real ScrollBridge attached to it,
    /// and (optionally) a tracer over an in-memory store.
    private func makeHarness(tracer tracing: Bool?, escapes: String) -> Harness {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        view.getTerminal().resize(cols: 100, rows: 35)
        view.feed(byteArray: ArraySlice(Array(escapes.utf8)))
        let sink = Sink()
        let bridge = ScrollBridge(sendData: { sink.plain.append($0) }, wheelBridgeEnabled: { true })
        bridge.onModeBTriggered = { sink.modeBTriggered += 1 }
        bridge.attach(to: view)
        let store = ScrollTraceStore(
            settings: makeTraceSettings(enabled: tracing ?? false), directory: nil, observesKeyboard: false
        )
        if tracing != nil {
            let framesAt = Date().addingTimeInterval(-2)
            bridge.tracer = ScrollGestureTracer(store: store) {
                ScrollTraceContext(
                    server: "probe", session: "aplus-test-0", transport: .meshyy,
                    meshyyUnavailableReason: nil, transportState: .connected,
                    rawSessionState: "connected", meshyyTransportFinished: false,
                    lastInboundBytesAt: framesAt, lastInboundFrameAt: nil,
                    lastModesFrame: (active: [1006, 1000], at: framesAt),
                    lastScreenModeFrame: (alt: true, at: framesAt)
                )
            }
            bridge.sendTraced = { sink.traced.append((data: $0, id: $1)) }
        }
        return Harness(view: view, bridge: bridge, store: store, sink: sink)
    }

    private let mouseOn = "\u{1B}[?1000h\u{1B}[?1006h"
    private let altScreen = "\u{1B}[?1049h"
    private let touch = CGPoint(x: 500, y: 699)   // the very bottom of the view

    private func expectedCell(_ view: TerminalEmulatorView, at point: CGPoint) -> (col: Int, row: Int) {
        let terminal = view.getTerminal()
        let col = min(max(Int(point.x / (view.bounds.width / CGFloat(terminal.cols))) + 1, 1), terminal.cols)
        let row = ScrollBridgeCore.wheelRow(forY: point.y, height: view.bounds.height, rows: terminal.rows)
        return (col, row)
    }

    func testMouseArmedRoutesToSGRWheelAndTheRecordNamesItsCause() throws {
        let h = makeHarness(tracer: true, escapes: mouseOn)
        let decision = try XCTUnwrap(h.bridge.beginSwipe())
        XCTAssertEqual(decision.mode, .sgrWheel)
        XCTAssertNotEqual(decision.mouseMode, .off)

        let bytes = h.bridge.injectSwipe(ticks: 3, up: true, at: touch)
        h.bridge.endSwipe()

        let rows = h.view.getTerminal().rows
        let cell = expectedCell(h.view, at: touch)
        XCTAssertLessThan(cell.row, rows, "a wheel event never claims the bottom (status) row")
        let one = "\u{1B}[<64;\(cell.col);\(cell.row)M"
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), one + one + one)
        XCTAssertEqual(h.sink.traced.map(\.data), [bytes], "traced bytes go through the traced send")
        XCTAssertTrue(h.sink.plain.isEmpty)

        let record = try XCTUnwrap(h.store.records.last)
        XCTAssertEqual(record.route, .sgrWheel)
        XCTAssertNil(record.declineReason)
        XCTAssertEqual(record.id, h.sink.traced.first?.id)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.transport, .meshyy)
        XCTAssertEqual(record.server, "probe")
        XCTAssertEqual(record.session, "aplus-test-0")
        XCTAssertEqual(record.transportState, .connected)
        XCTAssertTrue(record.wheelBridgeEnabled)
        let belief = try XCTUnwrap(record.belief)
        XCTAssertEqual(belief.mouseMode, String(describing: h.view.getTerminal().mouseMode))
        XCTAssertFalse(belief.altScreen)
        XCTAssertEqual(belief.rows, rows)
        XCTAssertNotNil(belief.msSinceMouseModeChange, "the mouse-mode change was stamped by the view")
        XCTAssertEqual(record.emissions.count, 1)
        let emission = try XCTUnwrap(record.emissions.first)
        XCTAssertEqual(emission.ticks, 3)
        XCTAssertTrue(emission.up)
        XCTAssertFalse(emission.momentum)
        XCTAssertEqual(emission.row, cell.row)
        XCTAssertEqual(emission.col, cell.col)
        XCTAssertEqual(emission.bytesHex, ScrollTrace.hex(bytes))
        XCTAssertEqual(record.totalBytes, bytes.count)
        XCTAssertEqual(record.lastModesFrame?.active, [1000, 1006])
        XCTAssertEqual(record.lastScreenModeFrame?.alt, true)
        XCTAssertGreaterThanOrEqual(record.lastModesFrame?.ageMs ?? 0, 1900)
        XCTAssertGreaterThanOrEqual(record.msSinceLastInboundBytes ?? 0, 1900)
    }

    func testAltScreenWithoutMouseRoutesToArrowKeys() throws {
        let h = makeHarness(tracer: true, escapes: altScreen)
        let decision = try XCTUnwrap(h.bridge.beginSwipe())
        XCTAssertEqual(decision.mode, .arrowKeys)
        XCTAssertTrue(decision.altScreen)
        XCTAssertEqual(h.sink.modeBTriggered, 1, "the mouse-hint trigger still fires on the decision")

        let bytes = h.bridge.injectSwipe(ticks: 2, up: false, at: touch)
        h.bridge.endSwipe()
        XCTAssertEqual(bytes, ScrollBridgeCore.arrowEvents(
            up: false, ticks: 2, applicationCursor: h.view.getTerminal().applicationCursor
        ))
        XCTAssertFalse(bytes.isEmpty)

        let record = try XCTUnwrap(h.store.records.last)
        XCTAssertEqual(record.route, .arrowKeys)
        XCTAssertEqual(record.belief?.altScreen, true)
        XCTAssertEqual(record.belief?.mouseMode, "off")
        XCTAssertNotNil(record.belief?.msSinceBufferSwitch, "the buffer switch was stamped by the view")
        let emission = try XCTUnwrap(record.emissions.first)
        XCTAssertNil(emission.row)
        XCTAssertNil(emission.col)
        XCTAssertFalse(emission.up)
        XCTAssertEqual(emission.bytesHex, ScrollTrace.hex(bytes))
    }

    func testPrimaryScreenWithoutMouseIsNativeSendsNothingAndIsRecorded() throws {
        let h = makeHarness(tracer: true, escapes: "")
        let decision = try XCTUnwrap(h.bridge.beginSwipe())
        XCTAssertEqual(decision.mode, .native)
        let bytes = h.bridge.injectSwipe(ticks: 3, up: true, at: touch)
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertTrue(h.sink.plain.isEmpty)
        XCTAssertTrue(h.sink.traced.isEmpty)

        let record = try XCTUnwrap(h.store.records.last)
        XCTAssertEqual(record.route, .native, "native is a route — the swipe went to local scrollback")
        XCTAssertNil(record.declineReason)
        XCTAssertNotNil(record.endedAt, "a native record closes at the decision")
        XCTAssertTrue(record.emissions.isEmpty)
        XCTAssertEqual(record.belief?.altScreen, false)
        XCTAssertEqual(record.belief?.mouseMode, "off")
    }

    func testTracingOffSendsIdenticalBytesAndRecordsNothing() {
        let scenarios: [(escapes: String, ticks: Int, up: Bool)] = [
            (mouseOn, 3, true), (mouseOn, 4, false), (altScreen, 2, true), (altScreen + mouseOn, 1, false), ("", 3, true),
        ]
        for scenario in scenarios {
            let traced = makeHarness(tracer: true, escapes: scenario.escapes)
            let disabled = makeHarness(tracer: false, escapes: scenario.escapes)
            let none = makeHarness(tracer: nil, escapes: scenario.escapes)
            var results: [Data] = []
            for h in [traced, disabled, none] {
                h.bridge.beginSwipe()
                results.append(h.bridge.injectSwipe(ticks: scenario.ticks, up: scenario.up, at: touch))
                h.bridge.endSwipe()
            }
            XCTAssertEqual(results[0], results[1], "\(scenario)")
            XCTAssertEqual(results[0], results[2], "\(scenario)")
            XCTAssertTrue(disabled.store.records.isEmpty)
            XCTAssertTrue(disabled.sink.traced.isEmpty, "a disabled trace never takes the traced send")
            XCTAssertEqual(disabled.sink.plain, results[1].isEmpty ? [] : [results[1]])
            XCTAssertEqual(none.sink.plain, results[2].isEmpty ? [] : [results[2]])
        }
    }

    func testSendOutcomesAreRecordedAgainstTheGesture() throws {
        let h = makeHarness(tracer: true, escapes: mouseOn)
        h.bridge.beginSwipe()
        h.bridge.injectSwipe(ticks: 1, up: true, at: touch)
        h.bridge.injectSwipe(ticks: 1, up: true, at: touch)
        h.bridge.endSwipe()
        let id = try XCTUnwrap(h.sink.traced.first?.id)
        let tracer = try XCTUnwrap(h.bridge.tracer)
        tracer.noteSend(recordID: id, via: .meshyy, error: nil)
        tracer.noteSend(recordID: id, via: .meshyy, error: "notConnected")
        let record = try XCTUnwrap(h.store.records.last)
        XCTAssertEqual(record.sendOK, 1)
        XCTAssertEqual(record.sendFailed, 1)
        XCTAssertEqual(record.lastSendError, "notConnected")
        XCTAssertEqual(record.sentVia, .meshyy)
        XCTAssertEqual(record.emissions.count, 2)
    }

    func testEmissionsAreCappedPerRecordAndTheRestCounted() throws {
        let h = makeHarness(tracer: true, escapes: mouseOn)
        h.bridge.beginSwipe()
        for _ in 0..<60 {
            h.bridge.injectSwipe(ticks: 1, up: true, at: touch)
        }
        h.bridge.endSwipe()
        let record = try XCTUnwrap(h.store.records.last)
        XCTAssertEqual(record.emissions.count, ScrollTraceStore.maxEmissionsPerRecord)
        XCTAssertEqual(record.emissionsDropped, 60 - ScrollTraceStore.maxEmissionsPerRecord)
        XCTAssertEqual(record.totalBytes, h.sink.traced.reduce(0) { $0 + $1.data.count })
    }

    func testANewSwipeClosesThePreviousRecord() throws {
        let h = makeHarness(tracer: true, escapes: mouseOn)
        h.bridge.beginSwipe()
        h.bridge.injectSwipe(ticks: 1, up: true, at: touch)
        h.bridge.beginSwipe()
        XCTAssertEqual(h.store.records.count, 2)
        XCTAssertNotNil(h.store.records[0].endedAt)
        XCTAssertNil(h.store.records[1].endedAt, "still open")
    }
}
