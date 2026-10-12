import Foundation

/// A CLI AI agent described purely as data, so adding one (Claude Code, Codex,
/// aider, Gemini CLI, Hermes, …) is config — a `profiles.json` entry — not a
/// recompile. The app core never names an agent; it only consults these.
struct AgentProfile: Codable, Identifiable, Hashable {
    /// Stable id, e.g. "claude-code".
    var id: String
    /// Human-facing name, e.g. "Claude Code".
    var displayName: String
    /// Lowercased substrings; ANY match in the output stream marks the agent
    /// as detected (drives the Live Activity label). Empty = heuristic only.
    var detectionMarkers: [String]
    /// File-attach insertion template; "{path}" is replaced with the remote
    /// path. Defaults to a bare path + trailing space (agent-agnostic).
    var attachTemplate: String
    /// Optional per-agent override of the "quiet => waiting" window (seconds).
    var quietInterval: Double?
    /// Optional per-agent override of the working-burst byte threshold.
    var burstThreshold: Int?
    /// Substrings that mean the agent is STILL WORKING however quiet the pty —
    /// Claude Code shows "esc to interrupt" for the whole life of a tool call,
    /// re-printed by its spinner. Quiet alone read a silent build as "waiting
    /// for input" and notified a human nobody needed. Empty = quiet decides.
    var busyMarkers: [String] = []
    /// Built-in (bundled) vs. user-defined. User entries override built-ins
    /// with the same id.
    var builtIn: Bool = true

    /// Renders `attachTemplate` for a concrete remote path.
    func formatAttachment(path: String) -> String {
        attachTemplate.replacingOccurrences(of: "{path}", with: path)
    }
}

extension AgentProfile {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, detectionMarkers, attachTemplate, quietInterval, burstThreshold, busyMarkers, builtIn
    }

    /// Lenient decoder: hand-authored / community profile JSON may omit
    /// `builtIn`, `detectionMarkers`, or `attachTemplate`. Synthesized Decodable
    /// ignores property defaults, so decode them explicitly with fallbacks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        detectionMarkers = try c.decodeIfPresent([String].self, forKey: .detectionMarkers) ?? []
        attachTemplate = try c.decodeIfPresent(String.self, forKey: .attachTemplate) ?? Self.defaultAttachTemplate
        quietInterval = try c.decodeIfPresent(Double.self, forKey: .quietInterval)
        burstThreshold = try c.decodeIfPresent(Int.self, forKey: .burstThreshold)
        busyMarkers = try c.decodeIfPresent([String].self, forKey: .busyMarkers) ?? []
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
    }
}

// MARK: - Validation and normalization (custom agents)

extension AgentProfile {
    /// Monitor defaults (`AgentActivityMonitor.init`), shown in the editor and
    /// used to decide when a per-agent override is really an override.
    static let defaultQuietInterval: Double = 2
    static let defaultBurstThreshold: Int = 200
    /// Bounds the editor offers and import clamps to. A zero or negative
    /// quiet window would spin the monitor's timer; NaN would trap it.
    static let quietIntervalRange: ClosedRange<Double> = 0.5...30
    static let burstThresholdRange: ClosedRange<Int> = 50...5000
    /// Prefix of every id the app generates for a user-made agent, so one can
    /// never collide with a bundled asset name (`agent-<id>`).
    static let customIDPrefix = "custom-"

    /// What the attach action types when a profile doesn't say otherwise.
    static let defaultAttachTemplate = "{path} "
    /// Longest attach text a custom agent may carry.
    static let attachTemplateMaxLength = 200

    /// `^[a-z0-9-]{1,64}$`. The id keys the icon FILE NAME in the App Group
    /// (`AgentIcons/<id>.png`) and `Server.agentProfileID`, so anything
    /// path-like ("../x", "a/b") must never get in through an import.
    static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D
        }
    }

    /// A valid id that also carries `customIDPrefix`. Required of every
    /// custom agent, imported ones included: without the prefix an imported
    /// "cursor" would turn into an override the day a release bundles a
    /// built-in with that id, and "auto"/"none" would collide with the
    /// agent pickers' mode tags (`SessionManager.resolveAgentCandidates`).
    static func isValidCustomID(_ id: String) -> Bool {
        isValidID(id) && id.hasPrefix(customIDPrefix) && id.count > customIDPrefix.count
    }

    /// A custom agent's attach text is TYPED into the terminal after an
    /// upload, so it must not be able to run anything by itself: it has to
    /// contain `{path}`, stay short, and carry no control characters at all
    /// (no newline or carriage return to press Return, no ESC sequences, no
    /// ^C). The user reads it on the prompt and presses Return themselves.
    /// Built-in templates aren't held to this; they ship with the app (aider's
    /// `/add {path}\n` submits on purpose).
    static func isSafeCustomAttachTemplate(_ template: String) -> Bool {
        guard template.contains("{path}"), template.count <= attachTemplateMaxLength else { return false }
        return template.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }

    /// A fresh id for a user-made agent: "custom-<slug>-<6 random>", generated
    /// once and never edited (it keys the icon file and server references).
    static func makeCustomID(displayName: String, avoiding taken: Set<String> = []) -> String {
        var slug = ""
        for scalar in displayName.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
            let id = customIDPrefix + (slug.isEmpty ? "" : slug + "-") + suffix
            if !taken.contains(id) { return id }
        }
    }

    /// Trim, lowercase, drop empties, dedupe (first occurrence wins). The
    /// monitor compares markers against LOWERCASED output, so a marker stored
    /// with a capital letter could never match.
    static func normalizedMarkers(_ markers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in markers {
            let marker = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !marker.isEmpty, seen.insert(marker).inserted else { continue }
            result.append(marker)
        }
        return result
    }

    /// This profile with markers normalized, the name trimmed, and timing
    /// overrides clamped to sane bounds (nil when equal to the default, or
    /// not a finite number). Safe for any source: the editor, an import, or
    /// a hand-edited user file.
    func normalized() -> AgentProfile {
        var copy = self
        copy.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.detectionMarkers = Self.normalizedMarkers(detectionMarkers)
        copy.busyMarkers = Self.normalizedMarkers(busyMarkers)
        if let quiet = quietInterval, quiet.isFinite {
            let clamped = min(max(quiet, Self.quietIntervalRange.lowerBound), Self.quietIntervalRange.upperBound)
            copy.quietInterval = clamped == Self.defaultQuietInterval ? nil : clamped
        } else {
            copy.quietInterval = nil
        }
        if let burst = burstThreshold {
            let clamped = min(max(burst, Self.burstThresholdRange.lowerBound), Self.burstThresholdRange.upperBound)
            copy.burstThreshold = clamped == Self.defaultBurstThreshold ? nil : clamped
        }
        return copy
    }
}
