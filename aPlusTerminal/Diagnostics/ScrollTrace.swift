// Beta-only (`MESHYY`): the trace exists to debug meshyy, and App Review tests
// the exact uploaded binary (no dormant features), so candidates compile it out.
#if MESHYY
import Foundation
import Observation
import SwiftTerm
import UIKit
import os

/// On-device swipe trace (Settings → Diagnostics → Scroll trace).
///
/// Every scroll bug this app has shipped was the emulator's BELIEF about the
/// far side (mouse mode, alt screen) diverging from what tmux actually had
/// armed — and every one was "verified" off-device. This records, per swipe,
/// what the app believed, which route `ScrollBridge` took on that belief, the
/// exact bytes it sent and whether the transport took them, so the next dead
/// swipe on a real phone names its own cause.
///
/// Observation only: nothing here changes routing. Local only: records live
/// in Application Support and leave the phone solely through a share the
/// user starts. Only ScrollBridge emissions are recorded — never general
/// input, which carries keystrokes and passwords.
enum ScrollTrace {
    static let schemaVersion = 1

    enum Transport: String, Codable, Sendable {
        case ssh, meshyy
    }

    /// Where `session` came from — they are not equally trustworthy.
    enum SessionSource: String, Codable, Sendable {
        /// The meshyy session this tab is attached to (authoritative).
        case meshyy
        /// The server's persisted last-seen tmux/screen target: shared by all
        /// of that server's tabs, refreshed only on keepalive ticks and never
        /// cleared on detach, so it can name a session this tab is not in.
        case serverLastMultiplexerTarget
    }

    enum TransportState: String, Codable, Sendable {
        case connected, reconnecting, dead
    }

    enum Route: String, Codable, Sendable {
        case sgrWheel, arrowKeys, native, declined

        init(_ mode: ScrollBridgeCore.Mode) {
            switch mode {
            case .sgrWheel: self = .sgrWheel
            case .arrowKeys: self = .arrowKeys
            case .native: self = .native
            }
        }
    }

    /// Why the pan never got as far as a routing decision. (`.native` is a
    /// route, not a decline: returning false there hands the swipe to
    /// SwiftTerm's local scrollback — a dead swipe if tmux is on the alt
    /// screen and the emulator does not know it.)
    enum DeclineReason: String, Codable, Sendable {
        /// A long-press text selection was holding the scroll pan down.
        case selectionHold
        /// The pan was more horizontal than vertical.
        case horizontal
        /// The bridge had lost its terminal view.
        case noView
    }

    /// What the emulator believed when the swipe was routed.
    struct Belief: Codable, Equatable, Sendable {
        var mouseMode: String
        var altScreen: Bool
        var applicationCursor: Bool
        var rows: Int
        var cols: Int
        var keyboardVisible: Bool
        /// Since the software keyboard last showed or hid — a toggle resizes
        /// the pty, and tmux re-pulses its mouse modes on every WINCH.
        var msSinceKeyboardChange: Int?
        var isFirstResponder: Bool
        /// Since the mouse mode last actually changed (not merely re-asserted).
        var msSinceMouseModeChange: Int?
        /// What it changed from, e.g. "off" → `mouseMode`.
        var previousMouseMode: String?
        var msSinceBufferSwitch: Int?
        /// The local viewport is up in SwiftTerm's own scrollback: the user is
        /// looking at stale local history, so even a wheel event tmux honours
        /// can look like "nothing happens". nil on records from before this
        /// field existed.
        var isScrolledBack: Bool?
        /// SwiftTerm's scroll position, 0 (top of scrollback) … 1 (live
        /// bottom); nil when there is no local scrollback (alt screen, or too
        /// little output).
        var scrollPosition: Double?
        /// Index of the top visible line in the active buffer (yDisp).
        var topVisibleRow: Int?
    }

    /// One `ScrollBridge.emit` that produced bytes.
    struct Emission: Codable, Equatable, Sendable {
        var msFromStart: Int
        var ticks: Int
        var up: Bool
        var momentum: Bool
        /// The 1-based cell the wheel event claimed; nil for arrow keys.
        var row: Int?
        var col: Int?
        var bytesHex: String
        /// ms from the record's start until the outbox finished sending these
        /// bytes (meshyy: handed to the QUIC stream; SSH: written to the
        /// channel). Far above `msFromStart` = the bytes waited in the FIFO
        /// outbox behind something else.
        var sendDoneMs: Int?
    }

    struct ModesFrame: Codable, Equatable, Sendable {
        var active: [Int]
        var ageMs: Int
    }

    struct ScreenModeFrame: Codable, Equatable, Sendable {
        var alt: Bool
        var ageMs: Int
    }

    /// The last pty size a transport was handed. Differing from the belief's
    /// rows/cols = the far side's pty is not the size the wheel rows assume.
    struct PtyResize: Codable, Equatable, Sendable {
        var cols: Int
        var rows: Int
        var via: Transport
        var ok: Bool
        var error: String?
        var ageMs: Int
    }

    /// One gesture (or one declined gesture).
    struct Record: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var server: String?
        var session: String?
        var transport: Transport
        /// Which tab (TerminalSession.id) — two tabs on one server differ here.
        var tabID: UUID?
        var sessionSource: SessionSource?
        var meshyyUnavailableReason: String?
        var transportState: TransportState
        var rawSessionState: String
        var meshyyTransportFinished: Bool?
        var msSinceLastInboundBytes: Int?
        var msSinceLastInboundFrame: Int?
        var belief: Belief?
        var wheelBridgeEnabled: Bool
        var route: Route
        var declineReason: DeclineReason?
        var emissions: [Emission] = []
        var emissionsDropped: Int = 0
        var totalBytes: Int = 0
        var sendOK: Int = 0
        var sendFailed: Int = 0
        var lastSendError: String?
        /// The longest any of this gesture's sends took from leaving
        /// ScrollBridge to the transport accepting it.
        var maxSendLatencyMs: Int?
        /// ms from start when the last send of this gesture finished.
        var lastSendDoneMs: Int?
        /// The cheapest on-device sign the far side reacted: ms from this
        /// gesture's first successful send to the first output that came
        /// back within `ScrollGestureTracer.responseWindow` of its last send
        /// (a tmux copy-mode redraw answers a wheel event). nil with sendOK > 0
        /// = nothing came back. Byte counts only, never the bytes.
        var msToFirstInboundAfterSend: Int?
        var inboundBytesAfterSend: Int?
        /// The transport the outbox actually used when it dequeued the bytes.
        var sentVia: Transport?
        var lastModesFrame: ModesFrame?
        var lastScreenModeFrame: ScreenModeFrame?
        var lastPtyResize: PtyResize?
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }

    // MARK: JSON

    private static let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoStyle.format(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return try isoStyle.parse(try container.decode(String.self))
        }
        return decoder
    }
}

/// The session-side half of a record, supplied by the owning
/// `TerminalSession` through a closure — `ScrollBridge` keeps no session
/// reference.
struct ScrollTraceContext {
    var tabID: UUID? = nil
    struct PtyResize {
        var cols: Int
        var rows: Int
        var via: ScrollTrace.Transport
        var error: String?
        var at: Date
    }

    var server: String?
    var session: String?
    var sessionSource: ScrollTrace.SessionSource? = nil
    var transport: ScrollTrace.Transport
    var meshyyUnavailableReason: String?
    var transportState: ScrollTrace.TransportState
    var rawSessionState: String
    var meshyyTransportFinished: Bool?
    var lastInboundBytesAt: Date?
    var lastPtyResize: PtyResize? = nil
    /// Pong-inclusive "last frame from the daemon" — nil until MeshyyKit
    /// exposes one (see TerminalSession.scrollTraceContext()).
    var lastInboundFrameAt: Date?
    var lastModesFrame: (active: Set<Int>, at: Date)?
    var lastScreenModeFrame: (alt: Bool, at: Date)?
}

// MARK: - Store

/// Ring buffer of the last `capacity` records, persisted to
/// Application Support so a force-quit right after a dead swipe keeps it.
@MainActor
@Observable
final class ScrollTraceStore {
    static let capacity = 500
    static let maxEmissionsPerRecord = 48

    private(set) var records: [ScrollTrace.Record] = []

    /// Bound to `AppSettings.scrollTraceEnabled`.
    var isEnabled: Bool {
        get { settings.scrollTraceEnabled }
        set { settings.scrollTraceEnabled = newValue }
    }

    /// Software keyboard on screen, from the app-wide will-show/will-hide
    /// notifications (a hardware keyboard keeps this false while the terminal
    /// is first responder — the record carries both).
    @ObservationIgnored private(set) var keyboardVisible = false
    @ObservationIgnored private(set) var keyboardChangedAt: Date?

    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let persistDelay: Duration
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let writer = ScrollTraceFileWriter()
    @ObservationIgnored private var keyboardObservers: KeyboardObservers?
    /// Reading the persisted ring (up to 500 records, possibly a few MB) runs
    /// on the writer actor, never on the launch path. Every write waits for it.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// `clear()` ran before the load finished: what it loads is discarded.
    @ObservationIgnored private var discardLoaded = false

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ScrollTrace", isDirectory: true)
    }

    /// - Parameters:
    ///   - directory: where `trace.json` lives; nil keeps the trace in memory only.
    ///   - persistDelay: how long changes coalesce before one background write.
    init(
        settings: AppSettings,
        directory: URL? = ScrollTraceStore.defaultDirectory,
        persistDelay: Duration = .seconds(2),
        observesKeyboard: Bool = true
    ) {
        self.settings = settings
        self.fileURL = directory?.appendingPathComponent("trace.json")
        self.persistDelay = persistDelay
        if let fileURL {
            let writer = self.writer
            loadTask = Task { [weak self] in
                let loaded = await writer.load(from: fileURL, capacity: Self.capacity)
                self?.adoptLoaded(loaded)
            }
        }
        if observesKeyboard {
            keyboardObservers = KeyboardObservers { [weak self] visible in
                guard let self else { return }
                if visible != self.keyboardVisible {
                    self.keyboardChangedAt = Date()
                }
                self.keyboardVisible = visible
            }
        }
    }

    /// Puts the persisted records in front of anything recorded while they
    /// were loading.
    private func adoptLoaded(_ loaded: [ScrollTrace.Record]) {
        loadTask = nil
        guard !discardLoaded, !loaded.isEmpty else { return }
        records = Array((loaded + records).suffix(Self.capacity))
    }

    /// Resolves once the persisted trace has been read (tests, export).
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    // MARK: Mutation

    func append(_ record: ScrollTrace.Record) {
        guard isEnabled else { return }
        records.append(record)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
        schedulePersist()
    }

    /// Mutates a record still in the ring (newest first — the one being
    /// updated is almost always the last).
    func update(_ id: UUID, _ body: (inout ScrollTrace.Record) -> Void) {
        guard let index = records.lastIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        schedulePersist()
    }

    func clear() {
        discardLoaded = true
        records = []
        persistTask?.cancel()
        persistTask = nil
        Task { await self.writeNow() }
    }

    // MARK: Persistence

    private func schedulePersist() {
        guard fileURL != nil, persistTask == nil else { return }
        let delay = persistDelay
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.persistTask = nil
            await self.writeNow()
        }
    }

    /// Writes immediately (app backgrounding, tests).
    func flush() async {
        persistTask?.cancel()
        persistTask = nil
        await writeNow()
    }

    private func writeNow() async {
        guard let fileURL else { return }
        // Never write before the old file is read: the write would replace it
        // with only what this launch recorded.
        await waitUntilLoaded()
        generation += 1
        await writer.write(records, generation: generation, to: fileURL)
    }

    // MARK: Export

    /// The export as pretty JSON. The snapshot is taken here; encoding a full
    /// ring (several MB) runs off the main actor.
    func exportData(now: Date = Date()) async throws -> Data {
        await waitUntilLoaded()
        let envelope = exportEnvelope(now: now)
        return try await Task.detached(priority: .userInitiated) {
            try ScrollTrace.makeEncoder(pretty: true).encode(envelope)
        }.value
    }

    private func exportEnvelope(now: Date) -> ScrollTraceExportEnvelope {
        let info = Bundle.main.infoDictionary
        let device = UIDevice.current
        return ScrollTraceExportEnvelope(
            schema: ScrollTrace.schemaVersion,
            app: AppVersion.current,
            build: info?["CFBundleVersion"] as? String,
            marketingVersion: info?["CFBundleShortVersionString"] as? String,
            device: .init(
                model: device.model,
                machine: Self.machineIdentifier(),
                systemName: device.systemName,
                systemVersion: device.systemVersion
            ),
            traceEnabled: isEnabled,
            exportedAt: now,
            timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT(for: now),
            recordCount: records.count,
            records: records
        )
    }

    static func exportFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "aplus-scroll-trace-\(formatter.string(from: now)).json"
    }

    /// Writes the export to the temporary directory for the share sheet.
    func exportFileURL(now: Date = Date()) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportFileName(now: now))
        let data = try await exportData(now: now)
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url, options: .atomic)
        }.value
        return url
    }

    /// e.g. "iPhone17,1" — UIDevice.model only says "iPhone".
    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// The shared-file envelope: device and build context around the records.
struct ScrollTraceExportEnvelope: Encodable, Sendable {
    struct Device: Encodable, Sendable {
        var model: String
        var machine: String
        var systemName: String
        var systemVersion: String
    }
    var schema: Int
    var app: String
    var build: String?
    var marketingVersion: String?
    var device: Device
    var traceEnabled: Bool
    var exportedAt: Date
    var timeZoneOffsetSeconds: Int
    var recordCount: Int
    var records: [ScrollTrace.Record]
}

/// Serializes trace reads and writes off the main actor; a write older than
/// the last one written is dropped, so the file never goes backwards.
private actor ScrollTraceFileWriter {
    private var lastGeneration = 0
    private static let log = Logger(subsystem: "com.aaroncx.aplusterminal", category: "scrolltrace")

    private struct PersistedFile: Decodable {
        var schema: Int
        var records: [ScrollTrace.Record]
    }

    /// Reads a previously persisted trace; anything unreadable starts empty.
    func load(from url: URL, capacity: Int) -> [ScrollTrace.Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let file = try ScrollTrace.makeDecoder().decode(PersistedFile.self, from: data)
            return Array(file.records.suffix(capacity))
        } catch {
            Self.log.error("scroll trace unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func write(_ records: [ScrollTrace.Record], generation: Int, to url: URL) {
        guard generation > lastGeneration else { return }
        lastGeneration = generation
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // "Stored only on your iPhone" (privacy policy): keep it out of
            // iCloud and Finder backups too.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            struct File: Encodable {
                var schema: Int
                var records: [ScrollTrace.Record]
            }
            let data = try ScrollTrace.makeEncoder(pretty: false)
                .encode(File(schema: ScrollTrace.schemaVersion, records: records))
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("scroll trace write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// App-wide keyboard visibility, observed once. Owns its tokens so they are
/// removed with it.
private final class KeyboardObservers {
    private var tokens: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange(true) }
        })
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange(false) }
        })
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - Gesture tracer

/// Turns ScrollBridge's gesture lifecycle into records: opened at the routing
/// decision, emissions (momentum included) appended, closed when momentum
/// ends or the pan cancels. Records are appended to the store as soon as they
/// open, so a swipe that never finishes is still on disk.
@MainActor
final class ScrollGestureTracer {
    private let store: ScrollTraceStore
    private let context: () -> ScrollTraceContext?
    private let now: () -> Date
    private(set) var openRecordID: UUID?
    /// How long after a gesture's last send inbound output still counts as
    /// its response.
    static let responseWindow: TimeInterval = 2
    /// The gesture whose response is being watched for.
    private var responseWatch: (recordID: UUID, firstSendDoneAt: Date, until: Date)?

    init(
        store: ScrollTraceStore,
        context: @escaping () -> ScrollTraceContext?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.context = context
        self.now = now
    }

    var isRecording: Bool { store.isEnabled }

    /// A routing decision was made. Returns the id emissions should carry, or
    /// nil when nothing will be emitted (tracing off, or the native route —
    /// recorded and closed on the spot).
    func begin(_ decision: SwipeDecision, view: TerminalEmulatorView) -> UUID? {
        end(openRecordID)
        guard store.isEnabled else { return nil }
        let at = now()
        var record = makeRecord(
            at: at, route: ScrollTrace.Route(decision.mode), declineReason: nil,
            wheelBridgeEnabled: decision.wheelBridgeEnabled, view: view
        )
        if decision.mode == .native {
            record.endedAt = at
            store.append(record)
            return nil
        }
        store.append(record)
        openRecordID = record.id
        return record.id
    }

    /// The pan was refused before any routing decision.
    func decline(_ reason: ScrollTrace.DeclineReason, wheelBridgeEnabled: Bool, view: TerminalEmulatorView?) {
        guard store.isEnabled else { return }
        let at = now()
        var record = makeRecord(
            at: at, route: .declined, declineReason: reason,
            wheelBridgeEnabled: wheelBridgeEnabled, view: view
        )
        record.endedAt = at
        store.append(record)
    }

    func emitted(recordID: UUID, ticks: Int, up: Bool, momentum: Bool, col: Int?, row: Int?, bytes: Data) {
        let at = now()
        store.update(recordID) { record in
            record.totalBytes += bytes.count
            if record.emissions.count < ScrollTraceStore.maxEmissionsPerRecord {
                record.emissions.append(.init(
                    msFromStart: ScrollTrace.milliseconds(from: record.startedAt, to: at),
                    ticks: ticks, up: up, momentum: momentum,
                    row: row, col: col, bytesHex: ScrollTrace.hex(bytes)
                ))
            } else {
                record.emissionsDropped += 1
            }
        }
    }

    /// What the outbox's send did with one emission batch. Sends complete in
    /// emission order (one FIFO outbox), so the n-th send is the n-th emission.
    func noteSend(recordID: UUID, via: ScrollTrace.Transport, error: String?, enqueuedAt: Date? = nil) {
        let at = now()
        store.update(recordID) { record in
            let index = record.sendOK + record.sendFailed
            let doneMs = ScrollTrace.milliseconds(from: record.startedAt, to: at)
            if index < record.emissions.count {
                record.emissions[index].sendDoneMs = doneMs
            }
            record.lastSendDoneMs = doneMs
            if let enqueuedAt {
                let latency = ScrollTrace.milliseconds(from: enqueuedAt, to: at)
                record.maxSendLatencyMs = max(record.maxSendLatencyMs ?? 0, latency)
            }
            record.sentVia = via
            if let error {
                record.sendFailed += 1
                record.lastSendError = error
            } else {
                record.sendOK += 1
            }
        }
        guard error == nil else { return }
        if let watch = responseWatch, watch.recordID == recordID {
            responseWatch?.until = at.addingTimeInterval(Self.responseWindow)
        } else {
            responseWatch = (recordID, at, at.addingTimeInterval(Self.responseWindow))
        }
    }

    /// Output reached the emulator (either pump). Counted against the gesture
    /// whose send preceded it, while inside the response window.
    func noteInbound(byteCount: Int) {
        guard let watch = responseWatch else { return }
        let at = now()
        guard at <= watch.until else {
            responseWatch = nil
            return
        }
        store.update(watch.recordID) { record in
            if record.msToFirstInboundAfterSend == nil {
                record.msToFirstInboundAfterSend = ScrollTrace.milliseconds(from: watch.firstSendDoneAt, to: at)
            }
            record.inboundBytesAfterSend = (record.inboundBytesAfterSend ?? 0) + byteCount
        }
    }

    func end(_ id: UUID?) {
        guard let id else { return }
        if openRecordID == id { openRecordID = nil }
        let at = now()
        store.update(id) { record in
            if record.endedAt == nil { record.endedAt = at }
        }
    }

    private func makeRecord(
        at: Date,
        route: ScrollTrace.Route,
        declineReason: ScrollTrace.DeclineReason?,
        wheelBridgeEnabled: Bool,
        view: TerminalEmulatorView?
    ) -> ScrollTrace.Record {
        let ctx = context()
        return ScrollTrace.Record(
            id: UUID(),
            startedAt: at,
            endedAt: nil,
            server: ctx?.server,
            session: ctx?.session,
            transport: ctx?.transport ?? .ssh,
            tabID: ctx?.tabID,
            sessionSource: ctx?.session == nil ? nil : ctx?.sessionSource,
            meshyyUnavailableReason: ctx?.meshyyUnavailableReason,
            transportState: ctx?.transportState ?? .dead,
            rawSessionState: ctx?.rawSessionState ?? "unknown",
            meshyyTransportFinished: ctx?.meshyyTransportFinished,
            msSinceLastInboundBytes: ctx?.lastInboundBytesAt.map { ScrollTrace.milliseconds(from: $0, to: at) },
            msSinceLastInboundFrame: ctx?.lastInboundFrameAt.map { ScrollTrace.milliseconds(from: $0, to: at) },
            belief: view.map { belief(of: $0, at: at) },
            wheelBridgeEnabled: wheelBridgeEnabled,
            route: route,
            declineReason: declineReason,
            lastModesFrame: ctx?.lastModesFrame.map {
                .init(active: $0.active.sorted(), ageMs: ScrollTrace.milliseconds(from: $0.at, to: at))
            },
            lastScreenModeFrame: ctx?.lastScreenModeFrame.map {
                .init(alt: $0.alt, ageMs: ScrollTrace.milliseconds(from: $0.at, to: at))
            },
            lastPtyResize: ctx?.lastPtyResize.map {
                .init(
                    cols: $0.cols, rows: $0.rows, via: $0.via, ok: $0.error == nil, error: $0.error,
                    ageMs: ScrollTrace.milliseconds(from: $0.at, to: at)
                )
            }
        )
    }

    private func belief(of view: TerminalEmulatorView, at: Date) -> ScrollTrace.Belief {
        let terminal = view.getTerminal()
        return ScrollTrace.Belief(
            mouseMode: String(describing: terminal.mouseMode),
            altScreen: terminal.isCurrentBufferAlternate,
            applicationCursor: terminal.applicationCursor,
            rows: terminal.rows,
            cols: terminal.cols,
            keyboardVisible: store.keyboardVisible,
            msSinceKeyboardChange: store.keyboardChangedAt.map { ScrollTrace.milliseconds(from: $0, to: at) },
            isFirstResponder: view.isFirstResponder,
            msSinceMouseModeChange: view.lastMouseModeChangeAt.map { ScrollTrace.milliseconds(from: $0, to: at) },
            previousMouseMode: view.previousMouseMode.map { String(describing: $0) },
            msSinceBufferSwitch: view.lastBufferSwitchAt.map { ScrollTrace.milliseconds(from: $0, to: at) },
            isScrolledBack: view.canScroll && view.scrollPosition < 1,
            scrollPosition: view.canScroll ? view.scrollPosition : nil,
            topVisibleRow: terminal.getTopVisibleRow()
        )
    }
}
#endif
