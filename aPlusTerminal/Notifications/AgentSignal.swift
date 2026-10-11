import Foundation
import SwiftTerm

/// Something the program in the terminal SAID to get the user's attention.
/// These are the only things that post an agent notification: the timing
/// heuristic in `AgentActivityMonitor` guesses, and a guess is fine for a
/// badge but not for a buzz in the user's pocket.
enum AgentSignal: Equatable {
    /// A bare BEL. Claude Code with `"preferredNotifChannel": "terminal_bell"`
    /// rings it ~6 s into an unanswered permission prompt and ~60 s after a
    /// finished turn.
    case bell
    /// OSC 9 (iTerm2-style) desktop notification: just a message.
    case osc9(message: String)
    /// OSC 777 `notify;<title>;<body>` (Ghostty/urxvt-style).
    case osc777(title: String, body: String)
    /// An OSC 7501 Program Status record.
    case programStatus(ProgramStatus.Record)

    /// What the user would be told, or nil when the signal is a status update
    /// rather than a request: 7501 `working`/`idle`/`error`/`clear` never
    /// post, and neither does a SUBAGENT's `done` — the session is not done.
    var trigger: AgentAlertPolicy.Trigger? {
        switch self {
        case .bell:
            return .bell
        case .osc9(let message):
            return .message(title: nil, body: message)
        case .osc777(let title, let body):
            return .message(title: title.isEmpty ? nil : title, body: body)
        case .programStatus(let record):
            switch record.state {
            case .blocked:
                return .blocked(kind: record.kind)
            case .done where record.id == nil:
                return .finished
            default:
                return nil
            }
        }
    }

    /// Log-safe name: the kind of signal, never its text.
    var logName: String {
        switch self {
        case .bell: return "bell"
        case .osc9: return "osc9"
        case .osc777: return "osc777"
        case .programStatus(let record):
            return "osc7501-\(record.state.rawValue)\(record.kind.map { "-\($0)" } ?? "")\(record.id == nil ? "" : "-sub")"
        }
    }

    /// What an OSC 9 payload is. `9;4;…` is ConEmu's progress report, which
    /// SwiftTerm draws as a bar; other `9;<digits>;…` forms are ConEmu
    /// commands (`9;9;<cwd>` from some prompts). Only the rest is iTerm2's
    /// "post a notification".
    enum OSC9: Equatable {
        case progress(Terminal.ProgressReport)
        case notification(String)
        case ignored
    }

    static func parseOSC9(_ data: ArraySlice<UInt8>) -> OSC9 {
        guard let text = String(bytes: data, encoding: .utf8), !text.isEmpty,
              !text.allSatisfy(\.isASCIIDigit) else { return .ignored }
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isASCIIDigit) {
            guard parts[0] == "4", let report = parseProgress(parts[1]) else { return .ignored }
            return .progress(report)
        }
        return .notification(text)
    }

    /// SwiftTerm's own `9;4;<state>[;<progress>]` parse (internal there), so
    /// the progress bar keeps working with this app's OSC 9 handler installed.
    private static func parseProgress(_ rest: Substring) -> Terminal.ProgressReport? {
        let parts = rest.split(separator: ";", omittingEmptySubsequences: false)
        guard let statePart = parts.first, statePart.count == 1,
              let stateValue = Int(statePart),
              let state = Terminal.ProgressReportState(rawValue: stateValue) else { return nil }
        var progress: UInt8?
        if parts.count >= 2, !parts[1].isEmpty {
            guard let raw = Int(parts[1]) else { return nil }
            progress = UInt8(max(0, min(raw, 100)))
        } else if state == .set {
            progress = 0
        }
        if state == .remove {
            progress = nil
        }
        return Terminal.ProgressReport(state: state, progress: progress)
    }

    /// OSC 777 `notify;<title>;<body>` — the body may itself hold `;`.
    static func parseOSC777(_ data: ArraySlice<UInt8>) -> AgentSignal? {
        guard let text = String(bytes: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: ";")
        guard parts.count >= 3, parts[0] == "notify" else { return nil }
        return .osc777(title: parts[1], body: parts[2...].joined(separator: ";"))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
