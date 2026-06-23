import Foundation

/// A terminal multiplexer described purely as data (tmux, zellij, screen,
/// dtach, or none). The reconnect/attach machinery runs these commands without
/// ever hardcoding a multiplexer. `nil` commands mean "not supported" — e.g.
/// the `none` profile (raw shell) leaves them all nil.
struct MultiplexerProfile: Codable, Identifiable, Hashable {
    /// Stable id, e.g. "tmux".
    var id: String
    /// Human-facing name, e.g. "tmux".
    var displayName: String
    /// Lists sessions, one target per line (used only informationally today).
    var listSessionsCommand: String?
    /// Attach template; "{target}" is replaced with the recorded session.
    var attachTemplate: String?
    /// Prints the currently-attached session name (for reattach targeting).
    var currentTargetCommand: String?
    /// One-time "enable mouse" hint command; nil = this multiplexer shows no hint.
    var mouseHintCommand: String?
    /// Built-in vs. user-defined.
    var builtIn: Bool = true

    /// Renders `attachTemplate` for a concrete target; nil if unsupported.
    /// The target is shell-quoted because it comes from the multiplexer's own
    /// `list-sessions` output and is typed into an interactive shell — a name
    /// with spaces or metacharacters must stay one literal argument.
    func attachCommand(target: String) -> String? {
        guard let attachTemplate else { return nil }
        return attachTemplate.replacingOccurrences(of: "{target}", with: Self.shellQuote(target))
    }

    /// POSIX single-quoting: wrap in single quotes, escaping any embedded ones.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension MultiplexerProfile {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, listSessionsCommand, attachTemplate, currentTargetCommand, mouseHintCommand, builtIn
    }

    /// Lenient decoder so hand-authored / community profile JSON may omit
    /// `builtIn` (synthesized Decodable ignores property defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        listSessionsCommand = try c.decodeIfPresent(String.self, forKey: .listSessionsCommand)
        attachTemplate = try c.decodeIfPresent(String.self, forKey: .attachTemplate)
        currentTargetCommand = try c.decodeIfPresent(String.self, forKey: .currentTargetCommand)
        mouseHintCommand = try c.decodeIfPresent(String.self, forKey: .mouseHintCommand)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
    }
}
