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
    /// Fired whenever the quiet timer finds the session sitting at a bare
    /// shell prompt — whatever was running there has exited. The session
    /// uses it to drop latches the monitor does not own (OSC 7501).
    var onIdleShellPrompt: (() -> Void)?

    /// Positive evidence that the named agent is running right now, not
    /// just that one was configured or once mentioned. A marker latch counts
    /// (an idle shell prompt un-latches it). An explicit pick is named from
    /// the start, so for it the evidence is the heuristic being active: a
    /// pick on a server sitting at a bare shell prompt reads `.none`, and a
    /// shell's bell there is not the agent's.
    var hasRunningAgentEvidence: Bool {
        guard let detected else { return false }
        if let explicitAgent, detected.id == explicitAgent.id {
            return status != .none
        }
        return true
    }

    private static let tailWindowBytes = 128
    /// Raw tail of recent output kept for idle-prompt detection — wider than
    /// the marker window because a prompt trails escape-heavy redraws.
    private static let promptTailBytes = 256
    /// Characters that, as the last non-whitespace of the ANSI-stripped tail,
    /// read as a bare shell prompt. Deliberately conservative — agent TUIs
    /// never end an idle frame with a bare POSIX terminator. Extend here for
    /// fancy prompts (e.g. "❯") if a real one proves safe.
    static let promptTerminators: Set<Character> = ["%", "$", "#"]
    /// Cap on the spaces one cursor-forward expands to — a marker never spans
    /// a jump wider than a line.
    private static let maxCursorForward = 512

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
    /// Raw byte tail of the previous chunk so a marker — or a multibyte UTF-8
    /// sequence — split across reads is reassembled before decoding.
    private var carryBytes: [UInt8] = []
    /// Raw tail of recent output, checked for an idle shell prompt when the
    /// quiet timer fires.
    private var promptTail: [UInt8] = []

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
        promptTail = Array((promptTail + bytes).suffix(Self.promptTailBytes))
        // Keep scanning until a named profile latches, even after the generic
        // heuristic has gone active — so "Agent" upgrades to the real name.
        if detected == nil, !markerCandidates.isEmpty {
            scanForMarker(bytes)
        }
        if agentSeen {
            burstBytes += bytes.count
            if status != .working, burstBytes >= activeBurst {
                transition(to: .working)
            }
        }
        // Scheduled even with detection off or status `.none`: the
        // idle-prompt check also un-latches a marker that matched a typed
        // command's echo (`cd codex-repo`, `man aider`), which is too short
        // to ever leave `.none`, and tells the session a program exited.
        scheduleQuiet()
    }

    func reset() {
        quietTask?.cancel()
        quietTask = nil
        agentSeen = alwaysActive
        detected = explicitAgent
        burstBytes = 0
        carryBytes = []
        promptTail = []
        if status != .none {
            transition(to: .none)
        }
    }

    private func scanForMarker(_ bytes: [UInt8]) {
        // Markers are matched against what the user SEES, not the raw bytes:
        // tmux redraws only the cells that changed, so "Claude Code" arrives
        // as `Claude C`, an attribute reset, `ode` — or with a cursor-forward
        // where a space already sat. Raw matching left Claude Code inside
        // tmux unnamed for its whole life.
        let text = Self.stripANSI(String(decoding: carryBytes + bytes, as: UTF8.self)).lowercased()
        // Prefer the most specific (longest) matching marker. When one chunk
        // carries markers for two agents, this names the one whose marker
        // matched most specifically rather than whichever profile happens to
        // be first in file order.
        var best: (candidate: AgentProfile, length: Int)?
        for candidate in markerCandidates {
            for marker in candidate.detectionMarkers where text.contains(marker) {
                if best == nil || marker.count > best!.length {
                    best = (candidate, marker.count)
                }
            }
        }
        if let best {
            detected = best.candidate
            agentSeen = true
            carryBytes = []
            return
        }
        carryBytes = Array((carryBytes + bytes).suffix(Self.tailWindowBytes))
    }

    private func scheduleQuiet() {
        quietTask?.cancel()
        let quiet = activeQuiet
        quietTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(quiet * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.burstBytes = 0
            if self.tailShowsIdleShellPrompt() {
                // The "burst" was a login banner / MOTD / multiplexer redraw,
                // a typed command's echo, or the agent has exited: the
                // session sits at a bare shell prompt, so nothing is waiting
                // for input. Clear status and un-latch a name the marker
                // scan may have picked up from banner or echo text (an
                // explicit user pick keeps its name).
                let unlatched = self.detected?.id != self.explicitAgent?.id
                self.detected = self.explicitAgent
                self.onIdleShellPrompt?()
                if self.status != .none {
                    self.transition(to: .none)
                } else if unlatched {
                    self.onChange?()
                }
            } else if self.status == .working {
                // Quiet is not waiting while the agent SAYS it is busy: a
                // silent tool call keeps the profile's busy marker near the
                // end of the stream (the spinner re-prints it). Same gate as
                // meshyy's daemon-side monitor; bounded to the recent tail
                // because bytes outlive the redraws that erased them.
                if !self.tailShowsBusyMarker() {
                    self.transition(to: .waiting)
                }
            }
        }
    }

    private func tailShowsIdleShellPrompt() -> Bool {
        Self.endsAtShellPrompt(String(decoding: promptTail, as: UTF8.self))
    }

    private func tailShowsBusyMarker() -> Bool {
        guard let markers = detected?.busyMarkers, !markers.isEmpty else { return false }
        let stripped = Self.stripANSI(String(decoding: promptTail, as: UTF8.self)).lowercased()
        let window = String(stripped.suffix(512))
        return markers.contains { window.contains($0.lowercased()) }
    }

    /// True when the ANSI-stripped tail ends at a bare shell prompt (`%`,
    /// `$`, `#`, optionally trailed by whitespace or cursor noise). Agent
    /// TUIs end idle frames with box borders or hint text, never a bare
    /// POSIX prompt terminator.
    static func endsAtShellPrompt(_ tail: String) -> Bool {
        let stripped = stripANSI(tail)
        guard let last = stripped.reversed().first(where: { !$0.isWhitespace }) else {
            return false
        }
        return promptTerminators.contains(last)
    }

    /// Removes CSI (`ESC [ … final`), OSC (`ESC ] … BEL` / `ESC \`),
    /// character-set designations (`ESC ( B`) and two-character escapes so
    /// prompt and marker detection see what the user sees. A cursor-forward
    /// (`ESC [ n C`) becomes `n` spaces: a redraw skips a cell that already
    /// holds a space instead of rewriting it.
    static func stripANSI(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            guard scalar.value == 0x1B else {
                result.append(scalar)
                continue
            }
            guard let introducer = scalars.first else { break }
            scalars = scalars.dropFirst()
            switch introducer {
            case "[":
                // CSI: skip parameter/intermediate bytes up to a final byte.
                var parameters = ""
                while let byte = scalars.first {
                    scalars = scalars.dropFirst()
                    if (0x40...0x7E).contains(byte.value) {
                        if byte == "C" {
                            let count = min(Int(parameters) ?? 1, Self.maxCursorForward)
                            result.append(contentsOf: String(repeating: " ", count: max(count, 1)).unicodeScalars)
                        }
                        break
                    }
                    parameters.unicodeScalars.append(byte)
                }
            case "(", ")", "*", "+":
                // Character-set designation: one more byte names the set.
                scalars = scalars.dropFirst()
            case "]":
                // OSC: terminated by BEL or ESC-backslash (ST).
                var previous: UnicodeScalar?
                while let byte = scalars.first {
                    scalars = scalars.dropFirst()
                    if byte.value == 0x07 { break }
                    if previous?.value == 0x1B, byte == "\\" { break }
                    previous = byte
                }
            default:
                break // two-character escape: introducer already consumed
            }
        }
        return String(result)
    }

    private func transition(to newStatus: Status) {
        agentAlertLog.notice("monitor \(self.status.rawValue, privacy: .public)->\(newStatus.rawValue, privacy: .public) burst=\(self.burstBytes, privacy: .public) agent=\(self.detected?.id ?? "nil", privacy: .public)")
        status = newStatus
        onChange?()
    }
}
