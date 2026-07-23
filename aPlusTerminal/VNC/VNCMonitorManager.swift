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

    /// Mirrors `SessionManager.pipKeepsProcessAlive` — wired at app init.
    @ObservationIgnored var pipKeepsProcessAlive: () -> Bool = { false }

    init(
        passwords: PasswordStore,
        makeConnection: ((Server) -> VNCConnecting)? = nil
    ) {
        self.passwords = passwords
        self.makeConnection = makeConnection ?? { server in
            RoyalVNCConnectionAdapter(server: server)
        }
    }

    @discardableResult
    func open(server: Server) -> VNCMonitorSession {
        if let existing = sessions.first(where: { $0.server.id == server.id && $0.state.isOpen }) {
            presented = existing
            return existing
        }
        let session = VNCMonitorSession(
            server: server,
            passwords: passwords,
            makeConnection: makeConnection
        )
        sessions.append(session)
        session.connect()
        presented = session
        return session
    }

    func close(_ session: VNCMonitorSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if presented === session {
            presented = nil
        }
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
