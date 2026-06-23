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
    /// Agent working/waiting heuristic for the Live Activity (§4.5). Built from
    /// the resolved agent candidates — never names an agent in code.
    let agentMonitor: AgentActivityMonitor
    /// One-time "enable mouse" hint banner trigger (§4.3).
    var showMultiplexerHint = false

    private(set) var connection = SSHConnection()
    private let keyStore: KeyStore
    private let serverStore: ServerStore
    private let passwords: PasswordStore
    private let settings: AppSettings
    private let profiles: ProfileStore
    private var io: SessionIO?
    private var scrollBridge: ScrollBridge?
    private var pumpTask: Task<Void, Never>?
    private var reconnectLoop: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// Idle keepalive cadence. A foreground PTY with no typing produces no
    /// traffic, so NAT/router idle timeouts AND the server's sshd ClientAlive
    /// check (often only a few minutes) silently drop the connection; we tick
    /// well under that. Citadel exposes no protocol-level keepalive, so this is
    /// app-level — and the liveness ping rides the *existing* PTY channel (a
    /// no-op window-change) rather than a separate exec channel. A separate
    /// exec channel can be server-restricted and, per build-5 on-device
    /// evidence, did not hold the link; the PTY channel is the one the user is
    /// already typing on, so a packet on it is guaranteed to traverse the wire.
    static let defaultKeepaliveInterval: TimeInterval = 25
    /// First tick fires fast so the link is held through the initial idle
    /// window AND `lastMultiplexerTarget` is recorded early — a drop within the
    /// first minute must still reattach to the live session.
    static let defaultFirstKeepaliveDelay: TimeInterval = 10
    /// Overridable in tests for fast, deterministic keepalive assertions.
    var keepaliveInterval = TerminalSession.defaultKeepaliveInterval
    var firstKeepaliveDelay = TerminalSession.defaultFirstKeepaliveDelay
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

    init(server: Server, keyStore: KeyStore, serverStore: ServerStore, passwords: PasswordStore, settings: AppSettings, profiles: ProfileStore) {
        self.server = server
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.passwords = passwords
        self.settings = settings
        self.profiles = profiles
        self.agentMonitor = AgentActivityMonitor(
            candidates: Self.resolveAgentCandidates(server: server, settings: settings, profiles: profiles)
        )
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
            guard let self, !self.settings.multiplexerHintShown,
                  // Only multiplexers that advertise a mouse-hint command (tmux)
                  // show the banner; zellij/screen/none stay silent.
                  self.resolvedMultiplexer.mouseHintCommand != nil else { return }
            self.settings.multiplexerHintShown = true
            self.showMultiplexerHint = true
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

    // MARK: - Attachments (image or file)

    enum AttachmentKind { case image, file }
    /// Drives the transient "Uploading…" indicator in the terminal screen.
    private(set) var isAttaching = false

    /// Uploads a picked image or file to the remote inbox over SFTP (the
    /// existing authenticated session, nowhere else), then types the absolute
    /// remote path — plus a trailing space, no Enter — into the PTY so the user
    /// can wrap it for whichever agent they run. Agent-agnostic by design.
    func attach(_ raw: Data, suggestedName: String, kind: AttachmentKind) async {
        guard state == .connected else { return }
        isAttaching = true
        defer { isAttaching = false }
        do {
            let payload: Data
            let name: String
            switch kind {
            case .image:
                let (data, ext) = ImageNormalizer.normalize(
                    raw, sourceExt: (suggestedName as NSString).pathExtension
                )
                payload = data
                name = "img-\(Self.stamp())-\(Self.shortID()).\(ext)"
            case .file:
                payload = raw
                name = "\(Self.shortID())-\(Self.sanitize(suggestedName))"
            }
            let path = try await connection.uploadToInbox(payload, filename: name)
            // Insert using the resolved agent's template (aider → `/add {path}\n`,
            // everyone else → bare path + space). Ordered via the FIFO outbox.
            let insertion = resolvedAttachAgent?.formatAttachment(path: path)
                ?? Self.formatAttachment(path: path)
            sendInput(Data(insertion.utf8))
        } catch {
            lastError = "Attachment failed: \(error.localizedDescription)"
        }
    }

    /// Default agent-agnostic insertion: bare path + trailing space, no newline.
    static func formatAttachment(path: String) -> String { "\(path) " }

    /// Collapses anything outside a safe, space-free set to `_` so the inserted
    /// path never needs shell quoting; preserves the extension.
    static func sanitize(_ name: String) -> String {
        let ok = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = String(name.map { ok.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "file" : cleaned
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func shortID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    // MARK: - Profile resolution (per-server override → global default)

    /// Agent candidates fed to the monitor. "auto" → every profile (generic
    /// fallback included); a specific id → just that profile; "none"/unknown
    /// "none" → empty (detection disabled).
    static func resolveAgentCandidates(server: Server, settings: AppSettings, profiles: ProfileStore) -> [AgentProfile] {
        let id = server.agentProfileID ?? settings.defaultAgentProfileID
        switch id {
        case "auto": return profiles.agents
        case "none": return []
        default:
            if let profile = profiles.agent(id: id) { return [profile] }
            return profiles.agents  // unknown id behaves like auto rather than going dark
        }
    }

    /// The multiplexer profile for this session (per-server → default → `none`).
    var resolvedMultiplexer: MultiplexerProfile {
        let id = server.multiplexerProfileID ?? settings.defaultMultiplexerProfileID
        return profiles.multiplexer(id: id)
            ?? profiles.multiplexer(id: "none")
            ?? MultiplexerProfile(id: "none", displayName: "None (raw shell)")
    }

    /// The agent whose attach template to use: in "auto" mode, whichever one was
    /// detected (nil → default template); otherwise the explicitly chosen one.
    private var resolvedAttachAgent: AgentProfile? {
        let id = server.agentProfileID ?? settings.defaultAgentProfileID
        if id == "auto" { return agentMonitor.detected }
        return profiles.agent(id: id)
    }

    /// How a (re)connect should resume the multiplexer.
    enum ReattachIntent {
        case auto              // best-guess, if auto-reattach is on (drop/foreground/retry)
        case session(String)   // attach this exact session (explicit pick)
        case freshShell        // no attach
        case choose            // query live sessions, then attach one / offer a fresh picker
    }

    /// Initial connection for a freshly-opened session: always a fresh shell,
    /// never an auto-reattach. Opening a server is "give me a new terminal";
    /// reattaching is for *resuming* after a drop (the reconnect paths), not for
    /// a deliberate new session. (Otherwise every new session lands in the last
    /// tmux — the "it booted me into session 1/12" bug.)
    func connect() async {
        guard state == .connecting || state == .suspended else { return }
        state = .connecting
        await attemptLoop(maxAttempts: 1, intent: .freshShell)
    }

    /// Reconnect contract (§4.1): exponential backoff 0.5s → 1s → 2s.
    /// Single-flight: a dropped channel, the foreground handler, and the retry
    /// button can all request a reconnect around the same moment — running two
    /// loops opens two PTYs that paint over each other on one screen.
    /// Uses the default attach behavior (auto-reattach the best-guess session if
    /// enabled). Used by the drop/foreground/retry paths.
    func reconnect(maxAttempts: Int = 3) async {
        await reconnect(intent: .auto, maxAttempts: maxAttempts)
    }

    /// Reconnect and attach to a *specific* session (or `nil` for a fresh
    /// shell). Used for explicit picks made over a live list.
    func reconnect(attachTo session: String?, maxAttempts: Int = 3) async {
        await reconnect(intent: session.map(ReattachIntent.session) ?? .freshShell, maxAttempts: maxAttempts)
    }

    /// Reconnect, then decide from the *live* session list: attach the only one,
    /// or surface a fresh picker if several exist. The paused card's "Reconnect"
    /// uses this so the choices are never stale (a session closed since the drop
    /// won't appear). Honors the "Auto-reattach multiplexer" master switch — when
    /// it's off, reconnecting lands in a fresh shell and never reattaches.
    func reconnectChoosingSession(maxAttempts: Int = 3) async {
        await reconnect(intent: reattachEnabled ? .choose : .freshShell, maxAttempts: maxAttempts)
    }

    /// The "Auto-reattach multiplexer" setting: the master on/off for the whole
    /// reattach feature (auto on connect/drop AND the paused-card picker).
    var reattachEnabled: Bool { settings.autoReattachMultiplexer }

    /// Count of reconnect runs actually started — a deterministic test seam so
    /// "must not auto-reconnect" assertions don't depend on a fixed sleep.
    private(set) var reconnectAttempts = 0

    private func reconnect(intent: ReattachIntent, maxAttempts: Int) async {
        guard state == .suspended || state == .reconnecting else { return }
        if let reconnectLoop {
            await reconnectLoop.value
            return
        }
        reconnectAttempts += 1
        state = .reconnecting
        let loop = Task { await attemptLoop(maxAttempts: maxAttempts, intent: intent) }
        reconnectLoop = loop
        await loop.value
        reconnectLoop = nil
    }

    /// The best-guess multiplexer session to reattach to — nil when none is
    /// recorded or the active profile can't attach (e.g. the `none` profile).
    var reattachTarget: String? {
        guard let target = server.lastMultiplexerTarget,
              resolvedMultiplexer.attachCommand(target: target) != nil else { return nil }
        return target
    }

    /// Set while connected when several live sessions exist and the user must
    /// pick which to reattach — drives the picker overlay. Always reflects a
    /// fresh `availableSessions` query (no stale entries).
    var reattachChoicePending = false

    /// Attach to a user-picked session over the already-open connection.
    func attachToChosen(_ session: String) {
        reattachChoicePending = false
        guard state == .connected,
              let attach = MultiplexerController.attachCommand(resolvedMultiplexer, target: session) else { return }
        sendInput(Data(attach.utf8))
    }

    /// Dismiss the picker and stay in the plain shell.
    func dismissReattachChoice() { reattachChoicePending = false }

    /// Cleanly close the socket while backgrounded; tmux survives.
    func suspend() async {
        guard state == .connected else { return }
        pumpTask?.cancel()
        pumpTask = nil
        await connection.disconnect()
        agentMonitor.reset()
        state = .suspended
    }

    /// All sessions available to reattach, captured live so the paused card can
    /// offer a picker (we can't query once the socket is gone). Empty for
    /// profiles that can't list/attach (e.g. `none`).
    private(set) var availableSessions: [String] = []

    /// Record the multiplexer session this PTY is attached to (best-guess
    /// auto-reattach target) plus the full session list for the picker. No-op
    /// for the `none` profile.
    private var recordTask: Task<Void, Never>?

    func recordMultiplexerTarget() async {
        // Single-flight (like reconnect): the keepalive tick and the
        // background-grace task can both call this, and each has `await`
        // suspension points where their read-modify-write of `server` would
        // otherwise interleave. Coalesce concurrent callers onto one run.
        if let recordTask {
            await recordTask.value
            return
        }
        let task = Task { await self.performRecordMultiplexerTarget() }
        recordTask = task
        await task.value
        recordTask = nil
    }

    private func performRecordMultiplexerTarget() async {
        guard state == .connected else { return }
        availableSessions = await MultiplexerController.availableSessions(resolvedMultiplexer, on: connection)
        guard let target = await MultiplexerController.currentTarget(resolvedMultiplexer, on: connection) else { return }
        server.lastMultiplexerTarget = target
        serverStore.update(server)
    }

    /// Periodic keepalive + multiplexer-target refresh while connected. The
    /// liveness ping is a no-op window-change on the live PTY channel (see the
    /// keepalive constants); separately, every Nth tick refreshes
    /// `lastMultiplexerTarget` over a side channel so any later reconnect
    /// reattaches to the live session instead of a fresh login shell. Recording
    /// must happen *while still attached* — once the socket drops, the session
    /// reads as detached and can't be identified.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        let firstDelay = firstKeepaliveDelay
        keepaliveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(firstDelay))
            while !Task.isCancelled {
                guard let self, self.state == .connected else { return }
                // Liveness ping on the already-open PTY channel: a no-op
                // window-change emits a real SSH packet that resets NAT idle
                // timers and the server's ClientAlive counter, without opening
                // a new channel or injecting visible input. A same-size
                // window-change is a no-op to tmux/readline, so nothing redraws.
                self.sendKeepalivePing()
                // Refresh the multiplexer reattach target each tick over a side
                // channel so a later reconnect lands back in the live session.
                // It must be captured *while the user is attached* — a session
                // entered and dropped between ticks would otherwise record no
                // target — and the exec is cheap.
                await self.recordMultiplexerTarget()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// No-op window-change on the live PTY channel — see `startKeepalive`.
    /// Routed through the FIFO outbox so it always targets the current
    /// connection and serializes with any in-flight keystrokes/resizes.
    private func sendKeepalivePing() {
        let size = currentWindowSize()
        resize(cols: size.cols, rows: size.rows)
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

    private func attemptLoop(maxAttempts: Int, intent: ReattachIntent) async {
        var delay = 0.5
        for attempt in 1...max(1, maxAttempts) {
            do {
                reattachChoicePending = false
                try await establish()
                state = .connected
                lastError = nil
                // Make the PTY match the on-screen size before anything
                // (especially a multiplexer attach) draws into it.
                await syncWindowSize()
                await applyReattach(intent)
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

    /// Resume the multiplexer after a (re)connect per `intent`. `.choose` (and a
    /// stale explicit/auto target) consults the *live* session list so the user
    /// never sees or lands in a session that was closed since the drop.
    private func applyReattach(_ intent: ReattachIntent) async {
        func attach(_ session: String) async {
            guard let cmd = MultiplexerController.attachCommand(resolvedMultiplexer, target: session) else { return }
            try? await connection.send(cmd)
        }

        switch intent {
        case .freshShell:
            return
        case .session(let s):
            // Explicit pick from a list the user just saw — attach directly.
            await attach(s)
        case .auto:
            guard settings.autoReattachMultiplexer, let target = reattachTarget else { return }
            await attach(target)
        case .choose:
            // Build the picker from a live query so closed sessions never show.
            let live = await MultiplexerController.availableSessions(resolvedMultiplexer, on: connection)
            availableSessions = live
            if live.count == 1, let only = live.first {
                await attach(only)            // unambiguous — just go there
            } else if live.count > 1 {
                reattachChoicePending = true  // let the user pick from the fresh list
            }
            // live empty → stay in the plain shell
        }
    }

    private func establish() async throws {
        let auth: SSHConnection.AuthMethod
        if let keyID = server.keyID {
            do {
                auth = .privateKey(try keyStore.privateKey(for: keyID))
            } catch {
                // A configured key that won't load (deleted, Keychain failure,
                // decode error) must be reported — not silently downgraded to a
                // password attempt that masks why the key failed.
                throw SessionError.keyUnavailable(error.localizedDescription)
            }
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
            // The user may have closed or suspended this session during the
            // await above; never resurrect a connection they tore down.
            guard state == .connected else { return }
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
        case keyUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No credentials are set for this server. Edit the server and pick a key or set a password."
            case .keyUnavailable(let detail):
                return "Couldn't load the configured SSH key (\(detail)). Re-import it in Settings → Manage Keys."
            }
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
    private let profiles: ProfileStore
    private let activityController = SessionActivityController()
    private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(keyStore: KeyStore, serverStore: ServerStore, passwords: PasswordStore, settings: AppSettings, profiles: ProfileStore) {
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.passwords = passwords
        self.settings = settings
        self.profiles = profiles
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
            settings: settings,
            profiles: profiles
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
            // Tear the session down like the X button does. Dropping it from
            // the list alone leaks the SSH connection (its socket is never
            // disconnected) and the outbox Task — which holds the session
            // strongly for the life of its never-finished stream — so every
            // natural `exit` would accumulate a leaked session + live socket.
            Task { await session.close() }
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
                    state: stateString,
                    startedAt: session.startedAt,
                    // Never surface a stale agent label on a session that
                    // isn't currently connected.
                    agentStatus: SessionActivityAttributes.resolvedAgentStatus(
                        sessionState: stateString,
                        monitorStatus: monitorStatus
                    ),
                    agentName: session.agentMonitor.detected?.displayName
                )
            }
        activityController.update(with: summaries)
    }

    func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    /// Hold sockets open for the *entire* background allowance iOS grants
    /// (~30s) so a quick app-switch keeps the live session, then close cleanly
    /// only when iOS is about to suspend us. The multiplexer target is recorded
    /// up front so even a forced suspend can reattach. The session survives the
    /// disconnect server-side; the user chooses reattach-vs-fresh on return.
    func appDidEnterBackground() {
        guard sessions.contains(where: { $0.state == .connected }) else { return }
        // iOS calls this expiration handler just before reclaiming our
        // background time — that's the latest safe moment to suspend cleanly.
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "aplusterminal.session-grace") { [weak self] in
            self?.finishGrace()
        }
        graceTask = Task { [weak self] in
            guard let self else { return }
            // Record targets immediately, while definitely still attached.
            for session in self.sessions where session.state == .connected {
                await session.recordMultiplexerTarget()
            }
            // No fixed timer: leave the sockets open until iOS fires the
            // expiration handler above, maximizing the quick-switch window.
        }
    }

    func appWillEnterForeground() {
        // Back within the grace window: sockets are still open, nothing to do.
        graceTask?.cancel()
        graceTask = nil
        endBackgroundTask()
        // Push the Activity's stale horizon out — content only goes stale
        // when the process is killed or frozen long enough to stop updating.
        // refreshActivity() coalesces when the session list is unchanged (the
        // common case after a background freeze), so also force a stale-date
        // bump that bypasses that coalescing.
        refreshActivity()
        activityController.refreshStaleHorizon()
        // Do NOT auto-reconnect: a session that was suspended in the background
        // shows a paused card so the user picks reattach-tmux vs. fresh shell.
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
