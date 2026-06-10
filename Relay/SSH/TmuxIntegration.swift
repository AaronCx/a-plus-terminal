import Foundation

/// Helpers for the tmux side of the reconnect contract (§4.1): find which
/// session our PTY is attached to before suspending, and rebuild the attach
/// command after reconnecting. tmux itself survives the disconnect.
enum TmuxIntegration {
    /// Lists sessions as `name<TAB>attached-count`; exits 0 even when no tmux
    /// server is running.
    static let listSessionsCommand = "tmux list-sessions -F '#{session_name}\t#{session_attached}' 2>/dev/null || true"

    static func attachCommand(target: String) -> String {
        let escaped = target.replacingOccurrences(of: "'", with: "'\\''")
        return "tmux attach -t '\(escaped)'\n"
    }

    /// First session with at least one attached client, from
    /// `listSessionsCommand` output.
    static func attachedSession(fromList output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let attached = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            if attached > 0 {
                return String(parts[0])
            }
        }
        return nil
    }

    /// Asks the server which tmux session is currently attached, over a side
    /// channel — the PTY itself is untouched.
    static func currentTarget(on connection: SSHConnection) async -> String? {
        guard let output = try? await connection.runCommand(listSessionsCommand) else { return nil }
        return attachedSession(fromList: output)
    }
}
