import Crypto
import MeshyyCore
import XCTest
@testable import aPlusTerminal

/// SSH as the oracle for swipe-to-scroll, on the REAL app objects.
///
/// Over SSH the emulator sees every byte tmux sends, so its belief about mouse
/// mode and the alternate screen is always right. Under meshyy a fresh or resumed
/// emulator learns its modes from replay plus the daemon's `.modes` frame, and
/// `ScrollBridge` routes every swipe on that belief. Every scroll bug so far was
/// that belief diverging from tmux's real state — and every one was "verified" by
/// asserting the belief. This suite asserts the OUTCOME instead:
///
///   1. a real swipe (`ScrollBridge.beginSwipe` / `injectSwipe` — the same `emit`
///      the pan uses) goes out through the real transport, and tmux is asked what
///      it did: `#{pane_in_mode} #{scroll_position}` for wheel events, and a
///      transcriber in the pane reports the bytes it received for arrow keys;
///   2. the meshyy outcome must equal the ssh outcome. SSH is the oracle; any
///      difference is the bug.
///
/// Two `TerminalSession`s per scenario against ONE isolated tmux server
/// (`-L aplus-oracle-<hex>`): A over SSH (a real Citadel pty to this Mac's sshd),
/// B over meshyy (the real launchd meshyyd). Same 1000x700 view, real SwiftTerm,
/// real ScrollBridge — nothing about the route is re-derived here. Exactly one
/// client is attached at a time (the ssh phase ends before the meshyy phase
/// starts), so tmux sizes the window to it.
///
/// The meshyy companion (meshyy `Tests/MeshyyKitTests/ScrollOracleOrderingTests`)
/// measures the same scenario against a REPLICA of SwiftTerm and ScrollBridge;
/// only this suite has the real belief.
///
/// Host-side work (tmux, the relay, daemon queries) goes through SSH exec
/// channels: the simulator cannot spawn host processes. Fixtures come from
/// `./scripts/meshyy-repro-setup.sh`; run the whole thing with
/// `make test-scroll-oracle`. Without the fixtures (CI) every test SKIPS; with
/// them, any harness failure FAILS — a live suite that skips on a broken setup
/// is a green that proves nothing.
///
/// Known divergences that are red on current code are wrapped in a STRICT
/// `XCTExpectFailure` pointing at docs/qa/scroll-divergence-audit.md: they turn
/// into an unexpected pass, and a red test, the moment someone fixes them.
@MainActor
final class ScrollOracleLiveTests: XCTestCase {

    // MARK: - Tests

    func testMouseOnEverySwipeOverMeshyyDoesWhatSSHDoes() async throws {
        try await runScenario(mouse: true)
    }

    func testMouseOffEverySwipeOverMeshyyDoesWhatSSHDoes() async throws {
        try await runScenario(mouse: false)
    }

    /// harness-design §6.2: the one step that can see the `modeEscapes` 1006
    /// ordering. No tmux (tmux always arms 1006 with the mouse family, so both
    /// orderings end armed). A program arms X10 mouse — `?1000h` WITHOUT
    /// `?1006h` — then clears the screen so the replay anchor postdates the
    /// arming, and transcribes what it receives. Over ssh the emulator saw the
    /// arming live; over meshyy the program's session is resumed into a FRESH
    /// emulator that can only learn it from the daemon's modes frame. Correct
    /// synthesis: the wheel bytes reach the program exactly as over ssh.
    func testAnX10ProgramStillGetsWheelBytesAfterAFreshEmulatorResumes() async throws {
        try requireLiveFixtures()
        let control = try await openControl()
        addTeardownBlock { await control.disconnect() }

        // ssh: the emulator sees the arming live.
        let sshLog = "/tmp/aplus-oracle-x10-\(Self.hex(6))-ssh.keys"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: sshLog) }
        let (ssh, _) = try makeSession(meshyy: false)
        try await connect(ssh, meshyy: false)
        ssh.sendInput(Data(Self.x10Program(log: sshLog).utf8))
        try await waitFor(10, "the x10 transcriber never started (ssh)") {
            FileManager.default.fileExists(atPath: sshLog)
        }
        try await waitFor(10, "the ssh emulator never saw ?1000h") {
            ssh.terminalView.getTerminal().mouseMode != .off
        }
        try await Task.sleep(for: .milliseconds(300))
        let sshSwipe = try await x10Swipe(ssh, log: sshLog)
        await ssh.close()

        // meshyy: same program, then a relaunch into a fresh emulator.
        let meshyyLog = "/tmp/aplus-oracle-x10-\(Self.hex(6))-meshyy.keys"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: meshyyLog) }
        let (first, server) = try makeSession(meshyy: true)
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock { await self.killMeshyySessions(withPrefix: prefix, over: control) }
        try await connect(first, meshyy: true)
        first.sendInput(Data(Self.x10Program(log: meshyyLog).utf8))
        try await waitFor(10, "the x10 transcriber never started (meshyy)") {
            FileManager.default.fileExists(atPath: meshyyLog)
        }
        // Not a harness check only: the daemon's live modes frame reaches THIS
        // emulator too, right behind the program's ?1000h. Measured with the
        // pre-#145 synthesis planted (?1006l emitted after the family), this is
        // where the step goes red: the frame disarms even the live emulator.
        try await waitFor(10, "the meshyy emulator does not believe mouse on after the program armed "
                              + "X10 mouse — the modes-frame synthesis disarmed it (1006 ordering?)") {
            first.terminalView.getTerminal().mouseMode != .off
        }
        let second = try await relaunchMeshyy(first, server: server, control: control)
        addTeardownBlock { await second.close() }
        await settle(second, armed: { $0.terminalView.getTerminal().mouseMode != .off })
        let meshyySwipe = try await x10Swipe(second, log: meshyyLog)

        let trace = second.scrollTraceStoreForTesting?.records.last
        let modes = trace?.lastModesFrame?.active ?? []
        print("MEASURE scrollOracle x10-fresh-emulator: ssh \(sshSwipe.summary) | meshyy \(meshyySwipe.summary) "
              + "modesFrame=\(modes)")
        XCTAssertTrue(sshSwipe.received.contains("^[[<64;"),
                      "ORACLE BROKEN: the ssh side's wheel bytes never reached the x10 program\n\(sshSwipe.detail)")
        XCTAssertTrue(Set(modes).contains(1000) && !Set(modes).contains(1006), """
            the step is not what it says: the daemon's modes frame should carry 1000 \
            without 1006 (an X10 program), got \(modes)
            """)
        XCTAssertEqual(meshyySwipe.received, sshSwipe.received, """
            DIVERGENCE x10-fresh-emulator: the program armed X10 mouse; over ssh its \
            wheel bytes arrived, over meshyy a fresh emulator resumed and they did not
            ssh:    \(sshSwipe.detail)
            meshyy: \(meshyySwipe.detail)
            """)
    }

    // MARK: - The scenario

    /// What tmux holds the pane to, per scenario.
    private struct Bench {
        let label: String
        let mouse: Bool
        var conf: String { "/tmp/\(label).conf" }
        var tmux: String { "/opt/homebrew/bin/tmux -L \(label)" }
    }

    /// One swipe's whole record, from either side.
    private struct Swipe {
        let step: String
        let side: String
        let decision: SwipeDecision?
        let bytes: Data
        let before: TmuxState
        let after: TmuxState
        let received: String
        let landedAfter: TimeInterval?
        let trace: ScrollTrace.Record?

        var outcome: Outcome {
            Outcome(inMode: after.inMode, scrollPosition: after.scrollPosition,
                    received: Self.normalized(received))
        }

        /// tmux re-encodes the app's arrows for the pane as a mix of CSI and SS3
        /// depending on how the burst was read (measured in the meshyy companion),
        /// identically over both transports — the COUNT is the fact.
        ///
        /// The Claude Code stand-ins arm ?2031h (theme-change reports), and tmux
        /// answers that with a `CSI ? 997 ; N n` report of its own — pane input
        /// that is not the swipe, measured on both transports alike. Dropped.
        static func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "^[OA", with: "^[[A")
                .replacingOccurrences(of: #"\^\[\[\?997;[0-9]+n"#, with: "", options: .regularExpression)
        }

        var summary: String {
            let route = decision.map { "\($0.mode)" } ?? "nil"
            return "\(outcome) via \(route) sent=\(bytes.count)B landed="
                + (landedAfter.map { "\(Int($0 * 1000))ms" } ?? "never")
        }

        var detail: String {
            let traceJSON = trace.flatMap { try? ScrollTrace.makeEncoder(pretty: false).encode($0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "nil"
            return """
                [\(side) \(step)] decision=\(decision.map { "\($0)" } ?? "nil (no view)")
                  bytes=\(ScrollTrace.hex(bytes))
                  tmux before=\(before) after=\(after)
                  received=\(received.debugDescription) landed=\(landedAfter.map { "\(Int($0 * 1000))ms" } ?? "never")
                  trace=\(traceJSON)
                """
        }
    }

    private struct Outcome: Equatable, CustomStringConvertible {
        let inMode: Int
        let scrollPosition: Int?
        let received: String

        var upArrows: Int { received.components(separatedBy: "^[[A").count - 1 }
        var wheelUps: Int { received.components(separatedBy: "^[[<64;").count - 1 }
        var description: String {
            "{inMode=\(inMode) scroll=\(scrollPosition.map(String.init) ?? "-") "
                + "arrows=\(upArrows) wheels=\(wheelUps) received=\(received.count)B}"
        }
    }

    private struct TmuxState: Equatable, CustomStringConvertible {
        let inMode: Int
        let scrollPosition: Int?
        let alternateOn: Int
        let mouseAny: Int
        let history: Int
        let clients: Int

        static let unknown = TmuxState(inMode: -1, scrollPosition: nil, alternateOn: -1,
                                       mouseAny: -1, history: -1, clients: -1)
        var description: String {
            "{in_mode=\(inMode) scroll=\(scrollPosition.map(String.init) ?? "-") alt=\(alternateOn) "
                + "mouse_any=\(mouseAny) history=\(history) clients=\(clients)}"
        }
    }

    /// What the pane runs under each step's swipe.
    private enum PaneProgram {
        /// A plain non-alt, non-mouse program (the shell's shape).
        case plain
        /// Inline Claude Code. MEASURED 2026-10-11 on this Mac, Claude Code
        /// 2.1.296 with `--settings '{"tui":"default"}'`, raw pane output via
        /// tmux pipe-pane: it sets ?1004h ?2004h ?2031h ?25l/h and NOTHING else —
        /// no alternate screen, no mouse tracking. So under tmux `mouse on` a
        /// wheel over it enters copy mode, exactly like a shell.
        case claudeInline
        /// Fullscreen Claude Code (`"tui": "fullscreen"`, this Mac's and
        /// Aaron's configured renderer — his panes read alt=1 mouse_any=1).
        /// MEASURED the same way: ?1049h ?1000h ?1002h ?1003h ?1006h ?1004h
        /// ?2004h ?2031h. Under tmux `mouse on` tmux forwards the wheel INTO the
        /// program as SGR events instead of entering copy mode.
        case claudeFullscreen

        var arming: String {
            switch self {
            case .plain: ""
            case .claudeInline: #"\033[?1004h\033[?2004h\033[?2031h\033[?25l"#
            case .claudeFullscreen:
                #"\033[?1049h\033[?1000h\033[?1002h\033[?1003h\033[?1006h\033[?1004h\033[?2004h\033[?2031h"#
            }
        }
    }

    /// The scripted step list, run for the ssh side, then the meshyy side.
    private func runScenario(mouse: Bool) async throws {
        try requireLiveFixtures()
        let control = try await openControl()
        addTeardownBlock { await control.disconnect() }
        let bench = Bench(label: "aplus-oracle-\(Self.hex(6))", mouse: mouse)
        try await startTmux(bench, over: control)
        addTeardownBlock {
            // kill-server leaves its socket file behind: remove that too.
            _ = try? await self.exec("sock=$(\(bench.tmux) display -p '#{socket_path}' 2>/dev/null); "
                                         + "\(bench.tmux) kill-server; rm -f \"$sock\" \(bench.conf) "
                                         + "/tmp/\(bench.label)-*.keys",
                                     over: control)
        }
        let variant = mouse ? "mouse-on" : "mouse-off"
        var oracle: [String: Swipe] = [:]

        // ---------------- ssh phase: the oracle ----------------
        var a = try makeSession(meshyy: false).0
        try await connect(a, meshyy: false)
        try await attachTmux(a, bench, control: control)
        await settle(a, bench)

        // 1. attach
        oracle["attach"] = try await swipe(a, "attach", bench, control: control)

        // 2. keyboard show/hide ×5: tmux pulses its outer mouse modes on every
        // WINCH; the swipe goes the instant the keyboard is dismissed.
        for cycle in 0..<Self.keyboardCycles {
            let step = "keyboard#\(cycle)"
            oracle[step] = try await keyboardCycleThenSwipe(a, step, bench, control: control)
        }

        // 3. relaunch: a new emulator; over ssh that is a new shell and a re-attach.
        await a.close()
        try await waitForClients(0, bench, control: control)
        a = try makeSession(meshyy: false).0
        try await connect(a, meshyy: false)
        try await attachTmux(a, bench, control: control)
        await settle(a, bench)
        oracle["relaunch"] = try await swipe(a, "relaunch", bench, control: control)

        // 4. reconnect mid output burst.
        try await startBurst(bench, control: control)
        try await Task.sleep(for: .milliseconds(500))
        await a.suspend()
        try await Task.sleep(for: .milliseconds(300))
        let sshMidBurst = try await paneCommand(bench, control: control) != "dd"
        await a.reconnect(maxAttempts: 1)
        try require(a.state == .connected && a.meshyy == nil,
                    "the ssh reconnect failed: \(a.lastError ?? "\(a.state)")")
        // A reconnected ssh tab is a fresh shell (profile "none"): re-attach.
        try await attachTmux(a, bench, control: control)
        try await waitForBurstToFinish(bench, control: control)
        await settle(a, bench)
        oracle["reconnect-mid-burst"] = try await swipe(a, "reconnect-mid-burst", bench, control: control)

        // 6/7. Claude Code stand-ins (step 5, the path drop, is meshyy-only).
        oracle["claude-inline"] = try await swipe(a, "claude-inline", bench, program: .claudeInline,
                                                  control: control)
        oracle["claude-fullscreen"] = try await swipe(a, "claude-fullscreen", bench,
                                                      program: .claudeFullscreen, control: control)
        await a.close()
        try await waitForClients(0, bench, control: control)

        // The oracle must itself be right, or every comparison below is noise.
        for (step, record) in oracle.sorted(by: { $0.key < $1.key }) {
            let program: PaneProgram = step == "claude-fullscreen" ? .claudeFullscreen : .plain
            XCTAssertTrue(isCorrect(record.outcome, mouse: mouse, program: program),
                          "ORACLE BROKEN at \(variant) \(step): ssh did not scroll correctly "
                              + "(\(expectedText(mouse: mouse, program: program)))\n\(record.detail)")
        }

        // ---------------- meshyy phase: the subject ----------------
        let made = try makeSession(meshyy: true)
        var b = made.0
        let server = made.1
        let prefix = MeshyyTransport.groupPrefix(serverID: server.id)
        addTeardownBlock { await self.killMeshyySessions(withPrefix: prefix, over: control) }
        try await connect(b, meshyy: true)
        try await attachTmux(b, bench, control: control)
        await settle(b, bench)

        // 1. attach
        judge("attach", oracle["attach"], try await swipe(b, "attach", bench, control: control), bench)

        // 2. keyboard show/hide ×5
        for cycle in 0..<Self.keyboardCycles {
            let step = "keyboard#\(cycle)"
            judge(step, oracle[step], try await keyboardCycleThenSwipe(b, step, bench, control: control), bench)
        }

        // 3. relaunch: suspend (the app is killed in the background), then a
        // brand-new TerminalSession — a fresh emulator — resumes the same daemon
        // session by name. tmux's client inside the daemon's pty never detached,
        // so nothing re-arms the outer terminal: replay + the modes frame only.
        b = try await relaunchMeshyy(b, server: server, control: control)
        await settle(b, bench)
        judge("relaunch", oracle["relaunch"], try await swipe(b, "relaunch", bench, control: control), bench)

        // 4. reconnect mid output burst: same TerminalSession, but establish()
        // resets the emulator before the reattach replays what was missed.
        try await startBurst(bench, control: control)
        try await Task.sleep(for: .milliseconds(500))
        await b.suspend()
        try await Task.sleep(for: .milliseconds(300))
        let meshyyMidBurst = try await paneCommand(bench, control: control) != "dd"
        await b.reconnect(maxAttempts: 1)
        try require(b.state == .connected && b.meshyy != nil,
                    "the meshyy reconnect failed or fell back to ssh: \(b.lastError ?? "\(b.state)")")
        try await waitForBurstToFinish(bench, control: control)
        await settle(b, bench)
        XCTAssertTrue(sshMidBurst && meshyyMidBurst, """
            a reconnect landed after the burst had finished, so this step tested an idle \
            resume: ssh=\(sshMidBurst) meshyy=\(meshyyMidBurst)
            """)
        judge("reconnect-mid-burst", oracle["reconnect-mid-burst"],
              try await swipe(b, "reconnect-mid-burst", bench, control: control), bench)

        // NOT a step here: a ring overrun. MEASURED 2026-10-12 with an overrun
        // step in this slot (4 MiB ring evicted past the client in ~10-12 s by
        // an unpaced full-screen awk flood): the overrun swipe itself matched
        // ssh in both variants, but every run afterwards the test host's shared
        // com.apple.network.connections queue pegged a core for 28 s+
        // (nw_flow_disconnected -> nw_flow_process_input_frames ->
        // dispatch_data_create_concat), so the next QUIC dial timed out at 4 s
        // and the tab fell back to ssh — a real defect, not a known divergence,
        // reported for its own fix rather than hidden in this suite. Repro:
        // ~/Developer/cc-sessions/scroll-evidence/app-oracle-ring-overrun-step.patch

        // 5. path drop (meshyy only; the oracle is ssh's step-1 outcome).
        try await pathDrop(b, bench, oracle: oracle["attach"], control: control)

        // 6/7. Claude Code stand-ins.
        judge("claude-inline", oracle["claude-inline"],
              try await swipe(b, "claude-inline", bench, program: .claudeInline, control: control), bench)
        judge("claude-fullscreen", oracle["claude-fullscreen"],
              try await swipe(b, "claude-fullscreen", bench, program: .claudeFullscreen, control: control),
              bench, program: .claudeFullscreen)
        await b.close()
    }

    private static let keyboardCycles = 5
    /// What a keyboard takes off a 700-point terminal.
    private static let keyboardHeight: CGFloat = 220

    private func keyboardCycleThenSwipe(
        _ session: TerminalSession, _ step: String, _ bench: Bench, control: SSHConnection
    ) async throws -> Swipe {
        let transcript = try await preparePane(bench, program: .plain, control: control)
        let fullHeight = try await windowHeight(bench, control: control)
        let full = session.terminalView.frame
        session.terminalView.frame = CGRect(x: 0, y: 0, width: full.width,
                                            height: full.height - Self.keyboardHeight)
        session.terminalView.layoutIfNeeded()
        // Up long enough for tmux to apply the size and pulse the modes.
        try await Task.sleep(for: .milliseconds(800))
        session.terminalView.frame = full
        session.terminalView.layoutIfNeeded()
        // The swipe goes the instant tmux has APPLIED the dismiss — exactly when
        // its disarm/re-arm pulse is in flight back to the client, the window a
        // stale belief would show in. Not before: tmux takes input it reads ahead
        // of a resize its client has not reported yet, on ANY transport (the
        // meshyy companion measured it; here the ssh oracle itself came back
        // "copy mode, scrolled 0" once in ten), so swiping into that race
        // measures tmux, not the transport.
        let by = Date().addingTimeInterval(5)
        while try await windowHeight(bench, control: control) != fullHeight {
            try require(Date() < by, "tmux never applied the keyboard dismiss")
        }
        return try await fireSwipe(session, step, bench, transcript: transcript, control: control)
    }

    // MARK: - Path drop

    /// Two legs, both meshyy-only (the oracle is ssh's step-1 outcome: over TCP
    /// a stalled path only delays bytes, in order):
    ///
    ///   path-drop    a 4 s black hole on a host UDP relay between the app and the
    ///                daemon (`kill -USR1`), on a path that then heals;
    ///   path-change  the relay the session rides is frozen for good
    ///                (`kill -STOP`: datagrams vanish, nothing is refused) and
    ///                every later bootstrap dials a second relay — a Wi-Fi to
    ///                cellular move with no connection migration.
    ///
    /// A swipe goes out 0.5 s into each, and the eventual outcome is judged
    /// within 20 s. A MEASURE line records whether it landed late, was lost, or
    /// errored, with the transport state and inbound-frame age the trace
    /// recorded at the swipe and the tab's state changes through the recovery.
    private func pathDrop(
        _ session: TerminalSession, _ bench: Bench, oracle: Swipe?, control: SSHConnection
    ) async throws {
        let first = try await startRelay(bench, tag: "chaos-a", control: control)
        let second = try await startRelay(bench, tag: "chaos-b", control: control)
        addTeardownBlock { @MainActor in
            MeshyyTransport.bootstrapRewriteForTesting = nil
            for relay in [first, second] {
                _ = try? await self.exec("kill -9 \(relay.pid) 2>/dev/null; rm -f \(relay.pidfile) \(relay.outfile)",
                                         over: control)
            }
        }
        // Stays installed (and the relay stays up) for the rest of the scenario:
        // the session's connection runs THROUGH the relay from here on, and
        // tearing it down mid-scenario would be an unplanned path drop.
        let firstPort = first.port
        MeshyyTransport.bootstrapRewriteForTesting = { $0.port = firstPort }

        // Put the live session behind the relay: a reattach re-bootstraps, and
        // the rewrite points its QUIC dial at the relay.
        await session.suspend()
        await session.reconnect(maxAttempts: 1)
        try require(session.state == .connected && session.meshyy != nil,
                    "could not reattach through the relay: \(session.lastError ?? "\(session.state)")")
        await settle(session, bench)

        // The healing hole's swipe fate is MEASURED, not asserted: on current code
        // it is a race, not a result. The app abandons the stalled connection when
        // the heartbeat declares it dead (~3.2-3.9 s) and redials; the swipe still
        // lands only if the abandoned connection's own retransmission gets through
        // the healed path before it is torn down. Measured 2026-10-11 over six
        // runs (mouse on): delivered late at 5.29-5.48 s three times, lost three.
        // No strict expectation can hold either fate, so the leg asserts what is
        // deterministic (the bytes left, the session recovers, the next swipe
        // scrolls) and the loss itself is asserted by path-change below, where
        // the old path never returns and the swipe is lost every time.
        try await dropLeg("path-drop", session, bench, oracle: oracle, judgeSwipe: false, control: control) {
            _ = try await self.exec("kill -USR1 \(first.pid)", over: control)
        }
        let secondPort = second.port
        try await dropLeg("path-change", session, bench, oracle: oracle, control: control) {
            _ = try await self.exec("kill -STOP \(first.pid)", over: control)
            MeshyyTransport.bootstrapRewriteForTesting = { $0.port = secondPort }
        }
    }

    private func dropLeg(
        _ step: String, _ session: TerminalSession, _ bench: Bench, oracle: Swipe?,
        judgeSwipe: Bool = true, control: SSHConnection, impair: () async throws -> Void
    ) async throws {
        let variant = bench.mouse ? "mouse-on" : "mouse-off"
        let transcript = try await preparePane(bench, program: .plain, control: control)
        let reconnectsBefore = session.reconnectAttempts
        try await impair()
        let hole = Date()
        try await Task.sleep(for: .milliseconds(500))

        // Watch the tab's state through the hole and the recovery.
        let timeline = StateTimeline(initial: "\(session.state)")
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                timeline.note("\(session.state)", at: Date().timeIntervalSince(hole))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let dropped = try await fireSwipe(session, step, bench, transcript: transcript,
                                          control: control, deadline: 20)
        // Through the recovery even when nothing was sent, so the timeline says
        // whether the tab noticed the drop at all.
        var recovery: Error?
        do {
            try await waitFor(20, "\(step): the session never came back over meshyy") {
                Date().timeIntervalSince(hole) > 6 && session.state == .connected && session.meshyy != nil
            }
        } catch {
            recovery = error
        }
        watcher.cancel()

        let record = dropped.trace
        let fate: String
        if let record, record.sendFailed > 0 {
            fate = "errored (\(record.lastSendError ?? "?"))"
        } else if dropped.bytes.isEmpty {
            fate = "nothing sent (route \(dropped.decision.map { "\($0.mode)" } ?? "nil"))"
        } else if isCorrect(dropped.outcome, mouse: bench.mouse, program: .plain), let landed = dropped.landedAfter {
            fate = "delivered late, \(Int((landed + 0.5) * 1000))ms after the hole opened"
        } else if dropped.landedAfter == nil {
            fate = "lost"
        } else {
            fate = "garbled"
        }
        print("MEASURE scrollOracle \(variant) \(step): fate=\(fate) "
              + "transportStateAtSwipe=\(record?.transportState.rawValue ?? "nil") "
              + "inboundAgeAtSwipe=\(record?.msSinceLastInboundFrame.map { "\($0)ms" } ?? "nil") "
              + "sendOK=\(record?.sendOK ?? -1) sendFailed=\(record?.sendFailed ?? -1) "
              + "reconnects=\(session.reconnectAttempts - reconnectsBefore) "
              + "timeline=\(timeline.entries.isEmpty ? "none" : timeline.entries.joined(separator: ",")) "
              + "recovered=\(recovery == nil) holeOpenedAt=\(hole.formatted(.iso8601))")
        if let recovery {
            // Recorded above either way; a tab that comes back over plain ssh
            // (or not at all) is a failure, never a skip.
            throw Failure("\(recovery) — state=\(session.state) meshyy=\(session.meshyy?.sessionName ?? "nil") "
                          + "unavailable=\(session.meshyyUnavailable ?? "nil") error=\(session.lastError ?? "nil")")
        }
        // Proof the hole hit THIS connection: with heartbeats every second, a
        // healthy session is never this quiet.
        XCTAssertGreaterThanOrEqual(record?.msSinceLastInboundFrame ?? 0, 300, """
            \(step): the impairment never reached the session's connection (inbound frames \
            kept arriving) — the relay is not in the path, so this step tested nothing
            """)
        if judgeSwipe {
            judge(step, oracle, dropped, bench)
        } else if let oracle {
            print("MEASURE scrollOracle \(variant) \(step): ssh \(oracle.summary) | meshyy \(dropped.summary) "
                  + "(fate measured, not asserted)")
            if !dropped.bytes.isEmpty {
                XCTAssertEqual(record?.sendOK, 1, "\(step): the swipe never left the app\n\(dropped.detail)")
                XCTAssertEqual(record?.sendFailed, 0, "\(step): the send errored\n\(dropped.detail)")
            }
        }

        // The next swipe once the session is back: none may stay dead.
        await settle(session, bench)
        judge("\(step)-after", oracle,
              try await swipe(session, "\(step)-after", bench, control: control), bench)
    }

    /// The tab's state changes through a path drop, timed from the hole.
    private final class StateTimeline {
        private(set) var entries: [String] = []
        private var last: String
        init(initial: String) { last = initial }
        func note(_ state: String, at offset: TimeInterval) {
            guard state != last else { return }
            entries.append("\(state)@\(Int(offset * 1000))ms")
            last = state
        }
    }

    private struct Relay {
        let port: UInt16
        let pid: Int
        let pidfile: String
        let outfile: String
    }

    /// Starts `meshyy-chaos udp` on the host in front of the daemon's QUIC port.
    private func startRelay(_ bench: Bench, tag: String, control: SSHConnection) async throws -> Relay {
        // The daemon binds its QUIC port once per process: learn it from a
        // throwaway session's bootstrap, then end that session.
        let probe = "aplus-oracle-portprobe-\(Self.hex(6))"
        let json = try await exec(MeshyyTransport.daemonCommand("attach --session \(probe) --json"),
                                  over: control)
        _ = try? await exec(MeshyyTransport.daemonCommand("kill \(probe)"), over: control)
        let daemonPort = try BootstrapResponse.parse(json).port

        let pidfile = "/tmp/\(bench.label)-\(tag).pid"
        let outfile = "/tmp/\(bench.label)-\(tag).out"
        _ = try await exec("""
            nohup meshyy-chaos udp --target 127.0.0.1:\(daemonPort) --rtt 0 --listen 0 \
            --pidfile \(pidfile) --blackhole-on-usr1 4 > \(outfile) 2>&1 < /dev/null &
            """, over: control)
        var port: UInt16?
        var pid: Int?
        try await waitFor(10, "the relay never reported its port (is ~/bin/meshyy-chaos installed?)") {
            let out = (try? String(contentsOfFile: outfile, encoding: .utf8)) ?? ""
            port = out.split(separator: "\n").first.flatMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            pid = ((try? String(contentsOfFile: pidfile, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyInt
            return port != nil && pid != nil
        }
        return Relay(port: port!, pid: pid!, pidfile: pidfile, outfile: outfile)
    }

    // MARK: - Judging

    /// The intended outcome of a 3-tick swipe up, independent of transport.
    private func isCorrect(_ outcome: Outcome, mouse: Bool, program: PaneProgram) -> Bool {
        if program == .claudeFullscreen {
            // The pane armed mouse tracking itself, so tmux forwards the wheel
            // INTO it as SGR events. With `mouse on` that is tmux's WheelUpPane
            // binding; with `mouse off` — MEASURED here, 2026-10-11 — tmux arms
            // the OUTER terminal's mouse for the active pane's sake and passes
            // the events through. Either way: no copy mode, three wheel-ups.
            return outcome.inMode == 0 && outcome.wheelUps == 3
        }
        if !mouse {
            // tmux owns the outer alternate screen and arms no mouse: arrow keys,
            // 3 per tick, reach the program, and nothing else does.
            let rest = outcome.received.replacingOccurrences(of: "^[[A", with: "")
            return outcome.inMode == 0 && outcome.upArrows == 9 && rest.isEmpty
        }
        return outcome.inMode == 1 && (outcome.scrollPosition ?? 0) > 0 && outcome.received.isEmpty
    }

    private func expectedText(mouse: Bool, program: PaneProgram) -> String {
        if program == .claudeFullscreen { return "3 SGR wheel-ups forwarded to the program" }
        return mouse ? "copy mode entered, scroll position > 0" : "exactly 9 Up arrows to the program"
    }

    /// Asserts (1) the meshyy OUTCOME is a correct scroll and (2) it equals the
    /// ssh outcome. Known deferred divergences run inside a strict expected
    /// failure — never loosened.
    private func judge(_ step: String, _ oracle: Swipe?, _ subject: Swipe, _ bench: Bench,
                       program: PaneProgram = .plain) {
        let variant = bench.mouse ? "mouse-on" : "mouse-off"
        guard let oracle else {
            XCTFail("no ssh record for \(step)")
            return
        }
        print("MEASURE scrollOracle \(variant) \(step): ssh \(oracle.summary) | meshyy \(subject.summary)")
        let correct = isCorrect(subject.outcome, mouse: bench.mouse, program: program)
        let message = """
            DIVERGENCE at \(variant) \(step) — expected \(expectedText(mouse: bench.mouse, program: program))
            ssh:    \(oracle.detail)
            meshyy: \(subject.detail)
            """
        let assertions = {
            XCTAssertTrue(correct, "OUTCOME: meshyy did not scroll\n" + message)
            XCTAssertEqual(subject.outcome, oracle.outcome, "meshyy != ssh\n" + message)
        }
        if let known = Self.knownDivergence(step: step, mouse: bench.mouse) {
            let options = XCTExpectedFailure.Options()
            options.isStrict = true
            XCTExpectFailure(known, options: options) { assertions() }
        } else {
            assertions()
        }
    }

    /// The divergences deliberately deferred to the PR C audit. Each is red on
    /// current code; a strict expected failure makes a fix show up as an
    /// unexpected pass instead of passing silently.
    private static func knownDivergence(step: String, mouse: Bool) -> String? {
        // claude-fullscreen is absent on purpose: its pane arms mouse tracking,
        // tmux arms the outer terminal for it, the modes frame carries that to a
        // fresh emulator, and the route is the wheel — measured equal to ssh.
        if !mouse, ["relaunch", "reconnect-mid-burst", "path-drop-after",
                    "path-change", "path-change-after", "claude-inline"].contains(step) {
            return """
                KNOWN (deferred): MeshyyTransport ignores .screenMode, and establish() resets \
                the emulator, so after the first relaunch/reconnect the meshyy emulator believes \
                the primary screen while tmux (mouse off) holds the alternate one; ScrollBridge \
                routes .native and sends nothing where ssh sends arrow keys. The wrong belief \
                persists for every later step — nothing re-sends ?1049h until tmux re-attaches. \
                See docs/qa/scroll-divergence-audit.md
                """
        }
        if mouse, step == "path-change" {
            // Lost every time measured. On a path that HEALS (path-drop) the same
            // swipe races the abandoned connection's retransmission — see there.
            return """
                KNOWN (deferred): a swipe written into a QUIC path that never returns is \
                lost. The heartbeat declares the path dead, the app redials over a new path \
                (no connection migration), and nothing carries input written into the \
                abandoned connection to the new one. See docs/qa/scroll-divergence-audit.md
                """
        }
        return nil
    }

    // MARK: - Swiping

    private func swipe(
        _ session: TerminalSession, _ step: String, _ bench: Bench,
        program: PaneProgram = .plain, control: SSHConnection
    ) async throws -> Swipe {
        let transcript = try await preparePane(bench, program: program, control: control)
        return try await fireSwipe(session, step, bench, transcript: transcript, control: control)
    }

    /// One real swipe through the real bridge, then tmux is asked what it did.
    /// Polls until the effect has been stable, bounded by `deadline`.
    private func fireSwipe(
        _ session: TerminalSession, _ step: String, _ bench: Bench,
        transcript: Prepared, control: SSHConnection, deadline: TimeInterval = 6
    ) async throws -> Swipe {
        let bridge = try XCTUnwrap(session.scrollBridge)
        let decision = bridge.beginSwipe()
        let bytes = bridge.injectSwipe(ticks: 3, up: true, at: CGPoint(x: 500, y: 300))
        bridge.endSwipe()
        let sentAt = Date()
        let side = session.usesMeshyy ? "meshyy" : "ssh"
        let trace = session.scrollTraceStoreForTesting?.records.last

        // Nothing sent: there is nothing to wait for beyond a beat that would
        // show a spontaneous change.
        let budget = bytes.isEmpty ? 1.5 : deadline
        var state = transcript.before
        var received = ""
        var landed: TimeInterval?
        var lastChange = Date()
        var lastSeen: (TmuxState, String)?
        while Date().timeIntervalSince(sentAt) < budget {
            state = try await tmuxState(bench, control: control)
            received = Self.read(transcript.path)
            // Normalized: the stand-ins' own theme report is not the swipe
            // landing, and must not start the stability clock.
            let effect = state.inMode != 0 || !Swipe.normalized(received).isEmpty
            if effect, landed == nil { landed = Date().timeIntervalSince(sentAt) }
            if lastSeen.map({ $0.0 != state || $0.1 != received }) ?? true {
                lastSeen = (state, received)
                lastChange = Date()
            }
            // Stable for 600 ms after something happened: done.
            if effect, Date().timeIntervalSince(lastChange) > 0.6 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // The trace store's copy has the send outcome filled in by now.
        let finalTrace = trace.flatMap { record in
            session.scrollTraceStoreForTesting?.records.first { $0.id == record.id }
        } ?? trace
        return Swipe(step: step, side: side, decision: decision, bytes: bytes,
                     before: transcript.before, after: state, received: received,
                     landedAfter: landed, trace: finalTrace)
    }

    private struct Prepared {
        let path: String
        let before: TmuxState
    }

    /// Resets the pane between swipes: out of copy mode, a fresh transcriber
    /// with fresh scrollback beneath it. Asserts there IS scrollback to scroll
    /// — a swipe over an empty history "passes" by doing nothing.
    private func preparePane(_ bench: Bench, program: PaneProgram, control: SSHConnection) async throws -> Prepared {
        let path = "/tmp/\(bench.label)-\(Self.hex(8)).keys"
        // Every program starts from a pane with nothing armed, whatever the last
        // step's stand-in left behind.
        let reset = #"\033[?1049l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l\033[?2031l\033[?25h"#
        let line = "printf '\(reset)'; seq 1 400; printf '\(program.arming)'; "
            + "stty -icanon -echo min 1; dd bs=1 of=\(path) 2>/dev/null; stty sane"
        try await paneRun(line, bench, control: control)
        var state = TmuxState.unknown
        try await waitFor(15, "the pane's transcriber never started") {
            FileManager.default.fileExists(atPath: path)
        }
        let by = Date().addingTimeInterval(10)
        repeat {
            state = try await tmuxState(bench, control: control)
            if state.history >= 15, state.inMode == 0,
               try await paneCommand(bench, control: control) == "dd" { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < by
        try require(state.history >= 15 && state.inMode == 0,
                    "no scrollback to scroll (or stuck in copy mode) before the swipe: \(state)")
        // Let the repaint reach the app before the swipe.
        try await Task.sleep(for: .milliseconds(400))
        return Prepared(path: path, before: state)
    }

    /// Stops whatever the pane runs and types `line` at its shell, out of band.
    private func paneRun(_ line: String, _ bench: Bench, control: SSHConnection) async throws {
        _ = try await exec("""
            \(bench.tmux) send-keys -t scroll -X cancel 2>/dev/null; \
            \(bench.tmux) send-keys -t scroll C-c; sleep 0.2; \
            \(bench.tmux) clear-history -t scroll; \
            \(bench.tmux) send-keys -t scroll -l \(Self.quoted(line)) \\; send-keys -t scroll Enter
            """, over: control)
    }

    private func startBurst(_ bench: Bench, control: SSHConnection) async throws {
        try await paneRun("i=0; while [ $i -lt 400 ]; do clear; seq $i $((i+40)); sleep 0.01; "
                          + "i=$((i+1)); done; stty -icanon -echo min 1; dd bs=1 of=/dev/null 2>/dev/null",
                          bench, control: control)
    }

    private func waitForBurstToFinish(_ bench: Bench, control: SSHConnection) async throws {
        let by = Date().addingTimeInterval(60)
        while Date() < by {
            if try await paneCommand(bench, control: control) == "dd" { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure("the output burst never finished")
    }

    // MARK: - tmux

    private func startTmux(_ bench: Bench, over control: SSHConnection) async throws {
        let conf = [
            "set -g mouse \(bench.mouse ? "on" : "off")",
            // No status line: wheel-on-status is previous/next-window, a confound.
            "set -g status off",
            "set -g escape-time 0",
            "set -g history-limit 5000",
            "set -g default-shell /bin/sh",
        ]
        _ = try await exec("""
            test -x /opt/homebrew/bin/tmux && \
            printf '%s\\n' \(conf.map(Self.quoted).joined(separator: " ")) > \(bench.conf) && \
            \(bench.tmux) -f \(bench.conf) new-session -d -s scroll -x 120 -y 40
            """, over: control)
    }

    private func attachTmux(_ session: TerminalSession, _ bench: Bench, control: SSHConnection) async throws {
        _ = try? await exec("\(bench.tmux) detach-client -s scroll", over: control)
        try await waitForClients(0, bench, control: control)
        session.sendInput(Data("\(bench.tmux) attach -t scroll\n".utf8))
        try await waitForClients(1, bench, control: control)
    }

    private func waitForClients(_ count: Int, _ bench: Bench, control: SSHConnection) async throws {
        let by = Date().addingTimeInterval(20)
        var seen = -1
        while Date() < by {
            seen = try await tmuxState(bench, control: control).clients
            if seen == count { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Failure("tmux never had \(count) client(s) attached (has \(seen))")
    }

    private func tmuxState(_ bench: Bench, control: SSHConnection) async throws -> TmuxState {
        // scroll_position is EMPTY outside copy mode, hence the brackets.
        let out = try await exec(
            "\(bench.tmux) display -p -t scroll "
                + "'#{pane_in_mode} [#{scroll_position}] #{alternate_on} #{mouse_any_flag} #{history_size}'"
                + "; \(bench.tmux) list-clients -t scroll | wc -l",
            over: control)
        let fields = out.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 6, fields[1].hasPrefix("["), fields[1].hasSuffix("]"),
              let inMode = Int(fields[0]), let alt = Int(fields[2]), let mouseAny = Int(fields[3]),
              let history = Int(fields[4]), let clients = Int(fields[5])
        else { throw Failure("unreadable tmux state: \(out.debugDescription)") }
        return TmuxState(inMode: inMode, scrollPosition: Int(fields[1].dropFirst().dropLast()),
                         alternateOn: alt, mouseAny: mouseAny, history: history, clients: clients)
    }

    private func windowHeight(_ bench: Bench, control: SSHConnection) async throws -> Int {
        let out = try await exec("\(bench.tmux) display -p -t scroll '#{window_height}'", over: control)
        guard let height = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("unreadable window_height: \(out.debugDescription)")
        }
        return height
    }

    private func paneCommand(_ bench: Bench, control: SSHConnection) async throws -> String {
        try await exec("\(bench.tmux) display -p -t scroll '#{pane_current_command}'", over: control)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sessions

    private func makeSession(meshyy: Bool, reusing existing: Server? = nil) throws -> (TerminalSession, Server) {
        let pem = try String(contentsOfFile: "/tmp/aplus-probe-key.pem", encoding: .utf8)
        let suffix = UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory
        let keyStore = KeyStore(
            secrets: InMemorySecretStore(),
            metadataURL: temporary.appendingPathComponent("oracle-keys-\(suffix).json")
        )
        let key = try keyStore.importKey(named: "probe", openSSHPrivateKey: pem)
        let serverStore = ServerStore(fileURL: temporary.appendingPathComponent("oracle-servers-\(suffix).json"))
        // `reusing` models a relaunch: the SAME server identity (its id is the
        // daemon group prefix), fresh everything else.
        var entry = existing ?? Server(name: "oracle", host: "127.0.0.1", username: Self.probeUser)
        entry.keyID = key.id
        serverStore.add(entry)

        let settings = AppSettings(defaults: UserDefaults(suiteName: "ScrollOracle-\(suffix)")!)
        settings.meshyyTransport = meshyy
        // The harness attaches tmux itself; an auto-reattach would add a client.
        settings.autoReattachMultiplexer = false
        settings.scrollTraceEnabled = true

        let session = TerminalSession(
            server: entry, keyStore: keyStore, serverStore: serverStore,
            passwords: PasswordStore(secrets: InMemorySecretStore()),
            settings: settings,
            profiles: ProfileStore(
                agents: [],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            ),
            scrollTrace: ScrollTraceStore(settings: settings, directory: nil, observesKeyboard: false)
        )
        // An unlaid-out terminal is a 2x1 grid: lay it out like a phone screen.
        session.terminalView.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        session.terminalView.layoutIfNeeded()
        return (session, entry)
    }

    private func connect(_ session: TerminalSession, meshyy: Bool) async throws {
        await session.connect()
        try require(session.state == .connected,
                    "\(meshyy ? "meshyy" : "ssh") connect failed: \(session.lastError ?? "\(session.state)")")
        if meshyy {
            // A meshyy failure falls back to an ssh shell — which would make this
            // whole suite ssh-vs-ssh, green and meaningless. Fail, never skip.
            if session.meshyy == nil {
                XCTFail("meshyy did not carry the session (\(session.meshyyUnavailable ?? "no reason")) — "
                        + "the differential would be ssh vs ssh")
                throw Failure("no meshyy transport")
            }
        } else {
            try require(session.meshyy == nil, "the ssh side is riding meshyy")
        }
    }

    /// Suspends `session` (the app dies in the background), waits until the
    /// daemon reports it resumable, and resumes it into a brand-new
    /// TerminalSession — a fresh emulator.
    private func relaunchMeshyy(
        _ session: TerminalSession, server: Server, control: SSHConnection
    ) async throws -> TerminalSession {
        let name = try XCTUnwrap(session.meshyy?.sessionName)
        await session.suspend()
        try await waitForAsync(20, "the daemon never reported \(name) resumable") {
            if case .success(let rows) = await MeshyyTransport.listGroup(over: control, serverID: server.id) {
                return rows.contains { $0.name == name && $0.isResumable }
            }
            return false
        }
        let (fresh, _) = try makeSession(meshyy: true, reusing: server)
        let connecting = Task { await fresh.connect() }
        var parked = false
        let by = Date().addingTimeInterval(30)
        while Date() < by {
            if fresh.meshyySurvivors != nil { parked = true; break }
            if fresh.state == .connected || fresh.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        if parked { fresh.chooseMeshyySession(.resume(name)) }
        await connecting.value
        try require(fresh.state == .connected && fresh.meshyy?.sessionName == name, """
            the relaunch never resumed \(name): parked=\(parked) state=\(fresh.state) \
            meshyy=\(fresh.meshyy?.sessionName ?? "nil") unavailable=\(fresh.meshyyUnavailable ?? "nil") \
            error=\(fresh.lastError ?? "nil")
            """)
        return fresh
    }

    /// Waits until the emulator holds the belief the side's live attach would
    /// teach it, or — when it never will (the known divergence) — until the
    /// attach burst is over: 1.5 s in and quiet for 500 ms. Bounded at 6 s.
    /// Both sides settle by the same rule.
    private func settle(_ session: TerminalSession, _ bench: Bench) async {
        await settle(session) { session in
            let terminal = session.terminalView.getTerminal()
            return bench.mouse ? terminal.mouseMode != .off : terminal.isCurrentBufferAlternate
        }
    }

    private func settle(_ session: TerminalSession, armed: (TerminalSession) -> Bool) async {
        let start = Date()
        while Date().timeIntervalSince(start) < 6 {
            let quiet = Date().timeIntervalSince(session.lastInboundBytesAt ?? start)
            if armed(session), quiet > 0.3 { return }
            if Date().timeIntervalSince(start) > 1.5, quiet > 0.5 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - X10 step

    /// Arms X10 mouse (no SGR), clears the screen so the replay anchor
    /// postdates the arming, then transcribes raw input.
    private static func x10Program(log: String) -> String {
        #"printf '\033[?1000h\033[2J'; stty -icanon -echo min 1; dd bs=1 of="#
            + log + " 2>/dev/null; stty sane\n"
    }

    private struct X10Swipe {
        let decision: SwipeDecision?
        let bytes: Data
        let received: String
        let trace: ScrollTrace.Record?
        var summary: String {
            "route=\(decision.map { "\($0.mode)" } ?? "nil") mouse=\(decision.map { "\($0.mouseMode)" } ?? "nil") "
                + "sent=\(bytes.count)B wheels=\(received.components(separatedBy: "^[[<64;").count - 1)"
        }
        var detail: String {
            let traceJSON = trace.flatMap { try? ScrollTrace.makeEncoder(pretty: false).encode($0) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "nil"
            return "decision=\(decision.map { "\($0)" } ?? "nil") bytes=\(ScrollTrace.hex(bytes)) "
                + "received=\(received.debugDescription) trace=\(traceJSON)"
        }
    }

    private func x10Swipe(_ session: TerminalSession, log: String) async throws -> X10Swipe {
        let bridge = try XCTUnwrap(session.scrollBridge)
        let decision = bridge.beginSwipe()
        let bytes = bridge.injectSwipe(ticks: 3, up: true, at: CGPoint(x: 500, y: 300))
        bridge.endSwipe()
        var received = ""
        let by = Date().addingTimeInterval(bytes.isEmpty ? 1.5 : 8)
        var stableSince = Date()
        while Date() < by {
            let now = Self.read(log)
            if now != received { received = now; stableSince = Date() }
            if !received.isEmpty, Date().timeIntervalSince(stableSince) > 0.6 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return X10Swipe(decision: decision, bytes: bytes, received: received,
                        trace: session.scrollTraceStoreForTesting?.records.last)
    }

    // MARK: - Host plumbing (same probe fixtures as MeshyySurvivorFlowTests)

    private static let fixtures = ["/tmp/aplus-probe-key.pem", "/tmp/aplus-probe-seed.b64",
                                   "/tmp/aplus-probe-user.txt"]

    /// CI has none of the fixtures: skip. A machine with SOME of them is a dev
    /// Mac with a broken setup: fail.
    private func requireLiveFixtures() throws {
        let present = Self.fixtures.filter { FileManager.default.fileExists(atPath: $0) }
        if present.isEmpty {
            throw XCTSkip("no live fixtures (/tmp/aplus-probe-*) — run `make test-scroll-oracle` on the dev Mac")
        }
        try require(present.count == Self.fixtures.count,
                    "partial live fixtures (\(present)) — re-run ./scripts/meshyy-repro-setup.sh")
    }

    private func openControl() async throws -> SSHConnection {
        guard let encoded = try? String(contentsOfFile: "/tmp/aplus-probe-seed.b64", encoding: .utf8),
              let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { throw Failure("the probe seed is unreadable — re-run ./scripts/meshyy-repro-setup.sh") }
        let connection = SSHConnection()
        var config = SSHConnection.Configuration(
            host: "127.0.0.1", port: 22, username: Self.probeUser,
            auth: .key(.ed25519(key)), cols: 80, rows: 24
        )
        config.connectTimeout = 10
        try await connection.connect(config, openShell: false)
        // The host must have what the scenario needs; on a dev Mac a missing
        // piece is a failure, not a skip.
        _ = try await exec("test -x /opt/homebrew/bin/tmux && command -v meshyy-chaos >/dev/null", over: connection)
        return connection
    }

    /// Runs `command` on the host over an exec channel. Exec channels get a
    /// bare PATH that misses Homebrew and ~/bin.
    @discardableResult
    private func exec(_ command: String, over control: SSHConnection) async throws -> String {
        do {
            return try await control.runCommand(
                "PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$PATH; export PATH; " + command)
        } catch {
            throw Failure("host command failed: \(command)\n\(error)")
        }
    }

    private func killMeshyySessions(withPrefix prefix: String, over control: SSHConnection) async {
        let output = (try? await control.runCommand(MeshyyTransport.listCommand())) ?? ""
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = envelope["sessions"] as? [[String: Any]]
            else { continue }
            for name in rows.compactMap({ $0["name"] as? String }) where name.hasPrefix(prefix) {
                _ = try? await control.runCommand(MeshyyTransport.daemonCommand("kill \(name)"))
            }
        }
    }

    private static var probeUser: String {
        (try? String(contentsOfFile: "/tmp/aplus-probe-user.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? NSUserName()
    }

    // MARK: - Small helpers

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message()) }
    }

    private func waitFor(_ seconds: TimeInterval, _ message: String, until condition: () -> Bool) async throws {
        let by = Date().addingTimeInterval(seconds)
        while Date() < by {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message)
    }

    private func waitForAsync(
        _ seconds: TimeInterval, _ message: String, until condition: () async -> Bool
    ) async throws {
        let by = Date().addingTimeInterval(seconds)
        while Date() < by {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw Failure(message)
    }

    /// A transcript as text, ESC rendered as `^[` (cat -v's spelling).
    private static func read(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "^[")
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func hex(_ count: Int) -> String {
        String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(count))
    }
}

private extension String {
    var nonEmptyInt: Int? { isEmpty ? nil : Int(self) }
}
