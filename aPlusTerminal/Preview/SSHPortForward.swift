import Foundation
import NIOCore
import Network
import Observation
import os

/// How many direct-tcpip channels one forward keeps open at once. A real page
/// opens roughly six parallel sockets per origin (plus an HMR websocket that
/// never closes), so 32 leaves generous headroom — while still capping what a
/// runaway page can cost: every one of these channels is multiplexed onto the
/// *same* TCP socket and the same SSH flow-control budget as the user's live
/// PTY, so an unbounded forward degrades the terminal the user is typing in.
///
/// File-scope rather than only a `static let` on the @MainActor type so the
/// nonisolated `errorDescription` below can read it without an actor hop.
private let forwardChannelLimit = 32

/// DEBUG-only stdout trace of the byte path, so `devicectl process launch
/// --console` can show where a forward stalls on a real device. os_log does
/// not reach that console; print does. Compiled out of release builds.
@inline(__always)
func previewTrace(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("PFWD \(message())")
    #endif
}

enum SSHPortForwardError: LocalizedError {
    /// Neither the preferred port nor an ephemeral loopback port could be
    /// bound. Carries a human-readable reason for the preview sheet.
    case bindFailed(String)
    case channelLimit
    case notConnected

    var errorDescription: String? {
        switch self {
        case .bindFailed(let reason):
            return "Couldn't open a local port for the preview: \(reason)"
        case .channelLimit:
            return "Too many preview connections at once (limit \(forwardChannelLimit))."
        case .notConnected:
            return "The SSH session isn't connected."
        }
    }
}

/// Forwards `remotePort` on the SSH server to a **loopback-only** listener on
/// the phone: one direct-tcpip channel per accepted connection, riding the
/// session the user already authenticated. Nothing outside the device can
/// reach the listener, and the remote side is dialled from the server itself,
/// so no port is ever exposed on either machine's network interface.
///
/// Two design choices are load-bearing and are explained where they happen:
/// the *preferred local port equals the remote port* rule (`bindListener`),
/// and *strict backpressure in both directions* (`ForwardPump` /
/// `ForwardChannelHandler`).
///
/// Isolation: this type coordinates on the main actor, but the bytes never
/// touch it. Network.framework callbacks arrive on `queue`, NIO callbacks on
/// the channel's event loop, and each accepted connection's state lives in a
/// non-isolated `ForwardPump` behind its own lock. The main actor is entered
/// only to accept/refuse a connection and to publish the counters the UI
/// binds to.
@MainActor
@Observable
final class SSHPortForward {
    let remotePort: Int
    /// Bound loopback port; 0 before `start()` succeeds (and again after
    /// `stop()`, since a restarted forward re-binds and re-publishes).
    private(set) var localPort = 0
    /// False when the preferred port was taken and an ephemeral port was used
    /// instead. The UI reads this to warn that live reload will not reconnect
    /// — see `bindListener` for why that is not cosmetic.
    private(set) var matchesRemotePort = true
    private(set) var activeChannels = 0
    static let maxConcurrentChannels = forwardChannelLimit

    private let connection: SSHConnection
    private let log = Logger(subsystem: "com.aaroncx.aplusterminal", category: "preview-forward")
    /// Serial queue for the listener's callbacks. Each accepted connection
    /// gets its own serial queue (see `ForwardPump`) so one stalled socket
    /// can't hold up another's completions.
    private let queue = DispatchQueue(label: "com.aaroncx.aplusterminal.preview-forward", qos: .userInitiated)

    @ObservationIgnored private var listener: NWListener?
    /// The owning reference for every live pair. `ForwardChannelHandler`
    /// holds its pump weakly, so removing the entry here is what finally
    /// releases the pump and its NWConnection.
    @ObservationIgnored private var pumps: [UUID: ForwardPump] = [:]
    /// Latched by `stop()`. `start()` awaits several hops (actor state, the
    /// bind probes) during which the user can dismiss the preview sheet;
    /// every hop re-checks this so a late `start()` can't leave an orphan
    /// listener that nothing will ever cancel.
    @ObservationIgnored private var isStopped = false

    init(remotePort: Int, connection: SSHConnection) {
        self.remotePort = remotePort
        self.connection = connection
    }

    func start() async throws {
        guard listener == nil else { return }
        isStopped = false

        // Deliberately NOT gated on `connection.state` here. Binding a
        // loopback listener is pure local work with no dependency on the SSH
        // session, and keeping it that way is what makes the port-preference
        // and collision-fallback rules unit-testable without standing up a
        // live server. The connectivity check that matters already happens
        // twice on the real path: `TerminalSession.startPreview` refuses
        // unless the session is `.connected`, and `openForward` throws
        // `SSHConnectionError.notConnected` per channel if the client has gone
        // since — which `ForwardPump.run` turns into a clean per-connection
        // teardown.
        guard let listener = await bindListener() else {
            throw SSHPortForwardError.bindFailed(
                "127.0.0.1:\(remotePort) is in use and no ephemeral port was available"
            )
        }
        guard let bound = listener.port.map({ Int($0.rawValue) }), bound > 0 else {
            listener.cancel()
            throw SSHPortForwardError.bindFailed("the listener bound to an unknown port")
        }
        guard !isStopped else {
            listener.cancel()
            return
        }

        // Replace the probe handler (which only reported readiness) with the
        // long-lived one: a listener that fails after ready — the socket was
        // reclaimed, the app was jetsammed out of a background transition —
        // must tear the whole forward down rather than sit there accepting
        // nothing while the WebView spins.
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            let reason = error.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.log.error("preview forward: listener failed: \(reason, privacy: .public)")
                await self.stop()
            }
        }

        previewTrace("bound local=\(bound) remote=\(remotePort) matched=\(bound == remotePort)")
        self.listener = listener
        localPort = bound
        matchesRemotePort = bound == remotePort
        if matchesRemotePort {
            log.info("preview forward: 127.0.0.1:\(bound) → remote 127.0.0.1:\(self.remotePort)")
        } else {
            log.info("preview forward: 127.0.0.1:\(bound) → remote 127.0.0.1:\(self.remotePort) (port mismatch — live reload will not reconnect)")
        }
    }

    /// Async spelling of `stopImmediately()`, for the ordinary teardown paths
    /// that are already in an async context. There is genuinely nothing to
    /// await — see below.
    func stop() async {
        stopImmediately()
    }

    /// Cancels the listener, closes every live channel and cancels every
    /// accepted connection. Idempotent.
    ///
    /// Synchronous on purpose, and that is a requirement rather than a
    /// convenience: `SessionManager`'s background-task expiration handler must
    /// return immediately and can never await network I/O (a slow handler is
    /// itself the 0x8badf00d kill it exists to avoid). Every operation here is
    /// non-blocking — `NWListener.cancel`, `NWConnection.cancel` and
    /// `Channel.close(promise: nil)` all just enqueue work — so the whole
    /// teardown completes within one main-actor hop with nothing left dangling.
    func stopImmediately() {
        isStopped = true
        if let listener {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
        }
        listener = nil

        let live = Array(pumps.values)
        pumps.removeAll()
        activeChannels = 0
        localPort = 0
        matchesRemotePort = true
        for pump in live {
            // Abortive: the user closed the preview, so there is no response
            // body left worth draining and the listener must be gone now.
            pump.shutDown(graceful: false)
        }
        if !live.isEmpty {
            log.info("preview forward: stopped, tore down \(live.count) live channel(s)")
        }
    }

    // MARK: - Binding

    /// Binds the loopback listener, preferring `remotePort` itself.
    ///
    /// **Why the preferred port matters.** Vite and Next hardcode the HMR
    /// websocket target as `localhost:<devPort>`, and dev servers emit
    /// absolute URLs (redirects, `<base>`, asset manifests) using the port
    /// they were started on. When the phone-side port matches, every one of
    /// those references resolves through this same forward with *zero*
    /// rewriting. When it doesn't, the page still loads but its own
    /// references dangle — which is exactly what `matchesRemotePort` exists
    /// to warn about. Never degrade silently.
    ///
    /// Three probes, in this order, and the order is deliberate:
    /// 1. `remotePort`, strict. A genuinely-live foreign listener must be
    ///    able to refuse us; landing elsewhere without noticing is the bug.
    /// 2. `remotePort` with `allowLocalEndpointReuse`. Rescues the common
    ///    self-inflicted failure: probe 1 refused only because *our own*
    ///    previous forward's accepted sockets are still in TIME_WAIT (open
    ///    preview → close → reopen within 2MSL). Reuse does not paper over a
    ///    real conflict — a live listener that did not itself opt into port
    ///    reuse still refuses this bind.
    /// 3. `.any`, which sets `matchesRemotePort = false`.
    ///
    /// Ports below 1024 skip straight to probe 3: iOS refuses privileged
    /// binds outright, so probing them only wastes a round trip.
    private func bindListener() async -> NWListener? {
        if (1024...65535).contains(remotePort), let preferred = NWEndpoint.Port(rawValue: UInt16(remotePort)) {
            if let listener = await bind(to: preferred, allowingReuse: false) {
                return listener
            }
            log.info("preview forward: 127.0.0.1:\(self.remotePort) refused the first bind — retrying with endpoint reuse")
            if let listener = await bind(to: preferred, allowingReuse: true) {
                return listener
            }
            log.error("preview forward: 127.0.0.1:\(self.remotePort) is unavailable — falling back to an ephemeral port")
        }
        return await bind(to: .any, allowingReuse: false)
    }

    private func bind(to port: NWEndpoint.Port, allowingReuse: Bool) async -> NWListener? {
        let parameters = NWParameters.tcp
        // Pinning `requiredLocalEndpoint` to 127.0.0.1 is what makes this a
        // genuinely loopback-only listener. Verified in the phase-0 spike
        // against a wildcard-bound control: the control answered on the
        // device's LAN address, this one refused. The user's dev server is
        // never exposed to the network by the preview.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = allowingReuse
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            // Nagle would add up to 40ms to every small write, and an HMR
            // socket plus a dev server's chunked responses are nothing but
            // small writes.
            tcp.noDelay = true
        }

        guard let listener = try? NWListener(using: parameters) else { return nil }
        // Installed BEFORE start(): a listener that becomes ready with no
        // connection handler drops whatever arrives in that window.
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }

        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trySet() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if once.trySet() { continuation.resume(returning: false) }
                case .waiting:
                    // A loopback listener has no interface to wait for, so
                    // `.waiting` here means the bind itself can't be
                    // satisfied (EADDRINUSE surfaces this way as often as it
                    // does via `.failed`) — and Network.framework will retry
                    // it forever. Treat it as a refusal so the next probe
                    // runs instead of hanging the preview sheet open.
                    if once.trySet() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        guard ready, listener.port != nil else {
            listener.cancel()
            return nil
        }
        return listener
    }

    // MARK: - Accepting

    private func accept(_ local: NWConnection) {
        guard !isStopped, listener != nil else {
            local.cancel()
            return
        }
        guard activeChannels < Self.maxConcurrentChannels else {
            // Refuse immediately rather than queue. Cancelling before start()
            // gives the browser a fast failed subresource, which is far
            // better than parking sockets against a channel budget shared
            // with the user's live PTY.
            log.error("preview forward: channel limit (\(Self.maxConcurrentChannels)) reached — refusing a local connection")
            local.cancel()
            return
        }

        let key = UUID()
        activeChannels += 1
        let connectionNumber = activeChannels
        previewTrace("accept #\(connectionNumber) (active=\(activeChannels))")
        let pump = ForwardPump(
            local: local,
            remotePort: remotePort,
            originatorPort: localPort,
            onFinish: { [weak self] in
                Task { @MainActor in self?.release(key) }
            }
        )
        pumps[key] = pump

        Task { [connection, log, remotePort] in
            do {
                try await pump.run(over: connection)
            } catch {
                log.error("preview forward: opening a channel to 127.0.0.1:\(remotePort) failed: \(error.localizedDescription, privacy: .public)")
                pump.shutDown()
            }
        }
    }

    private func release(_ key: UUID) {
        guard pumps.removeValue(forKey: key) != nil else { return }
        activeChannels = max(0, activeChannels - 1)
    }
}

// MARK: - One accepted connection ↔ one channel

/// The per-connection pump. Deliberately **not** main-actor isolated: every
/// byte in both directions arrives on a Network.framework queue or on the
/// channel's event loop, and routing each chunk through the main actor would
/// add latency and open reordering windows for no benefit. All mutable state
/// sits behind `lock`; the main actor is entered exactly once per pump, via
/// `onFinish`, to decrement the published counter.
private final class ForwardPump: @unchecked Sendable {
    /// Read ceiling for the local→remote direction: large enough that a POST
    /// body or a websocket frame moves in a couple of hops, small enough that
    /// a stalled SSH window can only pin this much memory per connection.
    private static let maxReadLength = 32 * 1024

    private let local: NWConnection
    private let remotePort: Int
    private let originatorPort: Int
    private let onFinish: @Sendable () -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var channel: Channel?
    private var isFinished = false
    /// Whether the local send stream has already been finalised. A second
    /// `.finalMessage` is rejected ~synchronously, and its completion then runs
    /// `local.cancel()` immediately — disarming the very drain the graceful
    /// path exists to provide.
    private var didFinalizeLocal = false

    init(
        local: NWConnection,
        remotePort: Int,
        originatorPort: Int,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.local = local
        self.remotePort = remotePort
        self.originatorPort = originatorPort
        self.onFinish = onFinish
        self.queue = DispatchQueue(
            label: "com.aaroncx.aplusterminal.preview-forward.connection",
            qos: .userInitiated
        )
    }

    private var currentChannel: Channel? {
        lock.withLock { channel }
    }

    /// Brings up the pair: local socket ready → channel open → both
    /// directions pumping. The local socket is started first so that data the
    /// remote sends the instant the channel activates always has somewhere to
    /// go.
    func run(over connection: SSHConnection) async throws {
        guard await startLocal() else {
            shutDown()
            return
        }

        let channel = try await connection.openForward(
            toRemotePort: remotePort,
            // Advisory only (SSH servers log it and otherwise ignore it), so
            // the listener's port is a more useful identifier here than the
            // browser's ephemeral source port.
            originatorPort: originatorPort
        ) { [self] channel in
            // autoRead OFF before a single byte can be delivered. With it on,
            // NIO pulls every frame the SSH window allows and fires
            // channelRead regardless of whether the phone-side socket has
            // drained — invisible on a hello-world page, and an unbounded
            // in-memory queue on a page with real assets. From here the
            // remote→local direction is entirely demand-driven: see
            // `ForwardChannelHandler.resume(on:)`.
            //
            // Citadel installed `DataToBufferCodec` before calling us, so the
            // handler's InboundIn is a plain ByteBuffer and
            // `allowRemoteHalfClosure` is already set.
            channel.setOption(ChannelOptions.autoRead, value: false).flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(ForwardChannelHandler(pump: self))
            }
        }

        previewTrace("channel open, active=\(channel.isActive)")
        guard adopt(channel) else { return }
        receiveFromLocal()
    }

    /// Starts the accepted connection and waits for readiness. The state
    /// handler stays installed afterwards so a later failure or cancellation
    /// still tears the pair down.
    private func startLocal() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            local.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.trySet() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if once.trySet() {
                        continuation.resume(returning: false)
                    } else {
                        self?.shutDown()
                    }
                default:
                    break
                }
            }
            local.start(queue: queue)
        }
    }

    /// Takes ownership of the channel, unless `stop()` already fired while it
    /// was being opened — in which case the channel is closed immediately
    /// rather than left dangling on the SSH connection.
    private func adopt(_ channel: Channel) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        self.channel = channel
        lock.unlock()
        return true
    }

    // MARK: local → remote

    /// Exactly one receive is outstanding at a time, and the next one is
    /// issued **only** from the completion of the channel write it produced.
    /// That single rule is the local→remote backpressure: while the SSH
    /// flow-control window is full, `writeAndFlush`'s future does not
    /// complete, no receive is re-armed, and the kernel's loopback receive
    /// buffer fills and stalls the browser — which is exactly where the stall
    /// belongs.
    private func receiveFromLocal() {
        local.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReadLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                self.shutDown()
                return
            }
            guard let channel = self.currentChannel else {
                self.shutDown()
                return
            }
            if let data, !data.isEmpty {
                previewTrace("local->remote \(data.count)B isComplete=\(isComplete) req=\(Self.firstLine(of: data))")
                channel.writeAndFlush(ByteBuffer(bytes: data)).whenComplete { result in
                    switch result {
                    case .success where isComplete:
                        // The browser finished its request and closed ITS send
                        // side. This is ordinary HTTP — CFNetwork does exactly
                        // this — and it emphatically does NOT mean the exchange
                        // is over: the response has not arrived yet.
                        //
                        // An earlier version called shutDown() here, on the
                        // stated assumption that "no HTTP client half-closes
                        // its request and then waits for a response". That
                        // assumption is false, and it cost a shipped build:
                        // on device every load after the first tore its own
                        // channel down before the server answered, the browser
                        // retried forever ("Loading…"), and a reload surfaced
                        // as NSURLErrorCannotParseResponse. It survived the
                        // Simulator because loopback delivered the request
                        // without the FIN in the same read, so isComplete was
                        // false. Covered now by
                        // `testHalfClosedRequestStillReceivesAResponse`.
                        //
                        // The correct response is to do NOTHING but stop
                        // reading. An HTTP request is self-delimiting (the
                        // blank line ends the head; Content-Length or chunking
                        // ends the body), so the server needs no EOF to answer.
                        // Forwarding one is not just unnecessary, it is
                        // destructive HERE: measured while fixing this, sending
                        // the EOF on via `channel.close(mode: .output)` got the
                        // remote's own EOF back before a single response byte
                        // arrived, and the response was lost. (To be precise
                        // about the mechanism rather than guess at it:
                        // NIOSSH's `.output` close does emit CHANNEL_EOF and
                        // does leave the channel open, so the loss is in what
                        // the far side does with that EOF, not in NIO. Either
                        // way the measurement stands and we simply do not
                        // forward it.)
                        self.awaitRemoteResponse(framing: "coalesced")
                    case .success:
                        self.receiveFromLocal()
                    default:
                        // The write itself failed — the channel is gone.
                        self.shutDown()
                    }
                }
            } else if isComplete {
                // The SAME half-close as the branch above, only split across
                // two receives: the browser wrote its request before this read
                // was armed, or is closing its send side on a socket it had
                // been keeping alive. Identical rule — stop reading, tear
                // NOTHING down.
                //
                // This site is the more damaging of the two. The coalesced one
                // kills the exchange before the response starts (a hang); this
                // one can fire while a response is ALREADY STREAMING, cutting
                // it off mid-headers — which is exactly what surfaced on device
                // as NSURLErrorCannotParseResponse rather than a spinner.
                self.awaitRemoteResponse(framing: "split")
            } else if data == nil {
                // No data, no EOF, no error: the socket is genuinely gone.
                self.shutDown()
            } else {
                self.receiveFromLocal()
            }
        }
    }

    // MARK: remote → local

    /// Hands one inbound chunk to the local socket. `completion` fires on
    /// this pump's queue once the transport has taken the data (so it already
    /// reflects TCP backpressure); the caller hops back to the channel's
    /// event loop before touching its own state.
    func sendToLocal(_ buffer: ByteBuffer, completion: @escaping @Sendable (Bool) -> Void) {
        previewTrace("remote->local \(buffer.readableBytes)B resp=\(Self.firstLine(of: Data(buffer.readableBytesView)))")
        local.send(
            content: Data(buffer.readableBytesView),
            completion: .contentProcessed { error in completion(error == nil) }
        )
    }

    /// The browser has finished sending. Stop reading from it and leave
    /// everything else exactly as it is, so the remote→local pump can deliver
    /// the response. Deliberately not a channel close of any kind — see the
    /// call site.
    /// Two call sites: the FIN can arrive coalesced with the request bytes
    /// (what a real network does — 54,029 of 54,896 requests in the device
    /// log) or in a receive completion of its own (loopback, and keep-alive
    /// reuse). Both must behave identically.
    func awaitRemoteResponse(framing: StaticString) {
        previewTrace("local EOF (\(framing)) -> awaiting response (no teardown)")
    }

    /// The remote end sent SSH EOF — Citadel's `allowRemoteHalfClosure` turned
    /// that into `inputClosed` rather than a channel close. Mirror it as a FIN
    /// on the phone side so a `Connection: close` response terminates cleanly
    /// instead of hanging until the browser's own timeout, and leave the
    /// channel open: the browser may still be writing.
    func halfCloseLocal() {
        previewTrace("remote EOF -> half-closing local")
        lock.lock()
        guard !didFinalizeLocal else { lock.unlock(); return }
        didFinalizeLocal = true
        lock.unlock()
        local.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    // MARK: teardown

    /// How long a graceful teardown waits for the local socket to drain before
    /// giving up and cancelling anyway, so one wedged socket can't hold a
    /// channel slot forever.
    private static let drainTimeout: TimeInterval = 5

    /// First line of an HTTP message, for the trace only.
    static func firstLine(of data: Data) -> String {
        let head = data.prefix(120)
        guard let text = String(data: head, encoding: .utf8) else { return "<binary>" }
        return String(text.prefix(while: { $0 != "\r" && $0 != "\n" }))
    }

    /// Idempotent teardown of one pair. Safe to call from any queue, any
    /// number of times: the channel close and the socket cancel both happen
    /// once, and the main actor is notified once.
    ///
    /// **`graceful` is about not truncating the response.**
    /// `NWConnection.cancel()` is abortive: Apple documents that outstanding
    /// sends whose completion handlers haven't fired yet may never reach the
    /// wire, and measured on this machine a cancel with 16×64KB queued
    /// delivered 320KB of 1MB. That is not a corner case here — when NIOSSH
    /// receives CHANNEL_CLOSE it runs `deliverPendingReads()` and
    /// `notifyChannelInactive()` in the *same* event-loop tick, so every
    /// buffered frame is handed to `sendToLocal` microseconds before
    /// `channelInactive` fires, and none of those completions can have run
    /// yet. Cancelling there truncates the tail of any response the server
    /// ends by closing (`Connection: close`, a finished SSE stream, a Vite
    /// restart) — worst exactly when backpressure is working hardest, i.e. a
    /// real page with real assets.
    ///
    /// So the remote-initiated paths half-close instead and cancel from that
    /// send's completion, which Network orders behind everything already
    /// queued. Only the user-initiated teardown (`stopImmediately`) cancels
    /// abruptly, where dropping bytes is exactly what's wanted.
    func shutDown(graceful: Bool = true) {
        previewTrace("shutDown(graceful: \(graceful))")
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let channel = self.channel
        self.channel = nil
        lock.unlock()

        // A nil promise swallows the `alreadyClosed` this throws when the
        // remote closed first — the overwhelmingly common ordering.
        channel?.close(promise: nil)
        let alreadyFinalized = lock.withLock { () -> Bool in
            let was = didFinalizeLocal
            didFinalizeLocal = true
            return was
        }
        if graceful && !alreadyFinalized {
            local.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [local] _ in local.cancel() }
            )
            // Watchdog: a socket the browser has stopped reading never
            // completes that send. `cancel()` is idempotent, so this is safe
            // alongside the completion above.
            queue.asyncAfter(deadline: .now() + Self.drainTimeout) { [local] in
                local.cancel()
            }
        } else if graceful {
            // Already half-closed by `halfCloseLocal`; the transport is draining
            // on that send's completion. Only arm the watchdog.
            queue.asyncAfter(deadline: .now() + Self.drainTimeout) { [local] in
                local.cancel()
            }
        } else {
            local.cancel()
        }
        onFinish()
    }
}

/// The remote→local half of one pair. Every method here runs on the channel's
/// event loop, so the counters below need no lock — but every re-entry from a
/// Network.framework completion MUST come back through `eventLoop.execute`,
/// which is why `channelRead` captures the loop rather than the context.
private final class ForwardChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    /// Weak on purpose. The pump is owned by `SSHPortForward.pumps`; the pump
    /// owns the channel, the channel owns the pipeline, and the pipeline owns
    /// this handler — a strong reference here would close that cycle and
    /// leave it to NIO's pipeline teardown to break.
    private weak var pump: ForwardPump?
    /// Sends handed to the local socket that have not reported completion.
    /// No further `read()` is issued while this is non-zero: that is the
    /// remote→local backpressure.
    private var pendingSends = 0
    /// A read-cycle finished while sends were still in flight; re-arm once
    /// they drain.
    private var readPending = false
    /// Remote half-close seen; mirror it locally once the in-flight sends
    /// drain, and stop reading.
    private var sawRemoteEOF = false

    init(pump: ForwardPump) {
        self.pump = pump
    }

    func channelActive(context: ChannelHandlerContext) {
        previewTrace("channelActive -> first read()")
        context.fireChannelActive()
        // autoRead is off, so nothing arrives until we ask. This is the only
        // unsolicited read; every later one comes from `resume(on:)`.
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard buffer.readableBytes > 0 else { return }
        guard let pump else {
            context.close(promise: nil)
            return
        }
        // One read() can drain several buffered SSH frames, so several sends
        // can be in flight at once; the counter — not a boolean — is what
        // keeps the next read behind *all* of them.
        pendingSends += 1
        let loop = context.eventLoop
        let channel = context.channel
        pump.sendToLocal(buffer) { [weak self] delivered in
            loop.execute {
                guard let self else { return }
                self.pendingSends -= 1
                guard delivered else {
                    channel.close(promise: nil)
                    return
                }
                self.resume(on: channel)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        previewTrace("readComplete pendingSends=\(pendingSends)")
        readPending = true
        resume(on: context.channel)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? ChannelEvent) == .inputClosed {
            sawRemoteEOF = true
            resume(on: context.channel)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        previewTrace("channelInactive")
        pump?.shutDown()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        previewTrace("errorCaught: \(error)")
        pump?.shutDown()
        context.close(promise: nil)
    }

    /// The single place a read is re-armed. Called after every send
    /// completion and after every read cycle; it is a no-op until the local
    /// socket has actually taken everything we handed it.
    private func resume(on channel: Channel) {
        guard pendingSends == 0 else { return }
        previewTrace("resume: eof=\(sawRemoteEOF) readPending=\(readPending)")
        if sawRemoteEOF {
            // Cleared first so a later `resume` can't emit a second FIN.
            sawRemoteEOF = false
            pump?.halfCloseLocal()
            return
        }
        guard readPending else { return }
        readPending = false
        channel.read()
    }
}
