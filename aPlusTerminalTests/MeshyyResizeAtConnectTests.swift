import MeshyyCore
import XCTest
@testable import aPlusTerminal

/// The terminal must be the right size the moment a meshyy session opens — not ten
/// seconds later.
///
/// **The bug this exists for.** The outbox routes a resize to meshyy when meshyy is set
/// and to the SSH connection otherwise. During the bootstrap meshyy is not set yet, and
/// under meshyy that SSH connection is deliberately opened with no pty — so a size
/// SwiftTerm reports in that window is handed to a channel that cannot take it and is
/// silently dropped. Nothing corrects it afterwards, because `sizeChanged` fires only
/// when the size CHANGES.
///
/// Except that something did, eventually, and that is what made this so hard to see:
/// the keepalive ping is a no-op window-change sent through the same outbox, and by the
/// time it fires meshyy exists, so it delivers the correct size as a side effect. With
/// `defaultFirstKeepaliveDelay` at 10 seconds, the symptom was "resizing works, but only
/// after being in the session a while, never from the jump" — which reads like a
/// rendering or emulator problem and is neither.
///
/// So this test **disables the keepalive**. Without that it passes against the broken
/// code, ten seconds late, and proves nothing.
///
/// The daemon was never at fault: `stty size` across a live resize reported 24 80 before
/// and 60 80 after. The size that never arrives is the one that was never sent.
///
/// Needs a local `meshyyd` and an SSH key this Mac accepts; skips cleanly without them:
///
///     ./scripts/meshyy-repro-setup.sh && make test-meshyy-live
@MainActor
final class MeshyyResizeAtConnectTests: XCTestCase {
    /// A size nothing else in the stack would pick by accident — not 80x24, not a
    /// plausible device geometry — so a pass cannot come from a default lining up.
    private static let target = (cols: 97, rows: 41)

    func testASizeReportedDuringTheBootstrapReachesTheShellWithoutTheKeepalive() async throws {
        let session = try makeMeshyySession()
        // THE LOAD-BEARING LINE. The keepalive would deliver this size on its own at
        // t+10s and turn a real failure into a slow pass.
        session.firstKeepaliveDelay = 3600
        session.keepaliveInterval = 3600
        addTeardownBlock { await session.close() }

        // Connect, and report the new size while the bootstrap is still in flight —
        // `connect()` suspends on the SSH socket long before meshyy exists, so this
        // lands squarely inside the window where a resize used to be dropped.
        let connecting = Task { await session.connect() }
        session.resize(cols: Self.target.cols, rows: Self.target.rows)
        await connecting.value

        guard session.state == .connected else {
            throw XCTSkip("no local meshyy session: \(session.meshyyUnavailable ?? "not connected")")
        }
        guard session.meshyy != nil else {
            throw XCTSkip("connected over SSH, not meshyy: \(session.meshyyUnavailable ?? "no daemon")")
        }

        // Ask the far side what size its pty actually is. `stty size` prints "rows cols";
        // the marker is assembled by printf so the command's own echo cannot satisfy the
        // assertion.
        let reported = try await ask(session, "stty size", marker: "PTYSIZE")
        XCTAssertEqual(
            reported, "\(Self.target.rows) \(Self.target.cols)",
            """
            the shell's pty is \(reported.isEmpty ? "unreadable" : reported) but the terminal is \
            \(Self.target.rows)x\(Self.target.cols). A size reported while the meshyy bootstrap was in \
            flight went to the pty-less SSH connection and was dropped, and with the keepalive \
            disabled nothing came along later to paper over it — which is what the user sees as \
            "resizing only works after being in the session a while"
            """
        )
    }

    /// The same session, resized normally once it is up, must still track — so a fix for
    /// the above cannot work by pinning the size at connect and ignoring later changes.
    func testAResizeAfterConnectStillReachesTheShell() async throws {
        let session = try makeMeshyySession()
        session.firstKeepaliveDelay = 3600
        session.keepaliveInterval = 3600
        addTeardownBlock { await session.close() }

        await session.connect()
        guard session.state == .connected, session.meshyy != nil else {
            throw XCTSkip("no local meshyy session: \(session.meshyyUnavailable ?? "not connected")")
        }

        session.resize(cols: 73, rows: 29)
        let reported = try await ask(session, "stty size", marker: "PTYSIZE")
        XCTAssertEqual(reported, "29 73", "a mid-session resize did not reach the pty (got \(reported.debugDescription))")
    }

    // MARK: - Harness

    /// Runs `command` in the session's shell and returns the single line it printed,
    /// read back off the real terminal view the user would be looking at.
    private func ask(_ session: TerminalSession, _ command: String, marker: String) async throws -> String {
        // printf assembles the marker from two halves so the echoed command line does
        // not contain it — otherwise the echo answers the question, not the shell.
        let head = String(marker.prefix(3)), tail = String(marker.dropFirst(3))
        session.sendInput(Data("printf '%s%s:%s\\n' '\(head)' '\(tail)' \"$(\(command))\"\n".utf8))

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let value = Self.value(after: marker + ":", in: session.terminalView) { return value }
            try await Task.sleep(for: .milliseconds(120))
        }
        return ""
    }

    /// Scans the rendered grid for `prefix` and returns the rest of that row.
    ///
    /// Reads the emulator rather than the byte stream deliberately: the size the user
    /// cares about is the one the terminal ends up displaying.
    private static func value(after prefix: String, in view: TerminalEmulatorView) -> String? {
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            var text = ""
            for column in 0..<terminal.cols { text.append(line[column].getCharacter()) }
            text = text.replacingOccurrences(of: "\0", with: " ")
            guard let range = text.range(of: prefix) else { continue }
            let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// A session pointed at this Mac, with meshyy on and the probe key in a real
    /// KeyStore — the app's own path end to end, not a transport built by hand.
    private func makeMeshyySession() throws -> TerminalSession {
        let pem = try probeKeyPEM()
        let suffix = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory

        let keyStore = KeyStore(
            secrets: InMemorySecretStore(),
            metadataURL: temporary.appendingPathComponent("keys-\(suffix).json")
        )
        let key = try keyStore.importKey(named: "probe", openSSHPrivateKey: pem)

        let serverStore = ServerStore(
            fileURL: temporary.appendingPathComponent("servers-\(suffix).json")
        )
        var entry = Server(name: "probe", host: "127.0.0.1", username: Self.probeUser)
        entry.keyID = key.id
        serverStore.add(entry)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "MeshyyResizeAtConnect-\(suffix)")!)
        settings.meshyyTransport = true

        // Isolation from the user's own sessions on this same Mac comes from the
        // server id: it is fresh per run, meshyy sessions are grouped by it, and the
        // daemon allocates within the group — so this test's shell cannot collide
        // with anything the user's phone is attached to.
        let session = TerminalSession(
            server: entry,
            keyStore: keyStore,
            serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: ProfileStore(
                agents: [],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        )
        // A headless view never lays out, and an unlaid-out terminal is a 2x1 grid —
        // the shell answers, the answer scrolls off a one-row screen, and every read
        // comes back empty. Diagnosed from a grid dump: `%` was sitting in a 2x1
        // terminal. The pty's size (what the assertions check) comes from
        // `session.resize`, not from this frame; the frame only makes output READABLE.
        session.terminalView.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        session.terminalView.layoutIfNeeded()
        return session
    }

    /// The host's login name, written by the setup script. `NSUserName()` in the
    /// simulator is not reliably this Mac's login name, and the username is what sshd
    /// matches the key against.
    private static var probeUser: String {
        (try? String(contentsOfFile: "/tmp/aplus-probe-user.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? NSUserName()
    }

    private func probeKeyPEM() throws -> String {
        guard let pem = try? String(contentsOfFile: "/tmp/aplus-probe-key.pem", encoding: .utf8),
              pem.contains("PRIVATE KEY")
        else {
            throw XCTSkip("no probe key at /tmp/aplus-probe-key.pem — run ./scripts/meshyy-repro-setup.sh")
        }
        return pem
    }
}
