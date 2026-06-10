import SwiftUI
import SwiftTerm
import Observation

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
        didSet { if oldValue != state { onStateChange?() } }
    }
    private(set) var lastError: String?
    /// SessionManager hook for Live Activity updates (§4.5).
    @ObservationIgnored var onStateChange: (() -> Void)?

    let bridge = TerminalBridge()
    let terminalView = RelayTerminalView(frame: .zero)
    /// One-time `set -g mouse on` hint banner trigger (§4.3).
    var showTmuxMouseHint = false

    private(set) var connection = SSHConnection()
    private let keyStore: KeyStore
    private let serverStore: ServerStore
    private let settings: AppSettings
    private var io: SessionIO?
    private var scrollBridge: ScrollBridge?
    private var pumpTask: Task<Void, Never>?
    private(set) var lastRequestedSize: (cols: Int, rows: Int)?

    init(server: Server, keyStore: KeyStore, serverStore: ServerStore, settings: AppSettings) {
        self.server = server
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.settings = settings

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
        let connection = connection
        Task { try? await connection.send(data) }
    }

    func resize(cols: Int, rows: Int) {
        // Remember the size even when not connected yet — the PTY may open
        // before the view lays out, and a dropped resize leaves the server
        // rendering 80 columns into a phone-width screen (wrapped/doubled
        // text). `syncWindowSize` replays this after every (re)connect.
        lastRequestedSize = (cols, rows)
        let connection = connection
        Task { try? await connection.resize(cols: cols, rows: rows) }
    }

    /// Initial connection; also the retry path for a failed first connect.
    func connect() async {
        guard state == .connecting || state == .suspended else { return }
        state = .connecting
        await attemptLoop(maxAttempts: 1)
    }

    /// Reconnect contract (§4.1): exponential backoff 0.5s → 1s → 2s.
    func reconnect(maxAttempts: Int = 3) async {
        guard state == .suspended || state == .reconnecting else { return }
        state = .reconnecting
        await attemptLoop(maxAttempts: maxAttempts)
    }

    /// Cleanly close the socket while backgrounded; tmux survives.
    func suspend() async {
        guard state == .connected else { return }
        pumpTask?.cancel()
        pumpTask = nil
        await connection.disconnect()
        state = .suspended
    }

    /// Record which tmux session this PTY is attached to, for auto-reattach.
    func recordTmuxTarget() async {
        guard state == .connected else { return }
        guard let target = await TmuxIntegration.currentTarget(on: connection) else { return }
        server.lastTmuxTarget = target
        serverStore.update(server)
    }

    func close() async {
        pumpTask?.cancel()
        pumpTask = nil
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
        guard let keyID = server.keyID, let privateKey = try? keyStore.privateKey(for: keyID) else {
            throw SessionError.noKeyAssigned
        }
        pumpTask?.cancel()
        await connection.disconnect()

        let fresh = SSHConnection()
        let size = currentWindowSize()
        try await fresh.connect(SSHConnection.Configuration(
            host: server.host,
            port: server.port,
            username: server.username,
            privateKey: privateKey,
            knownHostKey: server.knownHostKey,
            cols: size.cols,
            rows: size.rows
        ))
        connection = fresh

        if server.knownHostKey == nil, let presented = await fresh.serverHostKey {
            // TOFU: pin what the server presented on first contact.
            server.knownHostKey = presented
            serverStore.update(server)
        }
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

    private func startPump(reading connection: SSHConnection) {
        pumpTask = Task { [weak self] in
            for await chunk in await connection.output {
                guard let self, !Task.isCancelled else { return }
                self.terminalView.feed(byteArray: ArraySlice([UInt8](chunk)))
            }
            guard let self, !Task.isCancelled else { return }
            self.channelDropped()
        }
    }

    /// The PTY ended without the user asking — network drop or remote exit.
    /// Retry patiently enough to ride out a Wi-Fi blip (§4.1 acceptance).
    private func channelDropped() {
        guard state == .connected else { return }
        state = .reconnecting
        Task { await reconnect(maxAttempts: 10) }
    }

    enum SessionError: LocalizedError {
        case noKeyAssigned

        var errorDescription: String? {
            "No key is assigned to this server. Edit the server and pick or generate a key, then add its public key to the server's authorized_keys."
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
    private let settings: AppSettings
    private let activityController = SessionActivityController()
    private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(keyStore: KeyStore, serverStore: ServerStore, settings: AppSettings) {
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.settings = settings
    }

    @discardableResult
    func open(server: Server) -> TerminalSession {
        let session = TerminalSession(
            server: server,
            keyStore: keyStore,
            serverStore: serverStore,
            settings: settings
        )
        session.onStateChange = { [weak self] in
            self?.refreshActivity()
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
        let summaries = sessions.map { session in
            SessionActivityAttributes.SessionSummary(
                id: session.id,
                name: session.server.name,
                host: session.server.host,
                state: {
                    switch session.state {
                    case .connected: return "connected"
                    case .connecting: return "connecting"
                    case .reconnecting: return "reconnecting"
                    case .suspended: return "suspended"
                    case .closed: return "closed"
                    }
                }(),
                startedAt: session.startedAt
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
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "relay.session-grace") { [weak self] in
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
