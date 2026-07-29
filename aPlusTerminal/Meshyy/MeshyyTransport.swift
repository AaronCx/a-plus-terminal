import Foundation
import MeshyyCore
import MeshyyKit

/// Carries the pty byte stream over meshyy instead of over the SSH channel.
///
/// **Scope, deliberately small.** meshyy replaces the pty and nothing else. The SSH
/// connection stays up and keeps doing everything it does today — SFTP attachments, the
/// localhost preview forward, multiplexer discovery over exec, host-key pinning. Only
/// the interactive byte stream moves.
///
/// That falls out of meshyy's own design (§5.1): the bootstrap runs *over SSH*. The
/// client execs `meshyyd attach --json` and gets back a single-use token, a QUIC port
/// and a certificate fingerprint, so the QUIC certificate is trusted through the SSH
/// host key the user already pinned. There is no second thing to trust, and a host with
/// no daemon simply yields no bootstrap — which is most hosts, and not an error.
///
/// **One shell.** When meshyy carries the terminal, the SSH connection is opened with no
/// pty at all. An earlier version kept the SSH pty open as a live fallback, which meant
/// two shells on one host for one visible terminal and a mid-session switch between
/// them — different scrollback, different cursor, duplicated rc-file side effects. The
/// Settings toggle is the fallback; there is no runtime one.
@MainActor
final class MeshyyTransport {
    /// Why meshyy is not carrying this session. Kept so a caller can say so rather than
    /// silently behaving like a worse SSH client.
    enum Unavailable: LocalizedError, Equatable {
        case daemonAbsent
        case malformedBootstrap(String)
        case protocolTooOld(daemon: Int, client: Int)
        case connectFailed(String)

        var errorDescription: String? {
            switch self {
            case .daemonAbsent:
                return "meshyyd isn't installed on this host — using SSH."
            case .malformedBootstrap(let detail):
                return "meshyyd answered with something unreadable (\(detail)) — using SSH."
            case .protocolTooOld(let daemon, let client):
                return "meshyyd speaks protocol \(daemon), this app speaks \(client) — using SSH."
            case .connectFailed(let detail):
                return "Couldn't open the meshyy connection (\(detail)) — using SSH."
            }
        }
    }

    /// Pty bytes, in arrival order, shaped exactly like `SSHConnection.output` so the
    /// session's pump does not need to know which transport it is reading.
    let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    private let session: MeshyySession
    private let name: String
    private var eventTask: Task<Void, Never>?
    private(set) var isFinished = false

    private init(session: MeshyySession, name: String) {
        self.session = session
        self.name = name
        (output, outputContinuation) = AsyncStream.makeStream(
            of: Data.self,
            // Same bound and same reason as SSHConnection: a runaway remote must not be
            // able to grow this without limit. Dropped bytes are the oldest backlog.
            bufferingPolicy: .bufferingNewest(512)
        )
    }

    // MARK: - Naming

    /// Names the meshyy session for one terminal tab on one server.
    ///
    /// Both halves are load-bearing. Keyed on the SERVER alone, every tab on a host
    /// resolves to the same daemon session and a second terminal drops into the first
    /// one's shell. Keyed on something regenerated per launch — a fresh tab UUID, say —
    /// every launch spawns a NEW remote shell, and on a host whose rc auto-attaches a
    /// multiplexer each one becomes another client; a multiplexer sizes itself to its
    /// smallest client, so the orphans clamp the terminal for the live one.
    ///
    /// A slot is derived from position, so tab 0 on a server resolves to the same
    /// session tomorrow as today.
    ///
    /// Constrained to a charset a shell cannot read as syntax: the command below crosses
    /// an SSH exec channel.
    static func sessionName(serverID: UUID, slot: Int) -> String {
        let host = serverID.uuidString.lowercased().filter { $0.isHexDigit || $0 == "-" }
        return "aplus-\(host)-\(max(0, slot))"
    }

    /// Where `meshyyd` might be, in probe order.
    ///
    /// An SSH **exec** channel is not a login shell: it gets a bare PATH, and neither
    /// that nor `/etc/paths` includes `~/bin` — which is exactly where a self-built
    /// daemon lands. A bare `meshyyd` reports "not installed" on a host where it plainly
    /// is, and the feature looks broken while behaving correctly.
    static let daemonCandidates = [
        "meshyyd",
        "$HOME/bin/meshyyd",
        "/usr/local/bin/meshyyd",
        "/opt/homebrew/bin/meshyyd",
        "/usr/bin/meshyyd",
    ]

    /// Runs `meshyyd <arguments>` on the host, wherever the binary lives.
    ///
    /// `arguments` is composed from values this app controls, never from anything remote
    /// or user-typed — the string is read by a shell on the far side.
    static func daemonCommand(_ arguments: String) -> String {
        let probes = daemonCandidates.map { "\"\($0)\"" }.joined(separator: " ")
        return "for c in \(probes); do "
            + "if command -v \"$c\" >/dev/null 2>&1; then "
            + "exec \"$c\" \(arguments); fi; done; exit 127"
    }

    static func bootstrapCommand(session: String) -> String {
        daemonCommand("attach --session \(session) --json")
    }

    // MARK: - Opening

    /// Runs the §5.1 bootstrap over SSH and, on success, opens the meshyy session.
    ///
    /// Returns a reason rather than throwing for the expected cases: "this host has no
    /// daemon" is the majority of hosts, and the caller's correct response is to carry
    /// on over SSH.
    static func bootstrap(
        over ssh: SSHConnection,
        serverID: UUID,
        slot: Int,
        sshHost: String,
        cols: Int,
        rows: Int
    ) async -> Result<MeshyyTransport, Unavailable> {
        let name = sessionName(serverID: serverID, slot: slot)

        let json: String
        do {
            json = try await ssh.runCommand(bootstrapCommand(session: name))
        } catch {
            return .failure(.daemonAbsent)   // non-zero exit: no daemon here
        }

        let response: BootstrapResponse
        do {
            response = try BootstrapResponse.parse(json)
            try response.validate()
        } catch {
            return .failure(.malformedBootstrap(error.localizedDescription))
        }

        // Frames are additive (§5.3), so a NEWER daemon is fine; an older one may not
        // know a frame this client relies on.
        guard response.protocol >= Meshyy.protocolVersion else {
            return .failure(.protocolTooOld(daemon: response.protocol, client: Meshyy.protocolVersion))
        }

        let session = MeshyySession(size: TerminalSize(cols: cols, rows: rows))
        let transport = MeshyyTransport(session: session, name: name)
        transport.startPump()
        do {
            // A short budget: this sits between tapping a server and seeing a prompt, so
            // a path that cannot work must hand back to SSH quickly rather than eating
            // the whole connect.
            try await session.attach(bootstrap: response, sshHost: sshHost, timeout: .seconds(4))
        } catch {
            await transport.disconnect()
            return .failure(.connectFailed(error.localizedDescription))
        }
        return .success(transport)
    }

    /// Re-attaches this transport over a new SSH connection, keeping its resume point.
    ///
    /// `MeshyySession` carries `consumedOffset` — how many bytes this client has drawn —
    /// and that is the only durable state a resume needs. Building a fresh session per
    /// connect resets it to zero, so every attach asks for a fresh screen and the daemon
    /// replays nothing: the shell survives and the user sees none of what it said.
    func reattach(over ssh: SSHConnection, sshHost: String, cols: Int, rows: Int) async
        -> Result<Void, Unavailable>
    {
        let json: String
        do {
            json = try await ssh.runCommand(Self.bootstrapCommand(session: name))
        } catch {
            return .failure(.daemonAbsent)
        }
        let response: BootstrapResponse
        do {
            response = try BootstrapResponse.parse(json)
            try response.validate()
        } catch {
            return .failure(.malformedBootstrap(error.localizedDescription))
        }
        guard response.protocol >= Meshyy.protocolVersion else {
            return .failure(.protocolTooOld(daemon: response.protocol, client: Meshyy.protocolVersion))
        }
        do {
            try await session.resize(to: TerminalSize(cols: cols, rows: rows))
            try await session.attach(bootstrap: response, sshHost: sshHost, timeout: .seconds(4))
        } catch {
            return .failure(.connectFailed(error.localizedDescription))
        }
        return .success(())
    }

    // MARK: - Running

    /// One ordered consumer of the session's events.
    ///
    /// `MeshyySession` guarantees arrival order is delivery order — it drains a single
    /// AsyncStream rather than spawning a task per frame, because tasks enqueued on an
    /// actor run in an unspecified order and would scramble pty chunks. Preserving that
    /// means not fanning these out either.
    private func startPump() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.session.events {
                switch event {
                case .output(let bytes):
                    self.outputContinuation.yield(Data(bytes))

                case .geometryReset:
                    // A replay carries the scroll region of whichever client produced
                    // it: `ESC[1;24r` from a 24-row session confines a 60-row terminal
                    // to its top 24 rows. These bytes release it. They reach the
                    // emulator like any other, but meshyy never counts them as resumed
                    // output, so the resume offset is untouched.
                    self.outputContinuation.yield(Data(TerminalGeometry.reset))

                case .screenRebuilt, .termios, .screenMode, .agent, .quickActions, .reconnecting:
                    break   // not this type's business

                case .ended, .failed:
                    self.finish()
                    return
                }
            }
            self.finish()
        }
    }

    func send(_ data: Data) async throws {
        try await session.send([UInt8](data))
    }

    func resize(cols: Int, rows: Int) async throws {
        try await session.resize(to: TerminalSize(cols: cols, rows: rows))
    }

    /// Ends the session, and the shell behind it. For a tab the user closed.
    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await session.shutdown(reason: "the user closed the session")
        finish()
    }

    /// Leaves without ending it, so the daemon keeps the shell running and its ring
    /// buffer filling. This is the difference that makes meshyy worth having: a
    /// suspended app that detaches comes back to output it never saw.
    func detach() async {
        await session.detach(reason: "the app was suspended")
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        outputContinuation.finish()
    }
}
