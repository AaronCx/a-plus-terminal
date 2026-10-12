import Foundation

/// OSC 7501, the Program Status Protocol
/// (https://www.superlogical.com/rex/docs/build/program-status): a program
/// tells the terminal it is working, blocked on the user, or done.
///
/// A program only reports after the terminal answers its feature probe
/// `OSC 7501 ; ? ST`. The spec: "A supporting terminal MUST reply with `?`",
/// and "a reply without `states` means exactly `idle`, `working`, `done`,
/// `blocked`, and `error`" (kinds default to `permission`, `question`,
/// `auth`) — exactly what this app accepts, so the reply is the bare `?`.
///
/// Claude Code (v2.1.295+) speaks it OUTSIDE tmux only: inside, its probe
/// goes to tmux, which never answers.
enum ProgramStatus {
    static let oscCode = 7501

    /// `ESC ] 7501 ; ? BEL` — terminated like Claude Code's own probe.
    static let probeReply = Data("\u{1B}]7501;?\u{07}".utf8)

    enum State: String {
        case idle, working, done, blocked, error, clear
    }

    struct Record: Equatable {
        var state: State
        /// Only meaningful for `blocked`: permission, question, auth.
        var kind: String?
        /// Sub-record path (a subagent); nil is the program's root record.
        var id: String?
        var app: String?
        var title: String?
        var message: String?
    }

    enum Payload: Equatable {
        /// The program asks whether this terminal speaks the protocol.
        case probe
        case record(Record)
    }

    /// Parses an OSC 7501 payload (the bytes after `7501;`). Nil for a report
    /// the spec says to ignore or discard: no or unknown `state`, base64 that
    /// does not decode, decoded text holding a control character.
    static func parse(_ data: ArraySlice<UInt8>) -> Payload? {
        guard let text = String(bytes: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("?") { return .probe }
        var pairs: [String: String] = [:]
        for pair in text.split(separator: ":", omittingEmptySubsequences: true) {
            // A malformed pair is skipped; a repeated key: the last one wins.
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            pairs[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        guard let raw = pairs["state"], let state = State(rawValue: raw) else { return nil }
        var record = Record(state: state, kind: pairs["kind"], id: pairs["id"], app: pairs["app"])
        let texts: [(String, WritableKeyPath<Record, String?>)] = [("title", \.title), ("msg", \.message)]
        for (key, path) in texts {
            guard let encoded = pairs[key] else { continue }
            guard let decoded = Data(base64Encoded: encoded),
                  let value = String(data: decoded, encoding: .utf8),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            record[keyPath: path] = value
        }
        return .record(record)
    }
}
