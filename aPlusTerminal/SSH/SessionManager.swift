import SwiftUI
import SwiftTerm
import Observation
import Citadel

enum SessionState: Equatable {
    case connecting
    case connected
    /// Socket closed (backgrounded too long, network drop, or connect
    /// failure). Reconnect is possible.
    case suspended
    case reconnecting
    case closed
}

/// One terminal session: owns the SSH connection, the persistent SwiftTerm
/// view (so scrollback survives leaving the screen), and the reconnect logic.
@MainActor
@Observable
final class TerminalSession: Identifiable, Hashable {
    nonisolated let id = UUID()

    nonisolated static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let startedAt = Date()
    private(set) var server: Server
    private(set) var state: SessionState = .connecting {
        didSet {
            guard oldValue != state else { return }
            onStateChange?()
            // Keepalive runs only while genuinely connected.
            if state == .connected { startKeepalive() } else { stopKeepalive() }
        }
    }
    private(set) var lastError: String?
    /// SessionManager hook for Live Activity updates (§4.5).
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Fired when the remote shell ends on its own (the user typed `exit`).
    @ObservationIgnored var onShellExit: (() -> Void)?

    let bridge = TerminalBridge()
    let terminalView = TerminalEmulatorView(frame: .zero)
    /// Claude Code working/waiting heuristic for the Live Activity (§4.5).
    let agentMonitor = AgentActivityMonitor()
    /// One-time `set -g mouse on` hint banner trigger (§4.3).
    var showTmuxMouseHint = false

    private(set) var connection = SSHConnection()
    private let keyStore: KeyStore
    private let serverStore: ServerStore
    private let passwords: PasswordStore
    private let settings: AppSettings
    private var io: SessionIO?
    private var scrollBridge: ScrollBridge?
    private var pumpTask: Task<Void, Never>?
    private var reconnectLoop: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// Idle SSH keepalive cadence. A foreground PTY with no typing produces no
    /// traffic, so NAT/router/server idle timeouts (often only a few minutes)
    /// silently drop the connection; we tick well under that. Citadel has no
    /// built-in keepalive, so this is app-level.
    static let keepaliveInterval: TimeInterval = 60
    private(set) var lastRequestedSize: (cols: Int, rows: Int)?

    /// Outbound writes (keystrokes, resizes) flow through one FIFO stream
    /// consumed by a single task. Spawning a Task per keystroke gives no
    /// ordering guarantee: fast typing transposes bytes, and the resize burst
    /// during the keyboard-show animation can land out of order, leaving the
    /// server painting an intermediate geometry — corrupted rendering that
    /// starts "the second you type".
    private enum Outbound {
        case data(Data)
        case resize(cols: Int, rows: Int)
    }

    private let outboxStream: AsyncStream<Outbound>
    private let outboxContinuation: AsyncStream<Outbound>.Continuation
    private var outboxTask: Task<Void, Never>?

    init(server: Server, keyStore: KeyStore, serverStore: ServerStore, passwords: PasswordStore, settings: AppSettings) {
        self.server = server
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.passwords = passwords
        self.settings = settings
        (outboxStream, outboxContinuation) = AsyncStream.makeStream(of: Outbound.self)
        startOutbox()

        let io = SessionIO(session: self)
        self.io = io
        terminalView.terminalDelegate = io
        terminalView.inputAccessoryView = nil
        terminalView.interceptInsert = { [weak bridge] text in
            bridge?.handleInsert(text) ?? false
        }
        bridge.terminalView = terminalView
        bridge.sendData = { [weak self] data in
            self?.sendInput(data)
        }

        let scrollBridge = ScrollBridge(
            sendData: { [weak self] data in self?.sendInput(data) },
            wheelBridgeEnabled: { [weak settings] in settings?.scrollWheelBridge ?? true }
        )
        scrollBridge.onModeBTriggered = { [weak self] in
            guard let self, !self.settings.tmuxMouseHintShown else { return }
            self.settings.tmuxMouseHintShown = true
            self.showTmuxMouseHint = true
        }
        scrollBridge.attach(to: terminalView)
        self.scrollBridge = scrollBridge
    }

    func sendInput(_ data: Data) {
        outboxContinuation.yield(.data(data))
    }

    func resize(cols: Int, rows: Int) {
        // Remember the size even when not connected yet — the PTY may open
        // before the view lays out, and a dropped resize leaves the server
        // rendering 80 columns into a phone-width screen (wrapped/doubled
        // text). `syncWindowSize` replays this after every (re)connect.
        lastRequestedSize = (cols, rows)
        outboxContinuation.yield(.resize(cols: cols, rows: rows))
    }

    /// Initial connection; also the retry path for a failed first connect.
    func connect() async {
        guard state == .connecting || state == .suspended else { return }
        state = .connecting
        await attemptLoop(maxAttempts: 1)
    }

    /// Reconnect contract (§4.1): exponential backoff 0.5s → 1s → 2s.
    /// Single-flight: a dropped channel, the foreground handler, and the retry
    /// button can all request a reconnect around the same moment — running two
    /// loops opens two PTYs that paint over each other on one screen.
    func reconnect(maxAttempts: Int = 3) async {
        guard state == .suspended || state == .reconnecting else { return }
        if let reconnectLoop {
            await reconnectLoop.value
            return
        }
        state = .reconnecting
        let loop = Task { await attemptLoop(maxAttempts: maxAttempts) }
        reconnectLoop = loop
        await loop.value
        reconnectLoop = nil
    }

    /// Cleanly close the socket while backgrounded; tmux survives.
    func suspend() async {
        guard state == .connected else { return }
        pumpTask?.cancel()
        pumpTask = nil
        await connection.disconnect()
        agentMonitor.reset()
        state = .suspended
    }

    /// Record which tmux session this PTY is attached to, for auto-reattach.
    func recordTmuxTarget() async {
        guard state == .connected else { return }
        guard let target = await TmuxIntegration.currentTarget(on: connection) else { return }
        server.lastTmuxTarget = target
        serverStore.update(server)
    }

    /// Periodic SSH keepalive + tmux-target refresh while connected. Running
    /// `tmux list-sessions` on a side channel generates traffic that resets the
    /// connection's NAT/idle timer (so an idle foreground session doesn't drop
    /// after a few minutes) AND keeps `lastTmuxTarget` current, so any later
    /// reconnect reattaches to the live tmux session instead of dropping into a
    /// fresh login shell. Recording must happen *while still attached* — once the
    /// socket drops, tmux reads the session as detached and it can't be identified.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        let interval = Self.keepaliveInterval
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.state == .connected else { return }
                await self.recordTmuxTarget()
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    func close() async {
        pumpTask?.cancel()
        pumpTask = nil
        outboxTask?.cancel()
        outboxContinuation.finish()
        agentMonitor.reset()
        state = .closed
        await connection.disconnect()
    }

    private func attemptLoop(maxAttempts: Int) async {
        var delay = 0.5
        for attempt in 1...max(1, maxAttempts) {
            do {
                try await establish()
                state = .connected
                lastError = nil
                // Make the PTY match the on-screen size before anything
                // (especially tmux attach) draws into it.
                await syncWindowSize()
                if settings.autoReattachTmux, let target = server.lastTmuxTarget {
                    try? await connection.send(TmuxIntegration.attachCommand(target: target))
                }
                return
            } catch {
                lastError = error.localizedDescription
                if case SSHConnectionError.hostKeyMismatch = error {
                    break  // MITM warning — never retry past it silently
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 2.0)
                }
            }
        }
        state = .suspended
    }

    private func establish() async throws {
        let auth: SSHConnection.AuthMethod
        if let keyID = server.keyID, let privateKey = try? keyStore.privateKey(for: keyID) {
            auth = .privateKey(privateKey)
        } else if let ref = server.passwordRef, let password = passwords.password(for: ref) {
            auth = .password(password)
        } else {
            throw SessionError.noCredentials
        }
        pumpTask?.cancel()
        await connection.disconnect()

        let fresh = SSHConnection()
        let size = currentWindowSize()
        try await fresh.connect(SSHConnection.Configuration(
            host: server.host,
            port: server.port,
            username: server.username,
            auth: auth,
            knownHostKey: server.knownHostKey,
            cols: size.cols,
            rows: size.rows
        ))
        connection = fresh
        // Clear whatever the dead PTY left on screen before the new shell and
        // tmux attach repaint — otherwise old and new frames overlay.
        terminalView.getTerminal().resetToInitialState()

        if server.knownHostKey == nil, let presented = await fresh.serverHostKey {
            // TOFU: pin what the server presented on first contact.
            server.knownHostKey = presented
            serverStore.update(server)
        }
        // Re-arm agent detection from a clean slate: a reconnect — or a tmux
        // reattach to a different window — must not inherit the previous
        // shell's working/waiting reading.
        agentMonitor.reset()
        startPump(reading: fresh)
    }

    /// Best-known terminal dimensions: what the layout last reported, falling
    /// back to the emulator's current grid.
    private func currentWindowSize() -> (cols: Int, rows: Int) {
        if let lastRequestedSize {
            return (max(2, lastRequestedSize.cols), max(2, lastRequestedSize.rows))
        }
        let terminal = terminalView.getTerminal()
        return (max(2, terminal.cols), max(2, terminal.rows))
    }

    /// Replays the real window size after connecting (§4.2 SIGWINCH contract).
    private func syncWindowSize() async {
        let size = currentWindowSize()
        try? await connection.resize(cols: size.cols, rows: size.rows)
    }

    /// Single consumer for all outbound traffic — strict FIFO per session,
    /// always targeting the current connection.
    private func startOutbox() {
        outboxTask = Task { [weak self] in
            guard let self else { return }
            for await item in self.outboxStream {
                guard !Task.isCancelled else { return }
                let connection = self.connection
                switch item {
                case .data(let data):
                    try? await connection.send(data)
                case .resize(let cols, let rows):
                    try? await connection.resize(cols: cols, rows: rows)
                }
            }
        }
    }

    private func startPump(reading connection: SSHConnection) {
        pumpTask = Task { [weak self] in
            for await chunk in await connection.output {
                guard let self, !Task.isCancelled else { return }
                let bytes = [UInt8](chunk)
                self.terminalView.feed(byteArray: ArraySlice(bytes))
                self.agentMonitor.observe(bytes)
            }
            guard let self, !Task.isCancelled else { return }
            self.channelEnded(connection)
        }
    }

    /// The PTY ended without the user closing the session. A transport error
    /// means a drop — retry patiently enough to ride out a Wi-Fi blip (§4.1).
    /// A clean end means the remote shell exited (`exit`): close the session
    /// like a terminal should, instead of resurrecting the connection.
    private func channelEnded(_ endedConnection: SSHConnection) {
        guard state == .connected else { return }
        Task {
            var transportError: Error?
            if case .disconnected(let error) = await endedConnection.state {
                transportError = error
            }
            // A non-zero shell exit surfaces as CommandFailed — still `exit`.
            if let transportError, !(transportError is SSHClient.CommandFailed) {
                state = .reconnecting
                await reconnect(maxAttempts: 10)
            } else {
                state = .closed
                onShellExit?()
            }
        }
    }

    enum SessionError: LocalizedError {
        case noCredentials

        var errorDescription: String? {
            "No credentials are set for this server. Edit the server and pick a key or set a password."
        }
    }
}

/// Strongly-held TerminalViewDelegate (SwiftTerm keeps it weak). SwiftTerm
/// calls these on the main thread.
private final class SessionIO: TerminalViewDelegate {
    weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let payload = Data(data)
        MainActor.assumeIsolated { session?.sendInput(payload) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { session?.resize(cols: newCols, rows: newRows) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            UIPasteboard.general.string = text
        }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Registry of live sessions plus the app-lifecycle choreography: background
/// grace window, clean suspend, foreground reconnect (§4.1).
@MainActor
@Observable
final class SessionManager {
    private(set) var sessions: [TerminalSession] = []

    private let keyStore: KeyStore
    private let serverStore: ServerStore
    private let passwords: PasswordStore
    private let settings: AppSettings
    private let activityController = SessionActivityController()
    private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(keyStore: KeyStore, serverStore: ServerStore, passwords: PasswordStore, settings: AppSettings) {
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.passwords = passwords
        self.settings = settings
        // A surviving Live Activity from a previous launch must reflect this
        // process's truth (no sessions yet) instead of stale ones (§4.5).
        refreshActivity()
    }

    @discardableResult
    func open(server: Server) -> TerminalSession {
        let session = TerminalSession(
            server: server,
            keyStore: keyStore,
            serverStore: serverStore,
            passwords: passwords,
            settings: settings
        )
        session.onStateChange = { [weak self] in
            self?.refreshActivity()
        }
        session.agentMonitor.onChange = { [weak self] in
            self?.refreshActivity()
        }
        session.onShellExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessions.removeAll { $0.id == session.id }
            self.refreshActivity()
        }
        sessions.append(session)
        Task { await session.connect() }
        refreshActivity()
        return session
    }

    func close(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
        Task { await session.close() }
        refreshActivity()
    }

    func closeAll() {
        let closing = sessions
        sessions.removeAll()
        for session in closing {
            Task { await session.close() }
        }
        refreshActivity()
    }

    /// Live Activity mirror of the session list (§4.5).
    private func refreshActivity() {
        let summaries = sessions
            // A `.closed` session is on its way out of `sessions` this same
            // tick (onShellExit / close remove it); don't let it flicker into
            // the count.
            .filter { $0.state != .closed }
            .map { session -> SessionActivityAttributes.SessionSummary in
                let stateString: String = {
                    switch session.state {
                    case .connected: return "connected"
                    case .connecting: return "connecting"
                    case .reconnecting: return "reconnecting"
                    case .suspended: return "suspended"
                    case .closed: return "closed"
                    }
                }()
                let monitorStatus = session.agentMonitor.status == .none
                    ? nil
                    : session.agentMonitor.status.rawValue
                return SessionActivityAttributes.SessionSummary(
                    id: session.id,
                    name: session.server.name,
                    host: session.server.host,
                    state: stateString,
                    startedAt: session.startedAt,
                    // Never surface a stale agent label on a session that
                    // isn't currently connected.
                    agentStatus: SessionActivityAttributes.resolvedAgentStatus(
                        sessionState: stateString,
                        monitorStatus: monitorStatus
                    )
                )
            }
        activityController.update(with: summaries)
    }

    func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Keep sockets alive ~25s for quick app switches; record tmux targets,
    /// then close cleanly. tmux survives the disconnect.
    func appDidEnterBackground() {
        guard sessions.contains(where: { $0.state == .connected }) else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "aplusterminal.session-grace") { [weak self] in
            self?.finishGrace()
        }
        graceTask = Task { [weak self] in
            guard let self else { return }
            for session in self.sessions where session.state == .connected {
                await session.recordTmuxTarget()
            }
            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled else { return }
            self.finishGrace()
        }
    }

    func appWillEnterForeground() {
        // Back within the grace window: sockets are still open, nothing to do.
        graceTask?.cancel()
        graceTask = nil
        endBackgroundTask()
        // Push the Activity's stale horizon out — content only goes stale
        // when the process is killed or frozen long enough to stop updating.
        refreshActivity()
        for session in sessions where session.state == .suspended {
            Task { await session.reconnect() }
        }
    }

    private func finishGrace() {
        graceTask?.cancel()
        graceTask = nil
        Task { [weak self] in
            guard let self else { return }
            for session in self.sessions where session.state == .connected {
                await session.suspend()
            }
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
