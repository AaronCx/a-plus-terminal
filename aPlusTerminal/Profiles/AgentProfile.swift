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
        case id, displayName, detectionMarkers, attachTemplate, quietInterval, burstThreshold, builtIn
    }

    /// Lenient decoder: hand-authored / community profile JSON may omit
    /// `builtIn`, `detectionMarkers`, or `attachTemplate`. Synthesized Decodable
    /// ignores property defaults, so decode them explicitly with fallbacks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        detectionMarkers = try c.decodeIfPresent([String].self, forKey: .detectionMarkers) ?? []
        attachTemplate = try c.decodeIfPresent(String.self, forKey: .attachTemplate) ?? "{path} "
        quietInterval = try c.decodeIfPresent(Double.self, forKey: .quietInterval)
        burstThreshold = try c.decodeIfPresent(Int.self, forKey: .burstThreshold)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
    }
}
