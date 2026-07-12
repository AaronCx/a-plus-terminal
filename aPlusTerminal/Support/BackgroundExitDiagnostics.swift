import Foundation
import Observation
import os

/// Device-truth diagnostics for background process death — a tiny state
/// machine persisted synchronously to UserDefaults on every transition, so
/// the record survives *any* kind of process death (watchdog kill, jetsam,
/// crash, force-quit). Nothing ever leaves the phone.
///
/// Why this exists: the simulator does not enforce background watchdogs, so a
/// device-only kill around background-allowance expiry (0x8badf00d) can never
/// be reproduced in-sim. The only way to see what happened is to write down
/// which lifecycle phase the process was in, and read it back at next launch:
///
/// - `foreground`          → running normally; a kill here is a crash/relaunch,
///                           not the background watchdog.
/// - `backgrounded`        → sockets deliberately held open, wind-down not yet
///                           started. Death here = killed while parked.
/// - `windDownStarted`     → suspend + ActivityKit flush in flight. Death here
///                           = killed mid-teardown (the classic watchdog spot).
/// - `windDownCompleted`   → everything flushed, background task ended, process
///                           suspendable. Any later death is a *normal* iOS
///                           suspended-app termination, not a watchdog.
///
/// At launch the previous record is classified: `backgrounded` or
/// `windDownStarted` without a completion means the process very likely died
/// in the background (watchdog suspect) and a loud os_log fault names the
/// phase. The same plain-text summary is surfaced as a row in Settings so it
/// can be read on a TestFlight build without connecting to Xcode.
@MainActor
@Observable
final class BackgroundExitDiagnostics {
    enum Phase: String, Codable {
        case foreground
        case backgrounded
        case windDownStarted
        case windDownCompleted
    }

    enum WindDownTrigger: String, Codable {
        /// backgroundTimeRemaining dropped under the safety margin — the
        /// healthy path.
        case proactive
        /// The beginBackgroundTask expiration handler fired first — the last
        /// resort; means the proactive poll never saw the margin coming.
        case expiration
    }

    struct Record: Codable, Equatable {
        var phase: Phase
        var backgroundedAt: Date?
        var windDownStartedAt: Date?
        var windDownTrigger: WindDownTrigger?
        var windDownCompletedAt: Date?
        var updatedAt: Date
    }

    enum PreviousExit: Equatable {
        case none
        case clean(Record)
        case suspectBackgroundKill(Record)
    }

    /// How the PREVIOUS process run ended — classified once, at launch, from
    /// the record the previous process left behind.
    let previousExit: PreviousExit
    /// Plain-text one-liner of `previousExit` for the Settings row and os_log.
    let previousExitSummary: String

    /// The current run's record. Every mutation persists synchronously.
    private(set) var record: Record {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private static let recordKey = "backgroundExitDiagnostics.record"
    private static let log = Logger(subsystem: "com.aaroncx.aplusterminal", category: "lifecycle")

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let exit = Self.classify(Self.loadRecord(from: defaults))
        previousExit = exit
        previousExitSummary = Self.summary(for: exit)
        record = Record(phase: .foreground, updatedAt: now())
        persist()
        switch exit {
        case .suspectBackgroundKill:
            Self.log.fault("previous process likely killed in background (watchdog suspect): \(self.previousExitSummary, privacy: .public)")
        case .clean, .none:
            Self.log.info("previous exit: \(self.previousExitSummary, privacy: .public)")
        }
    }

    // MARK: - Transitions (each guards against out-of-order/racing callers)

    /// Entering the dangerous window: backgrounded with sockets held open.
    /// Starts a fresh cycle regardless of prior phase.
    func markBackgrounded() {
        let at = now()
        record = Record(phase: .backgrounded, backgroundedAt: at, updatedAt: at)
    }

    /// Wind-down (suspend + flush) began. Valid only from `.backgrounded` —
    /// the proactive path and the expiration handler can race, so the first
    /// caller wins and later calls are no-ops (the recorded trigger stays the
    /// one that actually started the teardown).
    func markWindDownStarted(trigger: WindDownTrigger) {
        guard record.phase == .backgrounded else { return }
        var r = record
        let at = now()
        r.phase = .windDownStarted
        r.windDownStartedAt = at
        r.windDownTrigger = trigger
        r.updatedAt = at
        record = r
    }

    /// Wind-down finished: sessions suspended, ActivityKit flushed, background
    /// task ended. From here on, process death is a normal suspended-app
    /// termination. Valid only from `.windDownStarted`.
    func markWindDownCompleted() {
        guard record.phase == .windDownStarted else { return }
        var r = record
        let at = now()
        r.phase = .windDownCompleted
        r.windDownCompletedAt = at
        r.updatedAt = at
        record = r
    }

    /// Back to the foreground — the background cycle (if any) is over.
    func markForegrounded() {
        record = Record(phase: .foreground, updatedAt: now())
    }

    // MARK: - Launch-time classification (pure, unit-testable)

    static func classify(_ record: Record?) -> PreviousExit {
        guard let record else { return .none }
        switch record.phase {
        case .foreground, .windDownCompleted:
            return .clean(record)
        case .backgrounded, .windDownStarted:
            return .suspectBackgroundKill(record)
        }
    }

    static func summary(for exit: PreviousExit) -> String {
        switch exit {
        case .none:
            return "No previous run recorded."
        case .clean(let r):
            if r.phase == .windDownCompleted {
                let how = r.windDownTrigger == .expiration
                    ? "via the expiration handler (last resort)"
                    : "proactively"
                return "Clean: background wind-down completed \(how)\(elapsed(from: r.backgroundedAt, to: r.windDownCompletedAt)); any later exit was a normal suspended-app termination."
            }
            return "Clean: exited while foreground/active — no background wind-down was pending."
        case .suspectBackgroundKill(let r):
            let phase: String
            switch r.phase {
            case .backgrounded:
                phase = "backgrounded — sockets held, wind-down not started"
            case .windDownStarted:
                let trigger = r.windDownTrigger.map { " (\($0.rawValue))" } ?? ""
                phase = "wind-down started\(trigger) — suspend/flush incomplete"
            default:
                phase = r.phase.rawValue
            }
            return "SUSPECT: previous process likely killed in background (watchdog 0x8badf00d?) — died in phase '\(phase)'\(elapsed(from: r.backgroundedAt, to: r.updatedAt)). Last record at \(timestamp(r.updatedAt))."
        }
    }

    /// " Ns after backgrounding" — or nothing if either bound is missing.
    private static func elapsed(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "" }
        return " \(Int(end.timeIntervalSince(start).rounded()))s after backgrounding"
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.recordKey)
    }

    private static func loadRecord(from defaults: UserDefaults) -> Record? {
        guard let data = defaults.data(forKey: recordKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}
