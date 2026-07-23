import Foundation
import Observation
import UIKit

/// App-scoped facade over the PiP engine. Owns lazy construction (the engine
/// exists only while "Pop-Out Sessions" is ON and the device supports PiP),
/// binds terminal sessions to the shared engine, and routes pop-out restore
/// taps back to the owning session's screen.
@MainActor
@Observable
final class PiPCoordinator {
    static var isSupported: Bool { PiPEngine.isSupported }

    private let settings: AppSettings
    @ObservationIgnored private var engine: PiPEngine?
    @ObservationIgnored private weak var boundSession: TerminalSession?

    /// Mirrors the engine for SwiftUI/SessionManager reads.
    private(set) var isActive = false

    /// Present session X's screen (wired to the deep-link router at app init).
    @ObservationIgnored var onRestore: ((UUID) -> Void)?
    /// PiP ended while the app was backgrounded: nothing keeps the process
    /// alive anymore, so the normal background wind-down must run now
    /// (wired to SessionManager at app init).
    @ObservationIgnored var onStoppedInBackground: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Feature gate for the toolbar button and screen arming: supported
    /// hardware AND the beta master toggle.
    var isAvailable: Bool { Self.isSupported && settings.popOutSessions }

    /// The toolbar tap: bind the session and start the pop-out.
    func popOut(_ session: TerminalSession) {
        guard isAvailable else { return }
        bind(session)
        engine?.start()
    }

    /// A session screen came on screen. With auto pop-out enabled the engine
    /// arms now, so the system can start PiP by itself on app switch.
    func sessionScreenAppeared(_ session: TerminalSession) {
        guard isAvailable, settings.autoPopOutOnAppSwitch else { return }
        bind(session)
    }

    /// The session screen left. Disarm unless the pop-out is live (leaving
    /// via the app switcher with PiP up must not tear the surface down).
    func sessionScreenDisappeared(_ session: TerminalSession) {
        guard boundSession === session, !isActive else { return }
        engine?.disarm()
        boundSession = nil
    }

    /// Master toggle turned off: release every AVKit object so no engine,
    /// layer, or audio-session behavior remains observable.
    func masterToggleTurnedOff() {
        engine?.invalidate()
        engine = nil
        boundSession = nil
        isActive = false
    }

    private func bind(_ session: TerminalSession) {
        let engine = ensureEngine()
        if boundSession !== session || engine.source == nil {
            let source = TerminalPiPFrameSource(
                terminalView: session.terminalView,
                sessionID: session.id,
                title: { [weak session] in session?.server.name ?? "Session" },
                chip: { [weak session] in
                    guard let session else { return .disconnected }
                    return .from(state: session.state, agentStatus: session.agentMonitor.status)
                }
            )
            // `pipInvalidate` is the session's single PiP slot (SessionManager
            // multicasts output/state/agent events into it) — hooked here,
            // unhooked when the engine drops the source.
            session.pipInvalidate = { [weak source] in source?.onInvalidate?() }
            source.onDetach = { [weak session] in session?.pipInvalidate = nil }
            boundSession = session
            engine.arm(source: source, autoStartOnAppSwitch: settings.autoPopOutOnAppSwitch)
        } else {
            engine.arm(source: engine.source!, autoStartOnAppSwitch: settings.autoPopOutOnAppSwitch)
        }
    }

    private func ensureEngine() -> PiPEngine {
        if let engine { return engine }
        let engine = PiPEngine()
        engine.onActiveChanged = { [weak self] active in
            guard let self else { return }
            self.isActive = active
            if !active, UIApplication.shared.applicationState == .background {
                self.onStoppedInBackground?()
            }
        }
        engine.onRestore = { [weak self] sessionID in
            self?.onRestore?(sessionID)
        }
        self.engine = engine
        return engine
    }
}
