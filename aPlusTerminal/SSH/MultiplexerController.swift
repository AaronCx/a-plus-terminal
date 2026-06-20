import Foundation

/// Drives the multiplexer side of the reconnect contract (§4.1) from a
/// `MultiplexerProfile` — no multiplexer is named in code. Discovers the
/// currently-attached target before a drop and rebuilds the attach command
/// after reconnecting. The multiplexer itself survives the disconnect.
enum MultiplexerController {
    /// Attach command for `target`, typed into the (login-shell) PTY and
    /// newline-terminated. A leading `clear` wipes the login banner/MOTD and the
    /// fresh prompt so they don't bleed into the multiplexer's redraw. nil when
    /// the profile doesn't support attaching (e.g. `none`).
    static func attachCommand(_ mux: MultiplexerProfile, target: String) -> String? {
        guard let command = mux.attachCommand(target: target) else { return nil }
        let withClear = "clear 2>/dev/null; \(command)"
        return withClear.hasSuffix("\n") ? withClear : withClear + "\n"
    }

    /// Locations a multiplexer binary commonly lives that a *non-interactive*
    /// SSH exec channel's PATH usually omits — Homebrew (Apple Silicon/Intel),
    /// Nix/snap, and per-user bins. Without this, `tmux`/`zellij` is "command
    /// not found" over the exec channel even though it's on the user's
    /// interactive PATH, so discovery silently finds no session to reattach.
    static let pathPrefix =
        "PATH=\"$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/run/current-system/sw/bin:/snap/bin:$PATH\""

    /// The exact shell string used for discovery: PATH-augmented (exec channels
    /// are non-login, so the user's interactive PATH is absent) and tolerant of
    /// a missing multiplexer/server. The brace group routes *all* stderr —
    /// including the multiplexer binary's "no server running" — to /dev/null so
    /// it can't pollute the parsed target; `|| true` keeps exit 0. nil if the
    /// profile reports no target command. Pure/testable.
    static func discoveryCommand(_ mux: MultiplexerProfile) -> String? {
        guard let command = mux.currentTargetCommand else { return nil }
        return "{ \(pathPrefix) \(command) ; } 2>/dev/null || true"
    }

    /// First non-empty line of the profile's `currentTargetCommand` output —
    /// the session name to reattach to. nil if the profile can't report one.
    static func currentTarget(_ mux: MultiplexerProfile, on connection: SSHConnection) async -> String? {
        guard let command = discoveryCommand(mux) else { return nil }
        guard let output = try? await connection.runCommand(command) else { return nil }
        return firstTarget(fromOutput: output)
    }

    /// PATH-augmented, stderr-suppressed `listSessionsCommand`. nil if the
    /// profile can't list (e.g. `dtach`/`none`).
    static func listCommand(_ mux: MultiplexerProfile) -> String? {
        guard let command = mux.listSessionsCommand else { return nil }
        return "{ \(pathPrefix) \(command) ; } 2>/dev/null || true"
    }

    /// All attachable session names (one per non-blank output line), so the
    /// reconnect UI can offer a picker when more than one session exists.
    static func availableSessions(_ mux: MultiplexerProfile, on connection: SSHConnection) async -> [String] {
        guard let command = listCommand(mux), mux.attachTemplate != nil else { return [] }
        guard let output = try? await connection.runCommand(command) else { return [] }
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Pure parser (testable): first non-blank trimmed line, or nil.
    static func firstTarget(fromOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
