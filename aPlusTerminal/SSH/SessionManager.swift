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

    /// Whether this state counts toward the Live Activity (§4.5). Every
    /// *open* session counts — including `.suspended`, whose socket is gone
    /// but whose app session is still open and reattachable (it renders as
    /// "Paused"). PR #76 excluded `.suspended`, which wound the Activity down
    /// ~60s after backgrounding even though the in-app session persisted as a
    /// reattachable paused card; the Activity must instead end only when the
    /// last session actually closes. Orphan cleanup for a process that dies
    /// while suspended is handled by the staleDate + launch-time reconcile in
    /// `SessionActivityController`, not by dropping paused sessions here.
    var representsOpenSession: Bool { self != .closed }
}

/// One terminal session: owns the SSH connection, the persistent SwiftTerm
/// view (so scrollback survives leaving the screen), and the reconnect logic.
@MainActor
@Observable
final class TerminalSession: Identifiable, Hashable {
    nonisolated let id = UUID()
    /// Which meshyy session on this server this tab owns. See `lowestFreeMeshyySlot`.
    nonisolated let meshyySlot: Int

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
    /// Set when a (re)connect failed on a host-key mismatch: both
    /// fingerprints plus the full presented key line, so the user can review
    /// and *explicitly* re-pin after a legitimate server reinstall. There is
    /// still no silent-accept path (§4.1); this is review-then-decide only.
    private(set) var hostKeyConflict: (expectedFingerprint: String, presentedFingerprint: String, presentedKey: String)?
    /// SessionManager hook for Live Activity updates (§4.5).
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Fired when the remote shell ends on its own (the user typed `exit`).
    @ObservationIgnored var onShellExit: (() -> Void)?
    /// The session's single pop-out slot: fired on every output chunk and —
    /// via SessionManager's multicast — on state/agent transitions, while a
    /// PiP surface mirrors this session. Owned by PiPCoordinator; do NOT
    /// repurpose (`onStateChange`/`agentMonitor.onChange` stay reserved for
    /// the Live Activity).
    @ObservationIgnored var pipInvalidate: (() -> Void)?

    let bridge = TerminalBridge()
    let terminalView = TerminalEmulatorView(frame: .zero)
    /// Agent working/waiting heuristic for the Live Activity (§4.5). Built from
    /// the resolved agent candidates — never names an agent in code.
    let agentMonitor: AgentActivityMonitor
    /// Candidate dev-server ports for this session — the output scrape, OSC 8
    /// hyperlinks, and `lsof`/`ss` ground truth, fused. Feeds the preview
    /// sheet's port picker.
    let portDetector = PortDetector()
    /// One-time "enable mouse" hint banner trigger (§4.3).
    var showMultiplexerHint = false

    private(set) var connection = SSHConnection()
    /// The meshyy transport, when the host runs a daemon and the toggle is on.
    ///
    /// The SSH connection above stays live regardless — this replaces only the PTY
    /// byte stream. See MeshyyTransport for why that is the whole of the change.
    private(set) var meshyy: MeshyyTransport?
    /// Why meshyy is not in use, when the user asked for it.
    ///
    /// SHOWN, not merely recorded. The first version set this and displayed it nowhere,
    /// so a user with the toggle on and a daemon that could not be reached got a normal
    /// SSH session and no explanation — reported as "it's just booting a new shell",
    /// "I don't think it's surviving anything". The information existed the whole time
    /// and never reached a screen, which cost a full round trip to diagnose something
    /// the app already knew.
    ///
    /// §3.5: fail VISIBLE. A silent fallback is indistinguishable from a broken feature.
    private(set) var meshyyUnavailable: String?
    /// True while meshyy is carrying this session, for the status line.
    var isUsingMeshyy: Bool { meshyy != nil }
    private let keyStore: KeyStore
    private let serverStore: ServerStore
    private let passwords: PasswordStore
    private let settings: AppSettings
    private let profiles: ProfileStore
    private var io: SessionIO?
    private var scrollBridge: ScrollBridge?
    private var pumpTask: Task<Void, Never>?
    private var meshyyPumpTask: Task<Void, Never>?
    /// The config the winning candidate connected with, so the SSH shell can still be
    /// opened later if the meshyy probe comes back empty.
    private var lastCandidateConfig: SSHConnection.Configuration?
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
    /// Multiplexer-target refresh cadence: the first keepalive tick, then
    /// every Nth. The liveness ping is free (it rides the PTY); the target
    /// refresh opens an exec channel, so it runs far less often.
    static let recordEveryNthTick = 4
    /// Overridable in tests for fast, deterministic keepalive assertions.
    var keepaliveInterval = TerminalSession.defaultKeepaliveInterval
    var firstKeepaliveDelay = TerminalSession.defaultFirstKeepaliveDelay
    /// How long a failed reconnect attempt waits for the network path to
    /// return before falling back to plain backoff — long enough to ride out
    /// an elevator or a walk between access points.
    static let defaultPathWaitBudget: TimeInterval = 60
    var pathWaitBudget = TerminalSession.defaultPathWaitBudget
    /// Test seam: replaced in unit tests to simulate path loss/restoration
    /// without a live NWPathMonitor.
    var awaitNetworkPath: (TimeInterval) async -> NetworkPathWaiter.Result = {
        await NetworkPathWaiter.awaitPath(timeout: $0)
    }
    /// Per-candidate connect budget when a server derives several candidate
    /// hosts (discovered ".local" servers). Short on purpose: a dead ".local"
    /// name on LTE must not eat the whole attempt before the VPN-resolvable
    /// bare name gets its turn. Single-candidate servers keep the transport
    /// default (today's behavior, untouched).
    static let defaultCandidateConnectTimeout: TimeInterval = 4
    /// Overridable in tests (same pattern as `keepaliveInterval`).
    var candidateConnectTimeout = TerminalSession.defaultCandidateConnectTimeout
    /// In-memory winner of the last successful candidate walk — reconnects
    /// within this session try it first. Never persisted; reset when the
    /// network path changes (the best candidate likely changed with it).
    private var preferredCandidateHost: String?
    /// One row per candidate actually attempted in the most recent establish
    /// run, in order — a deterministic test seam for candidate ordering and
    /// the per-candidate timeout budget (nil = transport default).
    struct CandidateAttempt: Equatable {
        let host: String
        let timeout: TimeInterval?
    }
    private(set) var lastCandidateAttempts: [CandidateAttempt] = []
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

    init(server: Server, meshyySlot: Int = 0, keyStore: KeyStore, serverStore: ServerStore, passwords: PasswordStore, settings: AppSettings, profiles: ProfileStore) {
        self.server = server
        self.meshyySlot = meshyySlot
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
        // Push the real size after every layout pass. `sizeChanged` is not reliably
        // delivered when the keyboard is DISMISSED, and without this the remote keeps
        // the keyboard-up row count for the life of the session.
        terminalView.onLayout = { [weak self] in
            MainActor.assumeIsolated { self?.syncSizeAfterLayout() }
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

    // MARK: - Localhost preview

    /// The one live port forward, or nil. Deliberately single: the sheet shows
    /// one preview at a time, and making a second forward require tearing the
    /// first down means a listener can never stay bound on the phone behind
    /// the user's back.
    private(set) var previewForward: SSHPortForward?
    /// Surfaced in the preview sheet; nil when the last attempt succeeded.
    var previewError: String?
    /// Set when the terminal reports an OSC 8 hyperlink on a loopback host.
    /// The terminal screen observes this and presents the preview sheet — the
    /// replacement for handing `http://localhost:5173` to Safari, where it
    /// resolves to the *phone* and fails.
    var pendingPreviewPort: Int?

    /// Forward `remotePort` to a loopback listener on this device. Any
    /// existing forward is torn down first (see `previewForward`).
    func startPreview(remotePort: Int) async {
        await stopPreview()
        guard state == .connected else {
            previewError = "Reconnect this session before opening a preview."
            return
        }
        let forward = SSHPortForward(remotePort: remotePort, connection: connection)
        do {
            try await forward.start()
            previewForward = forward
            previewError = nil
        } catch {
            // Leave no half-open listener behind on a failed start.
            await forward.stop()
            previewError = error.localizedDescription
        }
    }

    func stopPreview() async {
        guard let forward = previewForward else { return }
        previewForward = nil
        await forward.stop()
    }

    /// Synchronous teardown for the paths that must not await — the
    /// background-task expiration handler in particular, where any network
    /// I/O is itself the 0x8badf00d kill (see `suspendAbruptly`). Cancelling
    /// a listener and its connections is non-blocking, so this is safe there.
    private func stopPreviewImmediately() {
        guard let forward = previewForward else { return }
        previewForward = nil
        forward.stopImmediately()
    }

    /// Ground truth for the port picker. Runs over the existing exec-channel
    /// helper, on demand only — the preview sheet drives the cadence while it
    /// is visible, and nothing polls in the background.
    /// One listener snapshot. Returns whether a snapshot actually landed, so
    /// the picker can tell "still looking" from "looked, found nothing" —
    /// which it previously could not, and so showed the empty-state text while
    /// the very first check was still in flight.
    ///
    /// The timeout is the other half of that report: `runCommand` has none of
    /// its own, and an exec channel that stalls (a busy transport, a half-dead
    /// link) never returns, so the poll loop simply stopped. Backgrounding the
    /// sheet and coming back appeared to "fix" it because that tears down the
    /// task and starts a fresh one.
    @discardableResult
    func refreshListenerSnapshot(timeout: Duration = .seconds(6)) async -> Bool {
        guard state == .connected else { return false }
        let connection = self.connection
        let output = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await connection.runCommand(PortDetector.listenerCommand) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let output else { return false }
        portDetector.applyListenerSnapshot(output)
        return true
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
    /// Whether the multiplexer reattach machinery applies at all.
    ///
    /// It does not when meshyy is carrying the session. That machinery exists because a
    /// dropped SSH connection loses the shell, so coming back means finding a tmux
    /// session and guessing which one — a question only the user can answer. meshyy
    /// holds the shell itself, so there is nothing lost, nothing to find and nothing to
    /// ask: reconnecting is just reattaching to the session that was already there.
    ///
    /// Running it anyway would be worse than redundant. It would attach a multiplexer
    /// INSIDE a session that is already attached to one.
    var reattachEnabled: Bool { settings.autoReattachMultiplexer && !isUsingMeshyy }

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

    /// Explicit user decision after reviewing a host-key change on the
    /// conflict sheet: re-pin the exact presented key that was reviewed,
    /// persist it, and reconnect. NEVER called automatically — the only call
    /// site is the destructive confirm button.
    func acceptRotatedHostKey() async {
        guard let conflict = hostKeyConflict else { return }
        server.knownHostKey = conflict.presentedKey
        serverStore.update(server)
        hostKeyConflict = nil
        await reconnectChoosingSession()
    }

    #if DEBUG
    /// Test-only: inject a conflict so accept-path assertions don't need a
    /// live mismatching server.
    func _setHostKeyConflictForTesting(expected: String, presented: String, presentedKey: String) {
        hostKeyConflict = (expected, presented, presentedKey)
    }
    #endif

    /// Cleanly close the socket while backgrounded; tmux survives.
    func suspend() async {
        guard state == .connected else { return }
        pumpTask?.cancel()
        pumpTask = nil
        // Before the socket goes: a forward that outlives its SSHClient leaves
        // a listener bound on the phone with nothing behind it, so every
        // teardown path has to take it down (preview brief §Phase 1).
        await stopPreview()
        // DETACH, do not shut down. The distinction is the entire feature: detaching
        // leaves the daemon holding the pty with its ring buffer filling, so what the
        // shell says while the phone is asleep is still there to be replayed. A
        // shutdown would send `bye` and end the session, which is precisely the
        // behaviour meshyy exists to replace.
        //
        // Previously suspend ignored meshyy altogether, so the transport was left
        // running against a connection iOS was about to freeze.
        meshyyPumpTask?.cancel()
        meshyyPumpTask = nil
        await meshyy?.detach()
        await connection.disconnect()
        agentMonitor.reset()
        state = .suspended
    }

    /// Last-resort suspension for the background-task expiration handler:
    /// mark the session suspended WITHOUT the network teardown.
    /// `connection.disconnect()` is SSH channel teardown — network I/O the
    /// expiration handler must never wait on (a slow handler is exactly the
    /// watchdog kill this exists to avoid). Skipping it is safe: iOS closes
    /// the sockets when it suspends the process, the server-side multiplexer
    /// session survives just as it does after a clean disconnect, and every
    /// reconnect path already tears down the old connection first
    /// (`establish()` disconnects before dialing). Synchronous by design —
    /// never awaits.
    func suspendAbruptly() {
        guard state == .connected else { return }
        pumpTask?.cancel()
        pumpTask = nil
        // Synchronous variant only — cancelling a listener and its connections
        // never blocks, so this respects the handler's no-I/O contract while
        // still not leaking the bind across a suspend.
        stopPreviewImmediately()
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
            var tick = 0
            while !Task.isCancelled {
                guard let self, self.state == .connected else { return }
                tick += 1
                // Liveness ping on the already-open PTY channel: a no-op
                // window-change emits a real SSH packet that resets NAT idle
                // timers and the server's ClientAlive counter, without opening
                // a new channel or injecting visible input. A same-size
                // window-change is a no-op to tmux/readline, so nothing redraws.
                self.sendKeepalivePing()
                // Refresh the multiplexer reattach target on the first tick
                // (a drop within the first minute must still reattach) and
                // every Nth thereafter (~100s at the default cadence). This
                // opens an exec channel — the code previously ran it every
                // 25s while the doc claimed "every Nth tick"; the doc wins.
                if tick == 1 || tick % Self.recordEveryNthTick == 0 {
                    await self.recordMultiplexerTarget()
                }
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
        await stopPreview()
        // SHUT DOWN, do not detach. The user closed the tab, so the session should end
        // — a detach would leave the daemon holding a shell nobody will ever reattach
        // to, and they would accumulate one per closed tab, forever, invisible until
        // the host ran out of processes.
        //
        // Previously close() ignored meshyy entirely, leaking the QUIC connection, the
        // pump task, and the remote shell on every single tab close.
        await stopMeshyy()
        agentMonitor.reset()
        portDetector.reset()
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
                hostKeyConflict = nil
                // Make the PTY match the on-screen size before anything
                // (especially a multiplexer attach) draws into it.
                await syncWindowSize()
                await applyReattach(intent)
                return
            } catch {
                lastError = error.localizedDescription
                if case SSHConnectionError.hostKeyMismatch(let expected, let presented, let presentedKey) = error {
                    hostKeyConflict = (expected, presented, presentedKey)
                    break  // MITM warning — never retry past it silently
                }
                if attempt < maxAttempts {
                    // Don't burn retries against a dead radio (§4.1): when
                    // the path is down, wait — bounded — for it to come back
                    // and retry immediately with backoff reset. When the path
                    // is already up (a server-side failure), plain backoff
                    // applies exactly as before.
                    switch await awaitNetworkPath(pathWaitBudget) {
                    case .restored:
                        delay = 0.5
                        // The network changed under us (Wi-Fi → LTE, VPN up):
                        // the previous winner is likely the wrong candidate
                        // now, so the next attempt re-runs candidate selection
                        // from the top in derived order.
                        preferredCandidateHost = nil
                    case .alreadySatisfied, .timedOut:
                        try? await Task.sleep(for: .seconds(delay))
                        delay = min(delay * 2, 2.0)
                    }
                    // The user may have closed the session while this loop was
                    // suspended in the gap above — close() does not cancel it,
                    // and the path wait holds a gap open for up to 60s (≈10
                    // minutes across a full run). Bail instead of letting the
                    // next establish() resurrect a torn-down session. `.closed`
                    // is the only bail state: the gap otherwise runs under
                    // .reconnecting (reconnect flow) or .connecting (initial
                    // connect), both of which must keep retrying.
                    if state == .closed { return }
                }
            }
        }
        // A close() that landed mid-loop must win — stomping .closed with
        // .suspended would revive a session the manager already discarded.
        if state != .closed { state = .suspended }
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
                auth = .key(try keyStore.storedPrivateKey(for: keyID))
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
        // The forward is bound to the connection we are about to replace.
        await stopPreview()
        await connection.disconnect()

        // ONE SHELL. The transport that carries the terminal is chosen ONCE, here,
        // before any shell exists — and only the winner ever spawns one.
        //
        // The previous version opened an SSH pty AND attached meshyy, leaving two live
        // shells on the host for one visible terminal, and switched between them when
        // meshyy faltered. That is where the wrong frame and the wrong scrollback came
        // from: they were different shells with different state. There is no runtime
        // fallback now, by design — the Settings toggle IS the fallback, and a user who
        // finds meshyy misbehaving turns it off and gets exactly today's app back.
        let wantsMeshyy = settings.meshyyTransport
        let fresh = try await connectBestCandidate(auth: auth, openShell: !wantsMeshyy)
        connection = fresh
        // Clear whatever the dead pty left on screen before the new shell and
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

        await stopMeshyy()
        meshyyUnavailable = nil

        if wantsMeshyy {
            let size = currentWindowSize()
            let result = await MeshyyTransport.bootstrap(
                over: fresh,
                serverID: server.id,
                slot: meshyySlot,
                sshHost: server.host,
                cols: size.cols,
                rows: size.rows
            )
            switch result {
            case .success(let transport):
                meshyy = transport
                startMeshyyPump(reading: transport)
                return
            case .failure(let reason):
                // No daemon here, or it refused. Say so, and open the SSH shell that
                // was deliberately not opened above. This is a CONNECT-time decision,
                // not a mid-session switch: still exactly one shell.
                meshyyUnavailable = reason.errorDescription
                if let config = lastCandidateConfig {
                    try await fresh.openShell(config)
                }
            }
        }
        startPump(reading: fresh)
    }

    /// Tears down the meshyy transport without touching the SSH connection.
    private func stopMeshyy() async {
        guard let transport = meshyy else { return }
        meshyy = nil
        meshyyPumpTask?.cancel()
        meshyyPumpTask = nil
        await transport.disconnect()
    }

    /// Reads PTY bytes from meshyy into the emulator.
    ///
    /// Deliberately a copy of `startPump`'s body rather than a shared generic: the two
    /// differ in what ending means. An SSH channel ending is the shell exiting or the
    /// transport dying, and drives reconnect. meshyy ending while SSH is still up means
    /// only that the resumable transport gave up — the session is still alive, so the
    /// right response is to fall back to the SSH PTY that was left open underneath, not
    /// to tear the session down.
    private func startMeshyyPump(reading transport: MeshyyTransport) {
        meshyyPumpTask = Task { [weak self] in
            for await chunk in transport.output {
                guard let self, !Task.isCancelled else { return }
                let bytes = [UInt8](chunk)
                self.terminalView.feed(byteArray: ArraySlice(bytes))
                self.agentMonitor.observe(bytes)
                self.portDetector.observe(bytes)
                self.pipInvalidate?()
            }
            guard let self, !Task.isCancelled, self.meshyy === transport else { return }
            // meshyy ended. There is no SSH shell hiding behind it to fall back to —
            // that was the whole point — so this is a dropped session like any other,
            // and the reconnect path handles it. A user who wants SSH turns the toggle
            // off, which is what it is for.
            self.meshyyEnded()
        }
    }

    /// The meshyy session ended without the user closing it.
    private(set) var lastMeshyyEnd: String?

    private func meshyyEnded() {
        guard state == .connected else { return }
        lastMeshyyEnd = meshyy?.endReason
        meshyy = nil
        stopPreviewImmediately()
        state = .reconnecting
        Task { await reconnect(maxAttempts: 10) }
    }


    /// Walks the server's candidate hosts in order (last winner first within
    /// this session) and returns the first connection that completes an SSH
    /// handshake under the pinned host key.
    ///
    /// Security rule (non-negotiable): a host-key MISMATCH on a candidate
    /// other than the stored primary host means "wrong machine behind an
    /// untrusted resolver" — that candidate is skipped silently, WITHOUT
    /// recording `hostKeyConflict` or offering the re-pin sheet. The
    /// review-then-re-pin flow (PR #78) stays reserved for the stored primary
    /// host, where it still aborts the walk immediately (never quietly
    /// connect elsewhere past a MITM warning). A first connect with no pinned
    /// key does TOFU on whichever candidate connects first, exactly as today.
    private func connectBestCandidate(
        auth: SSHConnection.AuthMethod,
        openShell: Bool
    ) async throws -> SSHConnection {
        var candidates = server.connectionCandidates
        if let preferred = preferredCandidateHost,
           let index = candidates.firstIndex(of: preferred), index > 0 {
            candidates.remove(at: index)
            candidates.insert(preferred, at: 0)
        }
        // The short per-candidate budget applies only when there is a queue
        // behind the current candidate; a single-candidate (manually-entered)
        // server keeps the transport default exactly as before.
        let perCandidateTimeout: TimeInterval? = candidates.count > 1 ? candidateConnectTimeout : nil
        let size = currentWindowSize()

        lastCandidateAttempts = []
        var firstFailure: Error?
        for candidate in candidates {
            lastCandidateAttempts.append(CandidateAttempt(host: candidate, timeout: perCandidateTimeout))
            var config = SSHConnection.Configuration(
                host: candidate,
                port: server.port,
                username: server.username,
                auth: auth,
                knownHostKey: server.knownHostKey,
                cols: size.cols,
                rows: size.rows
            )
            if let perCandidateTimeout { config.connectTimeout = perCandidateTimeout }

            let fresh = SSHConnection()
            do {
                try await fresh.connect(config, openShell: openShell)
                preferredCandidateHost = candidate
                lastCandidateConfig = config
                return fresh
            } catch {
                if case SSHConnectionError.hostKeyMismatch = error {
                    // Primary host → surface the mismatch for review (PR #78)
                    // and stop the walk. Fallback → skip silently (see doc).
                    if candidate == server.host { throw error }
                    continue
                }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if candidates.count > 1 {
            throw SessionError.allCandidatesFailed(lastCandidateAttempts.map(\.host))
        }
        // Single candidate: rethrow the underlying error untouched — today's
        // behavior and error copy, exactly.
        throw firstFailure ?? SessionError.allCandidatesFailed(candidates)
    }

    /// Best-known terminal dimensions: what the layout last reported, falling
    /// back to the emulator's current grid.
    /// The size the terminal ACTUALLY is, not the last one we asked for.
    ///
    /// It used to prefer `lastRequestedSize`, which turned a single missed resize into
    /// a permanent one: the keepalive re-asserted the stale size every tick, so a
    /// terminal that shrank for the keyboard and grew back stayed small on the server
    /// forever. The emulator's own dimensions are the ground truth for what is on
    /// screen, and reading them makes every keepalive tick self-correcting.
    private func currentWindowSize() -> (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        if terminal.cols > 1, terminal.rows > 1 {
            return (terminal.cols, terminal.rows)
        }
        // Before the first layout the emulator has no meaningful size yet.
        if let lastRequestedSize {
            return (max(2, lastRequestedSize.cols), max(2, lastRequestedSize.rows))
        }
        return (max(2, terminal.cols), max(2, terminal.rows))
    }

    /// Pushes the terminal's real size to the far end if it has drifted.
    ///
    /// Called on every layout pass, so dismissing the keyboard regrows the remote
    /// immediately rather than at the next keepalive tick — or never.
    private func syncSizeAfterLayout() {
        let size = currentWindowSize()
        guard size.cols > 1, size.rows > 1 else { return }
        if let last = lastRequestedSize, last.cols == size.cols, last.rows == size.rows {
            return
        }
        resize(cols: size.cols, rows: size.rows)
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
                // Whichever transport is carrying the PTY. meshyy when it attached,
                // SSH otherwise — the outbox does not need to know which.
                let meshyy = self.meshyy
                let connection = self.connection
                switch item {
                case .data(let data):
                    if let meshyy {
                        try? await meshyy.send(data)
                    } else {
                        try? await connection.send(data)
                    }
                case .resize(let cols, let rows):
                    if let meshyy {
                        try? await meshyy.resize(cols: cols, rows: rows)
                    }
                    // The SSH PTY is resized either way: it is still the fallback if
                    // meshyy drops, and a stale size there would repaint at the wrong
                    // geometry the moment it does.
                    try? await connection.resize(cols: cols, rows: rows)
                }
            }
        }
    }

    /// `feedsTerminal: false` keeps the SSH channel drained while meshyy is drawing.
    ///
    /// Draining matters even when the bytes are not shown: an SSH PTY nobody reads
    /// fills its window, the remote shell blocks on its own stdout, and the session
    /// hangs for real — the same failure meshyy's own daemon has a ring buffer to
    /// avoid. So the pump keeps running and simply does not draw.
    private func startPump(reading connection: SSHConnection) {
        pumpTask = Task { [weak self] in
            for await chunk in await connection.output {
                guard let self, !Task.isCancelled else { return }
                let bytes = [UInt8](chunk)
                self.terminalView.feed(byteArray: ArraySlice(bytes))
                self.agentMonitor.observe(bytes)
                // Source A of the preview's port detection. Cheap by
                // construction: it byte-scans for "://" and only then does
                // any String work, so a firehose costs a memchr per chunk.
                self.portDetector.observe(bytes)
                self.pipInvalidate?()
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
        // The transport under the forward is gone either way (drop or clean
        // `exit`), so drop the listener now rather than after the reconnect
        // decision below — a bound port with a dead tunnel behind it just
        // hangs the browser.
        stopPreviewImmediately()
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
        /// Every candidate host failed — carries the addresses tried, in
        /// order, so the user sees exactly what was attempted.
        case allCandidatesFailed([String])

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No credentials are set for this server. Edit the server and pick a key or set a password."
            case .keyUnavailable(let detail):
                return "Couldn't load the configured SSH key (\(detail)). Re-import it in Settings → Manage Keys."
            case .allCandidatesFailed(let hosts):
                return "Tried \(hosts.joined(separator: ", ")) — none reachable."
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

    /// SwiftTerm parses OSC 8 hyperlinks, which Vite and friends emit. A
    /// loopback host is the one case where handing the URL to Safari is
    /// actively wrong: `localhost` on the phone is the phone, not the server
    /// the user is looking at, so the tap has always just failed. Route those
    /// into the preview instead; every other host keeps today's behavior.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
        MainActor.assumeIsolated {
            guard let host = url.host, PortDetector.isLoopbackHost(host) else {
                UIApplication.shared.open(url)
                return
            }
            guard let session else { return }
            session.portDetector.note(url: url)
            session.pendingPreviewPort = url.port ?? (url.scheme == "https" ? 443 : 80)
        }
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

    /// The lowest slot number not already taken by a live tab on this server.
    ///
    /// This is what makes a meshyy session name stable ACROSS APP LAUNCHES while still
    /// being unique per tab, and both halves matter. Keying on the tab's UUID gave
    /// uniqueness and nothing else: a fresh UUID every launch meant every launch
    /// created a NEW daemon session with a NEW shell, and because the user's shell rc
    /// auto-attaches tmux, each one became another tmux client. Six accumulated within
    /// an evening. tmux then sized the session to its smallest client, so the terminal
    /// was clamped to 39 rows no matter what any one client asked for — the black
    /// region — and six clients renegotiating produced the flicker.
    ///
    /// A slot is derived, not stored: the first tab on a server is always slot 0, so a
    /// relaunch reattaches to the session it left rather than spawning a sibling.
    private func lowestFreeMeshyySlot(for server: Server) -> Int {
        let taken = Set(sessions.filter { $0.server.id == server.id }.map(\.meshyySlot))
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        return slot
    }

    private let keyStore: KeyStore
    private let serverStore: ServerStore
    private let passwords: PasswordStore
    private let settings: AppSettings
    private let profiles: ProfileStore
    private let activityController = SessionActivityController()
    private let diagnostics: BackgroundExitDiagnostics
    private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Safety margin against the background watchdog. While backgrounded, the
    /// sockets are deliberately held open for nearly the entire background
    /// allowance (build-6 intent: a quick app-switch keeps the live session).
    /// But the wind-down itself — `session.suspend()` is SSH channel teardown,
    /// i.e. network I/O, plus the final ActivityKit flush — must NOT run
    /// inside the `beginBackgroundTask` expiration handler: Apple's contract
    /// is that the handler returns fast and calls `endBackgroundTask`
    /// promptly, and a handler that dawdles gets the process killed with
    /// 0x8badf00d. So the manager polls `backgroundTimeRemaining` and starts
    /// the wind-down *proactively* once the remaining allowance drops below
    /// this margin: late enough that the sessions still get the allowance
    /// minus only these ~10s, early enough that suspend + flush comfortably
    /// finish before the watchdog ever looks our way.
    static let windDownSafetyMargin: TimeInterval = 10
    /// Poll cadence for `backgroundTimeRemaining` while parked in the
    /// background — a plain Task.sleep loop, valid for as long as the
    /// background task assertion keeps the process running.
    static let backgroundRemainingPollInterval: TimeInterval = 2

    /// Remaining background allowance. UIApplication's number on device;
    /// injected in tests — the simulator doesn't enforce the watchdog this
    /// margin guards against, so the proactive path must be provable without it.
    @ObservationIgnored var backgroundTimeRemaining: @MainActor () -> TimeInterval = {
        UIApplication.shared.backgroundTimeRemaining
    }
    /// Overridable in tests for fast, deterministic wind-down assertions.
    @ObservationIgnored var windDownPollInterval: TimeInterval = SessionManager.backgroundRemainingPollInterval
    /// Single-flight guard for the wind-down: the proactive poll, the
    /// expiration handler, and a foreground return can race (same discipline
    /// as `graceTask` cancellation). First starter wins; everyone else no-ops.
    @ObservationIgnored private var windDownStarted = false

    /// Budget for the background grace preamble (the per-session multiplexer
    /// target recording below). Recording opens an exec channel per session
    /// with no deadline of its own, so a single stalled channel could
    /// otherwise pin the grace task for the entire background stay. Long
    /// enough for a healthy round-trip, small next to the ~30s allowance.
    /// Overridable in tests for fast, deterministic assertions.
    static let defaultBackgroundPreambleBudget: TimeInterval = 5
    @ObservationIgnored var backgroundPreambleBudget = SessionManager.defaultBackgroundPreambleBudget
    /// Test seam: replaced to simulate a hanging exec channel in the grace
    /// preamble without a wedgeable live server.
    @ObservationIgnored var recordTargetForGrace: (TerminalSession) async -> Void = { session in
        await session.recordMultiplexerTarget()
    }
    /// Test seam: flips true once the grace preamble has finished — or been
    /// abandoned by its budget — i.e. the moment the grace path is unblocked.
    @ObservationIgnored private(set) var gracePreambleFinished = false

    /// Awaits `operation`, but gives up after `seconds` and returns anyway.
    /// The abandoned work is cancelled best-effort (a truly wedged exec
    /// channel ignores cooperative cancellation) and left to finish or die on
    /// its own — the caller must treat the operation as fire-and-forget-safe.
    private static func raceAgainstTimeout(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) async {
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.withLock {
                    if resumed { return false }
                    resumed = true
                    return true
                }
            }
        }
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let work = Task {
                await operation()
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                if once.claim() { continuation.resume() }
            }
        }
    }

    init(keyStore: KeyStore, serverStore: ServerStore, passwords: PasswordStore, settings: AppSettings, profiles: ProfileStore, diagnostics: BackgroundExitDiagnostics? = nil) {
        self.keyStore = keyStore
        self.serverStore = serverStore
        self.passwords = passwords
        self.settings = settings
        self.profiles = profiles
        self.diagnostics = diagnostics ?? BackgroundExitDiagnostics()
        // A surviving Live Activity from a previous launch must reflect this
        // process's truth (no sessions yet) instead of stale ones (§4.5).
        // The controller adopts one survivor in its init; this zero push then
        // takes the end path on it — the cleanup for an Activity orphaned by
        // a force-quit while suspended, whose sessions no longer exist.
        refreshActivity()
    }

    @discardableResult
    func open(server: Server) -> TerminalSession {
        let session = TerminalSession(
            server: server,
            meshyySlot: lowestFreeMeshyySlot(for: server),
            keyStore: keyStore,
            serverStore: serverStore,
            passwords: passwords,
            settings: settings,
            profiles: profiles
        )
        session.onStateChange = { [weak self, weak session] in
            self?.refreshActivity()
            // State drives the pop-out's chip too — multicast into the
            // session's PiP slot rather than letting PiP claim this closure.
            session?.pipInvalidate?()
        }
        session.agentMonitor.onChange = { [weak self, weak session] in
            self?.refreshActivity()
            session?.pipInvalidate?()
        }
        session.onShellExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessions.removeAll { $0.id == session.id }
            self.refreshActivity()
            self.pipSessionClosed?(session)
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

    /// Wired at app init: a closing session must also end any pop-out that
    /// is mirroring it (a dead session's PiP window would otherwise linger,
    /// frozen on its last frame).
    @ObservationIgnored var pipSessionClosed: ((TerminalSession) -> Void)?

    func close(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
        Task { await session.close() }
        refreshActivity()
        pipSessionClosed?(session)
    }

    func closeAll() {
        let closing = sessions
        sessions.removeAll()
        for session in closing {
            Task { await session.close() }
            pipSessionClosed?(session)
        }
        refreshActivity()
    }

    /// Live Activity mirror of the session list (§4.5).
    private func refreshActivity() {
        let summaries = sessions
            // Every open session counts (§4.5), paused ones included — the
            // Activity mirrors open app sessions, not live sockets. A
            // `.closed` session is on its way out of `sessions` this same
            // tick and is the only state that leaves the summary.
            .filter { $0.state.representsOpenSession }
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

    /// Hold sockets open for *nearly* the entire background allowance iOS
    /// grants (~30s) so a quick app-switch keeps the live session, then close
    /// cleanly — proactively, while there is still comfortably enough time —
    /// once the allowance runs down to `windDownSafetyMargin`. The multiplexer
    /// target is recorded up front so even a forced suspend can reattach. The
    /// session survives the disconnect server-side; the user chooses
    /// reattach-vs-fresh on return.
    ///
    /// Watchdog history: builds 6–26 triggered the whole wind-down FROM the
    /// expiration handler, i.e. network teardown + ActivityKit flush racing
    /// the very deadline the handler announces — structurally 0x8badf00d
    /// bait on device (the simulator never enforces it). The handler is now
    /// a synchronous last resort only.
    /// Seam: true while a pop-out (PiP) window keeps the process running in
    /// the background. While true, the grace/wind-down machinery must NOT
    /// suspend sessions — live monitoring is the feature. Wired to
    /// PiPCoordinator at app init; tests override.
    @ObservationIgnored var pipKeepsProcessAlive: () -> Bool = { false }

    func appDidEnterBackground() {
        guard sessions.contains(where: { $0.state == .connected }) else { return }
        windDownStarted = false
        diagnostics.markBackgrounded()
        // A pop-out is up: iOS keeps the process (and its sockets) alive for
        // the PiP window, so no background task or wind-down. If the pop-out
        // ends while still backgrounded, PiPCoordinator re-enters this method
        // and the normal grace window starts then.
        guard !pipKeepsProcessAlive() else { return }
        // A grace cycle is already in flight (double entry via the PiP-stopped
        // path) — starting a second one would overwrite and leak the task and
        // race two wind-down loops.
        guard backgroundTaskID == .invalid else { return }
        // LAST RESORT — should never fire, because the proactive poll below
        // winds down before the allowance expires. If it does fire, it must
        // be fast, synchronous, and end the task immediately (Apple's
        // contract); anything slower is itself the watchdog kill.
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "aplusterminal.session-grace") { [weak self] in
            self?.handleBackgroundTaskExpiration()
        }
        gracePreambleFinished = false
        graceTask = Task { [weak self] in
            guard let self else { return }
            // Record targets immediately, while definitely still attached —
            // but never unbounded: each recording opens an exec channel, and
            // one stalled channel would otherwise pin this preamble (and the
            // session's record single-flight) for the whole background stay.
            // Abandoning a slow refresh is harmless: the keepalive recorded a
            // target recently and records again on the next connected tick,
            // so the reattach guess is at worst slightly stale.
            let budget = self.backgroundPreambleBudget
            let record = self.recordTargetForGrace
            let connected = self.sessions.filter { $0.state == .connected }
            await Self.raceAgainstTimeout(seconds: budget) {
                for session in connected where session.state == .connected {
                    await record(session)
                }
            }
            self.gracePreambleFinished = true
            // Hold the sockets while watching the allowance; wind down
            // proactively once it drops below the safety margin. Cancelled
            // by a foreground return (sockets stay live — the quick-switch
            // window) or preempted by the expiration handler.
            while !Task.isCancelled {
                // Auto-pop-out can engage a beat AFTER backgrounding (the
                // system starts PiP as part of the app switch): hand the
                // background stay over to PiP and relinquish the task.
                if self.pipKeepsProcessAlive() {
                    self.endBackgroundTask()
                    return
                }
                if self.backgroundTimeRemaining() <= Self.windDownSafetyMargin {
                    await self.windDownProactively()
                    return
                }
                try? await Task.sleep(for: .seconds(self.windDownPollInterval))
            }
        }
    }

    func appWillEnterForeground() {
        // Back within the grace window: sockets are still open, nothing to do.
        graceTask?.cancel()
        graceTask = nil
        endBackgroundTask()
        diagnostics.markForegrounded()
        // The system may have ended the Live Activity while we were suspended
        // (user swipe-dismiss, system cap): the controller's state-stream
        // observer only runs once the process resumes, so reconcile against
        // ActivityKit's ground truth FIRST — a dead handle is dropped, and
        // the refresh below then takes the needsStart path and re-requests
        // the card for the still-open sessions.
        activityController.reconcileExternalEnd()
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

    /// Proactive wind-down, run INSIDE `graceTask` when the remaining
    /// allowance hits the safety margin: suspend sessions cleanly (real SSH
    /// disconnects), flush ActivityKit, then relinquish the background task —
    /// all while there are still ~10s of runway, instead of inside the
    /// expiration handler where this work used to race the watchdog.
    private func windDownProactively() async {
        guard !windDownStarted else { return }
        windDownStarted = true
        diagnostics.markWindDownStarted(trigger: .proactive)
        for session in sessions where session.state == .connected {
            await session.suspend()
        }
        // Each suspend() fires onStateChange → refreshActivity(), whose
        // final push carries the sessions as *paused* (they still count —
        // the app session is open and reattachable) with the hours-long
        // pausedStaleWindow horizon, since nothing runs after iOS
        // suspends us. That mutation must reach ActivityKit before the
        // suspension, or the lock screen keeps claiming connected
        // sessions whose sockets are gone — same flush criticality as
        // PR #76's zero-state wind-down, different final content.
        await activityController.flushActivityUpdates()
        diagnostics.markWindDownCompleted()
        endBackgroundTask()
    }

    /// LAST RESORT — the `beginBackgroundTask` expiration handler. Apple's
    /// contract: be fast and call `endBackgroundTask` promptly; a slow handler
    /// IS the 0x8badf00d kill this redesign eliminates. So this never awaits
    /// anything: it synchronously marks state (`suspendAbruptly` — no network
    /// teardown; iOS closes the sockets with the suspension and reconnect
    /// already handles dead sockets) and ends the task immediately. The
    /// ActivityKit updates enqueued by the state changes are best-effort.
    /// Internal (not private) so the last-resort path is unit-testable —
    /// production's only caller is the expiration handler.
    func handleBackgroundTaskExpiration() {
        graceTask?.cancel()
        graceTask = nil
        // With a pop-out live the allowance never realistically expires; if
        // it somehow does, PiP is what keeps us running — do not kill the
        // monitored sessions, just relinquish the task (fast + synchronous).
        if pipKeepsProcessAlive() {
            endBackgroundTask()
            return
        }
        if !windDownStarted {
            windDownStarted = true
            diagnostics.markWindDownStarted(trigger: .expiration)
        }
        // Also covers an expiration that lands mid-proactive-wind-down: any
        // session the cancelled proactive pass hadn't reached yet is marked
        // suspended here, synchronously; already-suspended ones no-op.
        for session in sessions where session.state == .connected {
            session.suspendAbruptly()
        }
        diagnostics.markWindDownCompleted()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
