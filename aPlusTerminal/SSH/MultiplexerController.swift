import Foundation

/// Drives the multiplexer side of the reconnect contract (§4.1) from a
/// `MultiplexerProfile` — no multiplexer is named in code. Discovers the
/// currently-attached target before a drop and rebuilds the attach command
/// after reconnecting. The multiplexer itself survives the disconnect.
enum MultiplexerController {
    /// Attach command for `target` (already newline-terminated for the PTY),
    /// or nil when the profile doesn't support attaching (e.g. `none`).
    static func attachCommand(_ mux: MultiplexerProfile, target: String) -> String? {
        guard let command = mux.attachCommand(target: target) else { return nil }
        return command.hasSuffix("\n") ? command : command + "\n"
    }

    /// First non-empty line of the profile's `currentTargetCommand` output —
    /// the session name to reattach to. nil if the profile can't report one.
    static func currentTarget(_ mux: MultiplexerProfile, on connection: SSHConnection) async -> String? {
        guard let command = mux.currentTargetCommand else { return nil }
        // Tolerate a missing multiplexer/server: `|| true` keeps exit 0.
        guard let output = try? await connection.runCommand("\(command) 2>/dev/null || true") else {
            return nil
        }
        return firstTarget(fromOutput: output)
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
