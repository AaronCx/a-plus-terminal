import Foundation

/// One candidate dev server the preview sheet can offer.
struct DetectedPort: Identifiable, Equatable, Sendable {
    var id: Int { port }
    let port: Int
    /// Path the server actually advertised ("/admin"), from the output scrape
    /// or an OSC 8 hyperlink. nil means "load the root" — the preview must not
    /// invent a path, because a framework mounted under a sub-path serves 404
    /// at `/`.
    var path: String?
    /// Process name from `lsof`/`ss` ground truth. nil when only `netstat`
    /// answered (BSD `netstat -an` has no process column) or the port has so
    /// far only ever been printed, never confirmed listening.
    var process: String?
    /// Absent from two consecutive listener snapshots — greyed in the UI but
    /// deliberately still offered. See the merge notes on `PortDetector`.
    var isStale: Bool
}

/// A `scheme://loopback[:port][/path]` occurrence lifted out of terminal output.
struct ScrapedEndpoint: Equatable, Sendable {
    let port: Int
    let path: String?
}

/// One LISTEN row of `lsof`/`ss`/`netstat` output.
struct ListenerRow: Equatable, Sendable {
    let port: Int
    let process: String?
}

// The two tables below sit at file scope rather than being `static let`s on
// `PortDetector`: members of a `@MainActor` type are themselves main-actor
// isolated, and the scanners that read these are deliberately `nonisolated`
// (they touch no instance state, which is what makes them testable off the
// main actor). Reading an isolated static from a nonisolated context warns
// today and is an error under the Swift 6 language mode.

/// Trailing punctuation that belongs to the sentence, not the URL: "open
/// http://localhost:3000/admin." and the markdown form
/// "[preview](http://localhost:3000/admin)" must both yield "/admin". A real
/// path ending in one of these loses a character; that is the rarer and far
/// less annoying failure.
private let pathNoise: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\"", "'", "’", "”", "`"]

/// Loopback hostnames the scraper will match, pre-split into scalar arrays so
/// the hot scan compares without allocating.
private let loopbackHostScalars: [[UnicodeScalar]] = [
    Array("localhost".unicodeScalars),
    Array("127.0.0.1".unicodeScalars),
    Array("0.0.0.0".unicodeScalars),
    Array("[::1]".unicodeScalars),
]

/// Finds the dev servers running on the far end of the SSH session, fusing
/// three sources into one ordered, deduplicated candidate list:
///
/// - **A — output scrape** (`observe`): the URL the server prints on boot.
///   Instant and the only source that knows the *path* (`/admin`), but it is a
///   claim, not proof: the process may already be dead.
/// - **B — OSC 8 hyperlink** (`note(url:)`): SwiftTerm hands us the link the
///   user tapped. Same standing as A, with a parsed URL instead of a regexed
///   one.
/// - **C — listener snapshot** (`applyListenerSnapshot`): ground truth from
///   `lsof`/`ss`/`netstat` over an exec channel. Proves liveness and names the
///   process, but knows nothing about paths and lags by the poll interval.
///
/// **Merge rules.** A port is one entry no matter how many sources saw it:
/// A/B contribute `path`, C contributes `process` and liveness. An entry
/// missing from two *consecutive* snapshots is marked `isStale` rather than
/// dropped — a single miss is routine (the snapshot can easily run in the
/// window between the banner printing and the socket binding, and `lsof` on a
/// busy box sometimes returns nothing at all), and silently deleting a row the
/// user is reaching for is far worse than greying one that is still there.
/// Reappearing clears staleness and the miss counter.
///
/// **No heuristic filtering.** Ports 22, 631, 5432 and friends are surfaced
/// like any other. Guessing "that's not a dev server" is exactly the judgement
/// that breaks for the person tunnelling a database UI, an IPP admin page, or
/// an app that happens to listen on 22 inside a container — the list is short,
/// labelled with the process name, and the user picks.

@MainActor
final class PortDetector {
    static let maxEntries = 8
    /// Ordered fallbacks: `lsof` is the macOS answer, `ss` the modern Linux
    /// one, `netstat -an` the last resort that exists essentially everywhere
    /// (BusyBox included). `2>/dev/null` keeps "command not found" out of the
    /// parsed text, and `||` chains to the next tool only when the previous one
    /// failed outright.
    static let listenerCommand = "lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || ss -lntp 2>/dev/null || netstat -an"

    /// Most-recent-first, deduped by port, capped at `maxEntries`.
    private(set) var ports: [DetectedPort] = []

    /// Consecutive listener snapshots that did not mention a port.
    private var missedSnapshots: [Int: Int] = [:]
    /// Ports a human-visible source (a printed URL or a tapped OSC 8 link)
    /// vouched for. These outrank ports that only ever showed up in a listener
    /// snapshot — see `trimToCap`, where that distinction stops a busy host
    /// from evicting the one entry the user is actually reaching for.
    private var scrapedPorts: Set<Int> = []
    /// Raw byte tail of the previous chunk, so a URL split across two reads is
    /// reassembled before decoding — the same carry pattern
    /// `AgentActivityMonitor.scanForMarker` uses, and for the same reason: a
    /// PTY read boundary lands wherever the network put it, and
    /// `http://localhost:51` + `73/` is the common case, not the exotic one.
    /// Raw bytes (not a String) so a multibyte UTF-8 sequence split across the
    /// boundary also survives.
    private var carryBytes: [UInt8] = []

    /// Two misses, not one: see the staleness note in the type doc.
    private static let staleAfterMissedSnapshots = 2
    /// Wide enough for a realistic banner line — a dev-server URL line is well
    /// under 200 bytes even wrapped in colour codes and a box-drawing frame —
    /// and bounded so a firehose (`cat /dev/urandom`) can never grow it.
    private static let carryWindowBytes = 512

    // MARK: - Source A: output scrape

    /// Called from the PTY pump for every output chunk, beside
    /// `agentMonitor.observe(bytes)`.
    func observe(_ bytes: [UInt8]) {
        // PERFORMANCE GATE. This sits directly in the path of a potential
        // firehose (a build log, `yes`, a `cat` of a big file), so nothing
        // above this line may allocate per chunk. A URL cannot exist without
        // the ASCII bytes "://", and that check is a single pass over raw
        // bytes with no String, no UTF-8 decode, no ANSI strip and no scan —
        // all of which are an order of magnitude more expensive and are
        // skipped for the overwhelming majority of chunks, which carry no URL.
        guard Self.containsSchemeMarker(carry: carryBytes, chunk: bytes) else {
            rememberTail(bytes)
            return
        }

        // Colour codes routinely land *inside* the URL (vite underlines the
        // port, cargo bolds the host), so strip escapes with the same routine
        // the agent monitor uses before matching.
        let text = AgentActivityMonitor.stripANSI(String(decoding: carryBytes + bytes, as: UTF8.self))
        // Only text up to the last whitespace is complete. A chunk boundary
        // inside a URL otherwise scrapes its prefix — "http://localhost:51"
        // yields a plausible-looking port 51 that nothing ever retracts. The
        // trailing token waits in the carry and is re-scanned (and emitted)
        // the moment the rest arrives, which for a printed banner line is the
        // very next byte, its newline. A URL that is the last output ever, with
        // no trailing whitespace at all, is left to source C — which finds any
        // listening server regardless of what it printed.
        for endpoint in Self.scrape(String(Self.completedPrefix(of: text))) {
            upsert(port: endpoint.port, path: endpoint.path, process: nil, vouched: true)
        }
        rememberTail(bytes)
    }

    // MARK: - Source B: OSC 8 hyperlink

    /// SwiftTerm reported a hyperlink; adopt it when it points at the far end's
    /// loopback. The user tapping a link *is* an intent signal, so this
    /// promotes the port to the head of the list.
    func note(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, Self.isLoopbackHost(host) else { return }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        // The query is part of what the server asked us to open (`?token=…` is
        // how notebook servers hand over auth), so it rides along with the path.
        var path = url.path
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }
        upsert(port: port, path: (path.isEmpty || path == "/") ? nil : path, process: nil, vouched: true)
    }

    // MARK: - Source C: listener ground truth

    func applyListenerSnapshot(_ output: String) {
        let rows = Self.parseListeners(output)
        let live = Set(rows.map(\.port))

        // In snapshot order: a first sighting from here is *appended*, never
        // promoted, so the list keeps the snapshot's own ordering and stays
        // stable across polls.
        for row in rows {
            upsert(port: row.port, path: nil, process: row.process, vouched: false)
        }

        for index in ports.indices where !live.contains(ports[index].port) {
            let port = ports[index].port
            let misses = (missedSnapshots[port] ?? 0) + 1
            missedSnapshots[port] = misses
            if misses >= Self.staleAfterMissedSnapshots {
                ports[index].isStale = true
            }
        }
    }

    func reset() {
        ports = []
        missedSnapshots = [:]
        scrapedPorts = []
        carryBytes = []
    }

    // MARK: - Merge

    /// `vouched` marks the human-visible sources — a URL the server printed or
    /// a link the user tapped. Those are intent signals and take the head of
    /// the list; a bare listener sighting is appended instead. The distinction
    /// is not cosmetic: a developer Mac routinely has 20–40 TCP listeners
    /// (Spotlight, sharing daemons, Docker, databases), and promoting each one
    /// would push the dev server the user just started — and its path — off an
    /// 8-entry list before they could tap it.
    private func upsert(port: Int, path: String?, process: String?, vouched: Bool) {
        guard (1...65535).contains(port) else { return }
        if vouched { scrapedPorts.insert(port) }

        if let index = ports.firstIndex(where: { $0.port == port }) {
            var entry = ports[index]
            // nil never overwrites: a listener snapshot knows no path and a
            // scrape knows no process, so each source only ever fills in its
            // own column. This is also what keeps "/admin" alive when the
            // server later prints a bare "http://localhost:5173".
            if let path { entry.path = path }
            if let process { entry.process = process }
            entry.isStale = false
            if vouched {
                ports.remove(at: index)
                ports.insert(entry, at: 0)
            } else {
                // A snapshot re-confirms every live port at once; re-stamping
                // them all would reshuffle the list under the user's finger on
                // every poll.
                ports[index] = entry
            }
        } else if vouched {
            ports.insert(DetectedPort(port: port, path: path, process: process, isStale: false), at: 0)
        } else {
            ports.append(DetectedPort(port: port, path: path, process: process, isStale: false))
        }
        missedSnapshots[port] = 0
        trimToCap()
    }

    /// Evicts the last entry nothing vouched for, falling back to the plain
    /// oldest only when every entry is vouched. Evicting blindly from the tail
    /// is what let a busy host delete the scraped dev-server entry the whole
    /// feature exists to offer.
    private func trimToCap() {
        while ports.count > Self.maxEntries {
            let victim = ports.lastIndex { !scrapedPorts.contains($0.port) } ?? (ports.count - 1)
            let port = ports[victim].port
            missedSnapshots[port] = nil
            scrapedPorts.remove(port)
            ports.remove(at: victim)
        }
    }

    /// Keeps the tail in place rather than rebuilding `carry + chunk`, so a
    /// 64 KB chunk costs one bounded copy instead of one proportional to the
    /// chunk.
    private func rememberTail(_ bytes: [UInt8]) {
        if bytes.count >= Self.carryWindowBytes {
            carryBytes = Array(bytes.suffix(Self.carryWindowBytes))
            return
        }
        carryBytes.append(contentsOf: bytes)
        if carryBytes.count > Self.carryWindowBytes {
            carryBytes.removeFirst(carryBytes.count - Self.carryWindowBytes)
        }
    }

    // MARK: - Scraping (pure, testable)

    /// True when the ASCII bytes `://` appear anywhere in carry-then-chunk,
    /// including across the boundary between them — scanned as one logical
    /// sequence without concatenating the two buffers.
    private nonisolated static func containsSchemeMarker(carry: [UInt8], chunk: [UInt8]) -> Bool {
        let colon = UInt8(ascii: ":")
        let slash = UInt8(ascii: "/")
        var matched = 0 // 0 = nothing, 1 = ":", 2 = ":/"
        func scan(_ buffer: [UInt8]) -> Bool {
            for byte in buffer {
                switch matched {
                case 0:
                    matched = byte == colon ? 1 : 0
                case 1:
                    matched = byte == slash ? 2 : (byte == colon ? 1 : 0)
                default:
                    if byte == slash { return true }
                    matched = byte == colon ? 1 : 0
                }
            }
            return false
        }
        return scan(carry) || scan(chunk)
    }

    /// Everything up to (not including) the last whitespace character; empty
    /// when the text has none, since then nothing in it is known complete.
    private nonisolated static func completedPrefix(of text: String) -> Substring {
        guard let index = text.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return text[..<index]
    }

    /// Hand-rolled scanner rather than `NSRegularExpression`: no per-chunk
    /// NSString bridging, no optional-regex hatch to fall through, and the
    /// backtracking hazards of an optional-port-plus-optional-path pattern
    /// (which happily degrades `http://localhost:5173.` into "port 80") are
    /// structurally impossible here. Matches
    /// `https?://(localhost|127.0.0.1|0.0.0.0|[::1])(:port)?(/path)?` and
    /// returns every occurrence in order of appearance; deduplication is the
    /// merge's job.
    nonisolated static func scrape(_ text: String) -> [ScrapedEndpoint] {
        let scalars = Array(text.unicodeScalars)
        var results: [ScrapedEndpoint] = []
        var index = 0

        while index + 2 < scalars.count {
            guard scalars[index] == ":", scalars[index + 1] == "/", scalars[index + 2] == "/" else {
                index += 1
                continue
            }
            guard let scheme = schemeEnding(at: index, in: scalars) else {
                index += 3
                continue
            }
            var cursor = index + 3
            guard let hostLength = matchedHostLength(scalars, at: cursor) else {
                index += 3
                continue
            }
            cursor += hostLength

            // Default by scheme: a bare http://localhost/ is port 80, https is 443.
            var port = scheme == "https" ? 443 : 80
            if cursor < scalars.count, scalars[cursor] == ":" {
                var end = cursor + 1
                while end < scalars.count, isASCIIDigit(scalars[end]) { end += 1 }
                if end > cursor + 1 {
                    guard let parsed = Int(string(scalars, cursor + 1, end)), (1...65535).contains(parsed) else {
                        // "http://localhost:99999" is not a port — refuse the
                        // whole match rather than silently offering the default.
                        index += 3
                        continue
                    }
                    port = parsed
                    cursor = end
                }
                // A colon with no digits after it is prose ("Serving on
                // http://localhost: press q to quit"); the default port stands.
            }

            var path: String?
            if cursor < scalars.count, scalars[cursor] == "/" {
                var end = cursor
                while end < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[end]) { end += 1 }
                path = normalizedPath(string(scalars, cursor, end))
                cursor = end
            }

            results.append(ScrapedEndpoint(port: port, path: path))
            index = cursor
        }
        return results
    }


    private nonisolated static func normalizedPath(_ raw: String) -> String? {
        var path = raw
        while let last = path.last, pathNoise.contains(last) { path.removeLast() }
        // Only an exact "/" collapses to nil — "/admin/" is kept verbatim,
        // because a trailing slash can be load-bearing for the router.
        return (path.isEmpty || path == "/") ? nil : path
    }

    /// The scheme token immediately left of "://", lowercased, or nil when it
    /// is not http/https. Requires the *whole* preceding word to match, so
    /// "xhttp://localhost" is not a URL.
    private nonisolated static func schemeEnding(at index: Int, in scalars: [UnicodeScalar]) -> String? {
        var start = index
        while start > 0, isASCIILetter(scalars[start - 1]) { start -= 1 }
        guard start < index else { return nil }
        let scheme = string(scalars, start, index).lowercased()
        return (scheme == "http" || scheme == "https") ? scheme : nil
    }


    private nonisolated static func matchedHostLength(_ scalars: [UnicodeScalar], at start: Int) -> Int? {
        for host in loopbackHostScalars {
            guard start + host.count <= scalars.count else { continue }
            var matches = true
            for offset in 0..<host.count where asciiLowered(scalars[start + offset]) != host[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            // The literal must end the hostname. Without this,
            // "http://localhost.evil.com/" and "http://127.0.0.1.evil.com/"
            // match their loopback *prefix* and we would offer to tunnel — and
            // render in a WKWebView — a name that resolves anywhere at all.
            let next = start + host.count
            if next < scalars.count, isHostCharacter(scalars[next]) { continue }
            return host.count
        }
        return nil
    }

    // MARK: - Listener parsing (pure, testable)

    nonisolated static func parseListeners(_ output: String) -> [ListenerRow] {
        var rows: [ListenerRow] = []
        var indexByPort: [Int: Int] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            guard let row = parseListenerLine(String(line)) else { continue }
            if let existing = indexByPort[row.port] {
                // One server yields several rows (lsof prints the IPv4 and IPv6
                // sockets separately, ss one per address family). Keep the first
                // row's position but let a later row fill in a process name the
                // first one lacked.
                if rows[existing].process == nil, let process = row.process {
                    rows[existing] = ListenerRow(port: row.port, process: process)
                }
                continue
            }
            indexByPort[row.port] = rows.count
            rows.append(row)
        }
        return rows
    }

    /// One row of any of the three formats, or nil for headers, blank lines and
    /// non-LISTEN sockets (an ESTABLISHED row is somebody else's connection,
    /// not a server we can preview).
    private nonisolated static func parseListenerLine(_ line: String) -> ListenerRow? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !fields.isEmpty else { return nil }

        // macOS lsof -nP -iTCP -sTCP:LISTEN:
        //   COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        //   node 4321 acx 21u IPv4 0x… 0t0 TCP 127.0.0.1:5173 (LISTEN)
        // NAME is whatever sits just before the "(LISTEN)" token — addressing
        // it that way instead of by column index survives the SIZE/OFF column
        // being blank on some builds. The header line carries no "(LISTEN)"
        // and so is skipped here, not special-cased.
        if let stateIndex = fields.firstIndex(of: "(LISTEN)"), stateIndex >= 2 {
            guard let port = port(fromAddress: fields[stateIndex - 1]) else { return nil }
            // lsof truncates COMMAND to 9 characters unless invoked with
            // "+c 0"; surfaced as-is rather than guessed at.
            return ListenerRow(port: port, process: fields[0])
        }

        // Linux ss -lntp:
        //   State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process
        //   LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:(("node",pid=123,fd=20))
        // The "State" header row fails this test on its first field.
        if fields[0].uppercased() == "LISTEN", fields.count >= 4 {
            guard let port = port(fromAddress: fields[3]) else { return nil }
            // The process column is absent without -p or without privileges.
            return ListenerRow(port: port, process: processName(inSSLine: line))
        }

        // netstat -an fallback, BSD and Linux:
        //   tcp4 0 0 127.0.0.1.5173 *.*        LISTEN
        //   tcp  0 0 127.0.0.1:5173 0.0.0.0:*  LISTEN
        // No process column exists in either, so `process` is nil — the row is
        // still worth having, since liveness is what stops an entry going stale.
        if fields[0].lowercased().hasPrefix("tcp"), fields.contains("LISTEN"), fields.count >= 4 {
            guard let port = port(fromAddress: fields[3]) else { return nil }
            return ListenerRow(port: port, process: nil)
        }

        return nil
    }

    /// Port out of `*:5173`, `127.0.0.1:5173`, `[::1]:5173`, and the BSD
    /// netstat forms `127.0.0.1.5173` / `::1.5173`. Reading the trailing digit
    /// run and then checking its separator handles both delimiters without
    /// having to know which tool produced the line — splitting on ":" breaks on
    /// "::1.5173" and splitting on "." breaks on "127.0.0.1:5173".
    private nonisolated static func port(fromAddress address: String) -> Int? {
        let scalars = Array(address.unicodeScalars)
        let end = scalars.count
        var start = end
        while start > 0, isASCIIDigit(scalars[start - 1]) { start -= 1 }
        // start > 0 also rejects a bare number with no address in front of it.
        guard start < end, start > 0, end - start <= 5 else { return nil }
        let separator = scalars[start - 1]
        guard separator == ":" || separator == "." else { return nil }
        guard let port = Int(string(scalars, start, end)), (1...65535).contains(port) else { return nil }
        return port
    }

    /// Command name out of ss's `users:(("node",pid=123,fd=20))` column. Read
    /// off the whole line because the column may list several sockets and only
    /// the first name is wanted.
    private nonisolated static func processName(inSSLine line: String) -> String? {
        guard let marker = line.range(of: "users:((") else { return nil }
        let rest = line[marker.upperBound...]
        guard rest.first == "\"" else { return nil }
        let quoted = rest.dropFirst()
        guard let close = quoted.firstIndex(of: "\"") else { return nil }
        let name = String(quoted[..<close])
        return name.isEmpty ? nil : name
    }

    // MARK: - Host classification

    /// Loopback for our purposes: `localhost`, the whole `127.0.0.0/8` range,
    /// the `0.0.0.0` wildcard (a server bound to every interface is reachable
    /// on loopback too) and IPv6 `::1` with or without brackets,
    /// case-insensitively.
    ///
    /// Everything else is rejected, and the rejection that matters is the
    /// lookalike: `localhost.evil.com` and `127.0.0.1.evil.com` are ordinary
    /// public names whose *prefix* reads as loopback. Accepting one would mean
    /// forwarding to, and rendering in a WKWebView, a host the user never
    /// chose — so matching is exact, never prefix-based.
    nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if value == "localhost" || value == "::1" || value == "0.0.0.0" { return true }

        // `omittingEmptySubsequences: false` so "127.0.0.1." and
        // "127.0.0.1.evil.com" split into the wrong number of parts and fail,
        // instead of collapsing back to a valid-looking quad.
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = Int(part), (0...255).contains(octet) else { return false }
            return true
        }
    }

    // MARK: - Scalar helpers

    private nonisolated static func string(_ scalars: [UnicodeScalar], _ start: Int, _ end: Int) -> String {
        var view = String.UnicodeScalarView()
        for index in start..<end { view.append(scalars[index]) }
        return String(view)
    }

    private nonisolated static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    private nonisolated static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    /// Characters that can continue a hostname — used to prove a matched
    /// loopback literal is the whole name and not a prefix of a longer one.
    private nonisolated static func isHostCharacter(_ scalar: UnicodeScalar) -> Bool {
        isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }

    private nonisolated static func asciiLowered(_ scalar: UnicodeScalar) -> UnicodeScalar {
        guard (0x41...0x5A).contains(scalar.value),
              let lowered = UnicodeScalar(scalar.value + 0x20) else { return scalar }
        return lowered
    }
}
