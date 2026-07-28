import Foundation
import MeshyyCore
import MeshyyKit

/// Carries the PTY byte stream over meshyy instead of over the SSH channel.
///
/// **meshyy replaces one thing and nothing else.** The SSH connection stays up and
/// keeps doing everything it does today — SFTP attachments, the localhost preview's
/// direct-tcpip forward, tmux discovery over exec. Only the interactive byte stream
/// moves. That is what makes this safe to ship behind a toggle: if any part of the
/// meshyy path fails, the session is still a normal SSH session and the user loses a
/// feature rather than their terminal.
///
/// The reason it works that way is in meshyy's own design (§5.1): the bootstrap runs
/// *over SSH*. The client executes `meshyyd attach --json` on an exec channel and gets
/// back a single-use token, a QUIC port and a certificate fingerprint — so the trust
/// chain terminates in the SSH host key the user already pinned, and there is no second
/// thing to trust. A daemon that is absent, older than this client, or refusing simply
/// yields no bootstrap, and `bootstrap` returns nil.
///
/// What the user gets when it works: the session survives suspension, roaming and a
/// dead network, because the daemon holds the PTY and replays what was missed from a
/// ring buffer. What they get when it does not: exactly build 43.
@MainActor
final class MeshyyTransport {
    /// Why meshyy was not used. Surfaced in the session's status line rather than
    /// swallowed — a silent fallback is indistinguishable from a broken feature, and
    /// the whole point of the toggle is to find out whether it works.
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

    /// PTY bytes, in arrival order, shaped exactly like `SSHConnection.output` so the
    /// session's pump does not care which transport it is reading.
    let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// The resumable session identity. Stable across reconnects and app launches, so
    /// the daemon can replay what was missed rather than starting a new shell.
    let sessionID: String

    private let session: MeshyySession
    private var eventTask: Task<Void, Never>?
    private(set) var isFinished = false

    /// The session name, kept so every reattach lands on the SAME daemon session.
    private let name: String

    private init(session: MeshyySession, sessionID: String, name: String) {
        self.session = session
        self.sessionID = sessionID
        self.name = name
        (output, outputContinuation) = AsyncStream.makeStream(
            of: Data.self,
            // Matches SSHConnection's bound and for the same reason: a hostile or
            // runaway remote must not be able to grow this without limit. The dropped
            // bytes are the oldest backlog, already scrolled off screen.
            bufferingPolicy: .bufferingNewest(512)
        )
    }

    /// Names the meshyy session for a server.
    ///
    /// Derived from the server's own identifier so it is stable across launches —
    /// resume is worthless if the name changes — and constrained to a charset that
    /// cannot mean anything to a shell. The command below crosses an SSH exec channel
    /// and is interpreted by the remote shell, so an unconstrained name here would be
    /// a command-injection hole in the same class meshyy's own daemon rules forbid.
    static func sessionName(for serverID: UUID) -> String {
        "aplus-" + serverID.uuidString.lowercased().filter { $0.isHexDigit || $0 == "-" }
    }

    /// Where `meshyyd` might be, in probe order.
    ///
    /// An SSH **exec** channel is not a login shell: it gets a bare PATH, which on
    /// macOS is `/usr/bin:/bin:/usr/sbin:/sbin` plus whatever `/etc/paths` adds.
    /// Neither includes `~/bin`, which is exactly where a self-built daemon lands. So
    /// a bare `meshyyd` would report "not installed" on a host where it plainly is,
    /// and the feature would appear broken while behaving correctly — verified on this
    /// Mac before it could waste a TestFlight cycle.
    ///
    /// `$HOME` is expanded by the remote shell, deliberately: only the daemon's own
    /// user knows where their `~` is.
    static let daemonCandidates = [
        "meshyyd",                    // on PATH, if the user put it there
        "$HOME/bin/meshyyd",          // self-built, the common case
        "/usr/local/bin/meshyyd",
        "/opt/homebrew/bin/meshyyd",
        "/usr/bin/meshyyd",
    ]

    /// The exact command run on the exec channel.
    ///
    /// `session` is the ONLY value this side interpolates, and `sessionName(for:)`
    /// filters it to `[a-z0-9-]` — the command crosses a shell, so anything else would
    /// be an injection hole of the same class meshyy's own daemon rules forbid.
    static func bootstrapCommand(session: String) -> String {
        let probes = daemonCandidates.map { "\"\($0)\"" }.joined(separator: " ")
        return "for c in \(probes); do "
            + "if command -v \"$c\" >/dev/null 2>&1; then "
            + "exec \"$c\" attach --session \(session) --json; fi; done; exit 127"
    }

    /// Runs the §5.1 bootstrap over SSH and, if it succeeds, opens the meshyy session.
    ///
    /// Returns `nil` reasons rather than throwing for the expected cases, because
    /// "this host has no daemon" is not an error — it is the majority of hosts, and
    /// the caller's correct response is to carry on over SSH.
    static func bootstrap(
        over ssh: SSHConnection,
        serverID: UUID,
        sshHost: String,
        cols: Int,
        rows: Int
    ) async -> Result<MeshyyTransport, Unavailable> {
        let name = sessionName(for: serverID)

        // A missing `meshyyd` exits non-zero, which Citadel surfaces as a thrown
        // CommandFailed. That is the common case, not a fault.
        let json: String
        do {
            json = try await ssh.runCommand(bootstrapCommand(session: name))
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

        // Additive frames mean a NEWER daemon is fine; an older one is not, because it
        // may not know a frame this client relies on. §5.3.
        guard response.protocol >= Meshyy.protocolVersion else {
            return .failure(.protocolTooOld(daemon: response.protocol, client: Meshyy.protocolVersion))
        }

        let session = MeshyySession(size: TerminalSize(cols: cols, rows: rows))
        let transport = MeshyyTransport(session: session, sessionID: response.sessionID, name: name)
        transport.startPump()
        do {
            // A SHORT budget on purpose. This sits between the user tapping a server and
            // seeing a prompt, so a path that cannot work must fail fast and hand over
            // to SSH — the default 10s was most of the "slow to connect" report, spent
            // waiting for a connection that was never going to arrive.
            try await session.attach(bootstrap: response, sshHost: sshHost, timeout: .seconds(4))
        } catch {
            await transport.disconnect()
            return .failure(.connectFailed(error.localizedDescription))
        }
        return .success(transport)
    }

    /// Re-attaches an EXISTING transport over a new SSH connection.
    ///
    /// This is the method that makes the feature real, and its absence is why the
    /// first version did nothing it advertised. `MeshyySession` carries
    /// `consumedOffset` — how many bytes this client has actually drawn — and that is
    /// the ONLY durable state a resume needs. Building a fresh session per connect, as
    /// the first version did, reset it to zero every time, so every attach asked for a
    /// *fresh* screen and the daemon replayed nothing. The shell survived and the user
    /// saw none of what it had said.
    ///
    /// Keeping one session for the life of the terminal tab fixes that: the offset
    /// persists, the reattach asks to resume from it, and the daemon sends the bytes
    /// that were missed.
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
            try await session.attach(bootstrap: response, sshHost: sshHost)
        } catch {
            return .failure(.connectFailed(error.localizedDescription))
        }
        return .success(())
    }

    /// How many bytes this client has drawn. The resume point, exposed for diagnostics
    /// and so a test can prove the offset actually survives a reconnect.
    var consumedOffset: UInt64 {
        get async { await session.consumedOffset }
    }

    /// One ordered consumer of the session's events.
    ///
    /// `MeshyySession` guarantees arrival order is delivery order — it drains a single
    /// AsyncStream rather than spawning a task per frame, because tasks enqueued on an
    /// actor run in an unspecified order and would scramble PTY chunks. Preserving that
    /// property here means not fanning these out either.
    private func startPump() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.session.events {
                switch event {
                case .output(let bytes):
                    self.outputContinuation.yield(Data(bytes))
                case .screenRebuilt, .termios, .screenMode, .agent, .quickActions, .reconnecting:
                    // Not this type's business. Agent status already has a local
                    // detector in the app, and duplicating it from the wire would give
                    // two sources of truth for the same badge.
                    break
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

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await session.shutdown(reason: "the user closed the session")
        finish()
    }

    /// Detaches without ending the session, so the daemon keeps the shell running and
    /// the ring buffer filling. This is the difference that makes meshyy worth having:
    /// a suspended app that detaches can come back to output it never saw, where an
    /// SSH session that drops has lost it.
    func detach() async {
        await session.detach(reason: "the app was suspended")
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        outputContinuation.finish()
    }
}
