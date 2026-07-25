import Foundation
import Observation
import UIKit

/// Registry of open VNC monitor sessions plus their app-lifecycle
/// choreography, mirroring SessionManager's contract in miniature: on
/// backgrounding without a live pop-out the monitors disconnect cleanly
/// (VNC has no reattach concept — the user reconnects with one tap), and
/// foregrounding never auto-reconnects.
@MainActor
@Observable
final class VNCMonitorManager {
    private(set) var sessions: [VNCMonitorSession] = []
    /// The monitor currently presented full-screen (fullScreenCover item).
    var presented: VNCMonitorSession?

    private let passwords: PasswordStore
    private let makeConnection: (Server) -> VNCConnecting
    /// Resolves the linked SSH server + builds the cursor bridge; seams for
    /// tests. Nil resolver disables bridging entirely.
    private let resolveServer: (UUID) -> Server?
    /// All saved SSH servers (for auto-matching a cursor bridge by host).
    private let sshServers: () -> [Server]
    private let makeBridge: (Server) -> VNCCursorBridge

    /// Mirrors `SessionManager.pipKeepsProcessAlive` — wired at app init.
    @ObservationIgnored var pipKeepsProcessAlive: () -> Bool = { false }

    init(
        passwords: PasswordStore,
        keyStore: KeyStore? = nil,
        serverStore: ServerStore? = nil,
        makeConnection: ((Server) -> VNCConnecting)? = nil,
        makeBridge: ((Server) -> VNCCursorBridge)? = nil,
        sshServers: (() -> [Server])? = nil
    ) {
        self.passwords = passwords
        self.makeConnection = makeConnection ?? { server in
            RoyalVNCConnectionAdapter(server: server)
        }
        self.resolveServer = { [weak serverStore] id in serverStore?.server(for: id) }
        self.sshServers = sshServers ?? { [weak serverStore] in
            (serverStore?.servers ?? []).filter { $0.kind == .ssh }
        }
        self.makeBridge = makeBridge ?? { [weak keyStore] sshServer in
            guard let keyStore else {
                return VNCCursorBridge { AsyncThrowingStream { $0.finish() } }
            }
            return VNCCursorBridge.forLinkedServer(sshServer, keyStore: keyStore, passwords: passwords)
        }
    }

    /// The SSH server to drive the cursor bridge for this monitor: an
    /// explicit link if set and still valid, otherwise a saved SSH server on
    /// the SAME host (so the physical-mouse cursor "just works" for anyone
    /// who already has the machine saved as an SSH server). `cursorBridge...`
    /// resolving to a deleted/None entry disables the bridge deliberately.
    func cursorBridgeServer(for monitor: Server) -> Server? {
        if let linkID = monitor.cursorBridgeSSHServerID {
            let linked = resolveServer(linkID)
            return (linked?.kind == .ssh) ? linked : nil
        }
        let host = monitor.host.lowercased()
        return sshServers().first { ssh in
            ssh.connectionCandidates.contains { $0.lowercased() == host }
                || monitor.connectionCandidates.contains { $0.lowercased() == ssh.host.lowercased() }
        }
    }

    @discardableResult
    func open(server: Server) -> VNCMonitorSession {
        // Reuse an open monitor only when its captured config is byte-for-byte
        // the saved one — an edited host/port/username must NOT re-present a
        // stale session whose Retry would reconnect with the old values.
        if let existing = sessions.first(where: { $0.server.id == server.id && $0.state.isOpen }) {
            if existing.server == server {
                presented = existing
                return existing
            }
            close(existing)
        }
        let session = VNCMonitorSession(
            server: server,
            passwords: passwords,
            makeConnection: makeConnection
        )
        // Cursor bridge: an explicitly linked OR host-matched saved SSH
        // server streams the real pointer position (macOS reports none). The
        // session starts/stops it with its state.
        if let sshServer = cursorBridgeServer(for: server) {
            session.cursorBridge = makeBridge(sshServer)
        }
        sessions.append(session)
        session.connect()
        presented = session
        return session
    }

    /// Wired at app init: a closing session must also end any pop-out that
    /// is mirroring it (a dead session's PiP window would otherwise linger).
    @ObservationIgnored var pipSessionClosed: ((VNCMonitorSession) -> Void)?

    func close(_ session: VNCMonitorSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if presented === session {
            presented = nil
        }
        pipSessionClosed?(session)
    }

    func session(for id: UUID) -> VNCMonitorSession? {
        sessions.first { $0.id == id }
    }

    private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Backgrounded: hold the monitors open briefly (auto-pop-out engages a
    /// beat after backgrounding), then disconnect cleanly under a background
    /// task so iOS never freezes us with sockets half-open. A live pop-out
    /// keeps everything running instead.
    func appDidEnterBackground() {
        guard sessions.contains(where: { $0.state.isActiveConnection }) else { return }
        guard !pipKeepsProcessAlive() else { return }
        // A grace cycle is already in flight (re-entry via the PiP-stopped
        // path) — starting a second one would overwrite and leak the task.
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "aplusterminal.vnc-grace") { [weak self] in
            // Expiration last resort: disconnect() is non-blocking, safe here.
            self?.suspendAllNow()
        }
        graceTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(0.5))
                guard let self, !Task.isCancelled else { return }
                if self.pipKeepsProcessAlive() {
                    self.endBackgroundTask()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.suspendAllNow()
        }
    }

    func appWillEnterForeground() {
        graceTask?.cancel()
        graceTask = nil
        endBackgroundTask()
        // Deliberately no auto-reconnect (same contract as SSH sessions).
    }

    private func suspendAllNow() {
        graceTask?.cancel()
        graceTask = nil
        for session in sessions {
            session.suspend()
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
