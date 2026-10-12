import Foundation
import os

/// One line per event that can lead to (or explain the absence of) an agent
/// notification: heuristic transitions, every status the funnel notes, every
/// alert decision, pty resizes, scene-phase changes, focus reports and bells.
/// Timestamps come from the unified log itself. Never logs terminal content —
/// only statuses, sizes, counts and session-id prefixes.
///
/// Read it live from the host:
///   xcrun simctl spawn <udid> log stream --level debug --style ndjson \
///     --predicate 'subsystem == "com.aaroncx.aplusterminal" AND category == "agent-alerts"'
let agentAlertLog = Logger(subsystem: "com.aaroncx.aplusterminal", category: "agent-alerts")

extension UUID {
    /// Short, stable tag for log lines — enough to tell sessions apart.
    var logTag: String { String(uuidString.prefix(8)) }
}

#if DEBUG
/// DEBUG-only counters for the live notification tests, which cannot see
/// UNUserNotificationCenter from the test runner. Enabled by the launch
/// environment `APLUSTERMINAL_TEST_ALERT_PROBE=1`; every change rewrites the
/// one-line summary into the file named by `APLUSTERMINAL_TEST_ALERT_PROBE_FILE`,
/// which the runner reads after `app.activate()` (a simulator app and its
/// runner share the host filesystem). A hidden accessibility element was
/// tried first and kept dropping out of the tree while the terminal screen
/// was up. Compiled out of release builds entirely.
@MainActor
final class AgentAlertProbe {
    static let shared = AgentAlertProbe()

    let isEnabled = ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_ALERT_PROBE"] == "1"
    private let fileURL = ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_ALERT_PROBE_FILE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    /// Notifications actually handed to UNUserNotificationCenter by the
    /// agent-alert path.
    private(set) var posts = 0
    /// Alert requests that reached the policy (posted or not).
    private(set) var wouldPost = 0
    /// The most recently detected agent profile id, so a test can wait for
    /// detection without reading terminal text.
    private(set) var agent = "none"
    /// Real pty size changes, so a test can prove each trip actually made the
    /// agent repaint — a trip that resized nothing tested nothing.
    private(set) var resizes = 0

    /// `APLUSTERMINAL_TEST_HIDE_KEYBOARD_ON_LEAVE=1`: the session screen
    /// hides the keyboard as the app goes inactive and raises it on return,
    /// as leaving does on a device (see TerminalScreen).
    var hidesKeyboardOnLeave: Bool {
        isEnabled && ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_HIDE_KEYBOARD_ON_LEAVE"] == "1"
    }

    /// `APLUSTERMINAL_TEST_ALERT_FLOOR` (seconds) overrides the per-session
    /// floor so repeated posts in a test are not masked by it.
    static var floorOverride: TimeInterval? {
        ProcessInfo.processInfo.environment["APLUSTERMINAL_TEST_ALERT_FLOOR"].flatMap(TimeInterval.init)
    }

    var summary: String { "posts=\(posts) wouldPost=\(wouldPost) agent=\(agent) resizes=\(resizes)" }

    /// Writes the starting summary, so the runner can tell "zero" from
    /// "probe never ran".
    func start() {
        guard isEnabled else { return }
        agentAlertLog.notice("probe enabled file=\(self.fileURL?.path ?? "nil", privacy: .public)")
        write()
    }

    func notePost() {
        posts += 1
        write()
    }
    func noteWouldPost() {
        wouldPost += 1
        write()
    }
    func noteResize() {
        resizes += 1
        write()
    }
    func noteAgent(_ id: String?) {
        guard let id, id != agent else { return }
        agent = id
        write()
    }

    private func write() {
        guard isEnabled, let fileURL else { return }
        do {
            try Data((summary + "\n").utf8).write(to: fileURL, options: .atomic)
        } catch {
            agentAlertLog.error("probe write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
