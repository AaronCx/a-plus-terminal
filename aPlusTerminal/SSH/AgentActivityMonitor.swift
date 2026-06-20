import Foundation

/// Heuristic agent status for a session, derived purely from the output
/// stream — the app never inspects commands. Agent identity is **data**: the
/// monitor is handed candidate `AgentProfile`s and never names one itself.
///
/// Detection:
/// - If a `generic` profile (empty markers) is among the candidates — the
///   default "auto" mode — the burst/quiet heuristic runs from the start and
///   reports working/waiting for *any* agent, with no detected name ("Agent").
/// - As soon as a candidate's marker substring appears in the output, that
///   profile latches as `detected` and its display name drives the label.
/// - Empty candidates (multiplexer/agent "none") => detection disabled.
///
/// Heuristic: a sustained output burst (≥ threshold bytes inside one quiet
/// window) means **working**; quiet for the quiet interval means **waiting**.
/// Keystroke echoes are a handful of bytes and never reach the threshold.
@MainActor
final class AgentActivityMonitor {
    enum Status: String {
        case none
        case working
        case waiting
    }

    private(set) var status: Status = .none
    /// The profile whose marker last matched; nil under the generic heuristic.
    /// Drives the Live Activity label.
    private(set) var detected: AgentProfile?
    /// Fired on every status transition (main actor).
    var onChange: (() -> Void)?

    private static let tailWindow = 64

    private let candidates: [AgentProfile]
    /// Candidates that carry markers — scanned to upgrade `detected`.
    private let markerCandidates: [AgentProfile]
    /// The burst/quiet heuristic runs whenever ANY agent is configured — not
    /// just the generic-auto case. Selecting a specific agent must still report
    /// working/waiting, and status must NOT depend on a marker appearing in the
    /// output: inside a multiplexer (tmux/zellij), redraws splice cursor/escape
    /// codes through the text, so a marker like "esc to interrupt" rarely lands
    /// as a contiguous substring — which previously left a specific-agent session
    /// with no status for minutes, or ever.
    private let alwaysActive: Bool
    /// A single explicitly-chosen agent (no generic fallback): its name is known
    /// up front, so the label is correct immediately without waiting for a marker.
    private let explicitAgent: AgentProfile?

    private let defaultQuiet: TimeInterval
    private let defaultBurst: Int

    private var agentSeen: Bool
    private var burstBytes = 0
    private var quietTask: Task<Void, Never>?
    /// Tail of the previous chunk so markers split across reads still match.
    private var carry = ""

    init(candidates: [AgentProfile], quietInterval: TimeInterval = 2, burstThreshold: Int = 200) {
        self.candidates = candidates
        let markers = candidates.filter { !$0.detectionMarkers.isEmpty }
        let hasGeneric = candidates.contains { $0.detectionMarkers.isEmpty }
        self.markerCandidates = markers
        self.alwaysActive = !candidates.isEmpty
        // Exactly one real agent and no generic fallback ⇒ an explicit pick.
        let explicit = (!hasGeneric && markers.count == 1 && candidates.count == 1) ? markers[0] : nil
        self.explicitAgent = explicit
        self.defaultQuiet = quietInterval
        self.defaultBurst = burstThreshold
        self.agentSeen = !candidates.isEmpty
        self.detected = explicit
    }

    private var activeQuiet: TimeInterval { detected?.quietInterval ?? defaultQuiet }
    private var activeBurst: Int { detected?.burstThreshold ?? defaultBurst }

    func observe(_ bytes: [UInt8]) {
        // Keep scanning until a named profile latches, even after the generic
        // heuristic has gone active — so "Agent" upgrades to the real name.
        if detected == nil, !markerCandidates.isEmpty {
            scanForMarker(bytes)
        }
        guard agentSeen else { return }

        burstBytes += bytes.count
        if status != .working, burstBytes >= activeBurst {
            transition(to: .working)
        }
        scheduleQuiet()
    }

    func reset() {
        quietTask?.cancel()
        quietTask = nil
        agentSeen = alwaysActive
        detected = explicitAgent
        burstBytes = 0
        carry = ""
        if status != .none {
            transition(to: .none)
        }
    }

    private func scanForMarker(_ bytes: [UInt8]) {
        let text = carry + String(decoding: bytes, as: UTF8.self).lowercased()
        for candidate in markerCandidates {
            if candidate.detectionMarkers.contains(where: { text.contains($0) }) {
                detected = candidate
                agentSeen = true
                carry = ""
                return
            }
        }
        carry = String(text.suffix(Self.tailWindow))
    }

    private func scheduleQuiet() {
        quietTask?.cancel()
        let quiet = activeQuiet
        quietTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(quiet * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
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
