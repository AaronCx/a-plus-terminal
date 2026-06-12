import Foundation

/// Heuristic Claude Code (and similar agent) status for a session, derived
/// purely from the output stream — the app never inspects commands.
///
/// Detection: nothing is reported until an agent banner/marker appears in
/// the output ("Claude Code", "esc to interrupt"). After that:
/// - a sustained output burst (≥ `burstThreshold` bytes inside one quiet
///   window) means the agent is **working** — streaming a response,
/// - quiet for `quietInterval` means it's **waiting** for input.
/// Keystroke echoes are a handful of bytes and never reach the burst
/// threshold, so the user typing a reply doesn't read as "working".
@MainActor
final class AgentActivityMonitor {
    enum Status: String {
        case none
        case working
        case waiting
    }

    private(set) var status: Status = .none
    /// Fired on every status transition (main actor).
    var onChange: (() -> Void)?

    /// Markers that prove an interactive agent is on-screen. Lowercased.
    private static let markers = ["claude code", "esc to interrupt"]
    private static let tailWindow = 64

    private let quietInterval: TimeInterval
    private let burstThreshold: Int

    private var agentSeen = false
    private var burstBytes = 0
    private var quietTask: Task<Void, Never>?
    /// Tail of the previous chunk so markers split across reads still match.
    private var carry = ""

    init(quietInterval: TimeInterval = 3, burstThreshold: Int = 200) {
        self.quietInterval = quietInterval
        self.burstThreshold = burstThreshold
    }

    func observe(_ bytes: [UInt8]) {
        if !agentSeen {
            scanForMarker(bytes)
        }
        guard agentSeen else { return }

        burstBytes += bytes.count
        if status != .working, burstBytes >= burstThreshold {
            transition(to: .working)
        }
        scheduleQuiet()
    }

    func reset() {
        quietTask?.cancel()
        quietTask = nil
        agentSeen = false
        burstBytes = 0
        carry = ""
        if status != .none {
            transition(to: .none)
        }
    }

    private func scanForMarker(_ bytes: [UInt8]) {
        let text = carry + String(decoding: bytes, as: UTF8.self).lowercased()
        if Self.markers.contains(where: { text.contains($0) }) {
            agentSeen = true
            carry = ""
            return
        }
        carry = String(text.suffix(Self.tailWindow))
    }

    private func scheduleQuiet() {
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.quietInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.burstBytes = 0
            if self.status == .working {
                self.transition(to: .waiting)
            }
        }
    }

    private func transition(to newStatus: Status) {
        status = newStatus
        onChange?()
    }
}
