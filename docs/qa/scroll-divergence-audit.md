# Scroll under meshyy: audit of the two deferred divergences

Written 2026-10-12, against `develop` at build 75 (meshyy 0.1.22). **Audit only.
Nothing here is implemented.** The status of scrolling stays "not fixed": these are
the known ways a swipe still dies under meshyy. Each one is measured in a harness.
None is confirmed on a phone yet. Build 75's scroll trace exists to tell which of
them Aaron actually hits.

## Where the numbers come from

Two live differential suites drive the same swipe through SSH (the oracle) and
through meshyy into one real tmux. Each swipe is judged by what tmux **did**: copy
mode entered and the scroll position, or the bytes the pane program received.

| suite | emulator and routing | transport | log |
|---|---|---|---|
| a+Terminal `ScrollOracleLiveTests` (`make test-scroll-oracle`) | **real** SwiftTerm and the real `ScrollBridge`, in the simulator | real Citadel SSH vs real launchd `meshyyd` 0.1.22, plus a host UDP relay for path drops | `~/Developer/cc-sessions/scroll-evidence/app-oracle-run{0..4}.log` |
| meshyy `ScrollOracleOrderingTests` (`make check`) | a replica of SwiftTerm's belief and of the ScrollBridge route | real `ssh -tt` in a PTY vs `MeshyySession` through `ChaosUDPProxy` | `~/Developer/cc-sessions/scroll-evidence/final{1,2,3}.log`, `postfix-oracle-{1,2}.log` |

Both run on loopback on the Mac mini. Where the two disagreed, the real-app suite
is the one to believe, and the disagreements are listed under each finding.

Aaron's configuration matters for what he can hit:
- tmux `mouse on`, read live from his server on 2026-08-07 (`tmux show -g mouse`;
  session transcript 096c02c8, 18:33Z);
- Claude Code with the fullscreen renderer, whose panes read `alt=1 mouse_any=1`.

Measured mode sets, raw pane output via tmux `pipe-pane`, Claude Code 2.1.296:
- **inline:** `?1004h ?2004h ?2031h ?25l/h` only. No alternate screen and no mouse.
- **fullscreen:** `?1049h ?1000h ?1002h ?1003h ?1006h ?1004h ?2004h ?2031h`.

---

## 1. The path-change window

### What happens to a swipe

The outbox sends whatever transport is current. The QUIC connection reports
nothing when its path dies, so the swipe goes **into the dead connection**.
- It is not queued or replayed by anything.
- `send` does not fail (`sendOK=1, sendFailed=0` in every run).
- The heartbeat declares death 3.1–4.1 s after the path dies (1 s interval,
  3 misses; 15 legs measured), which is about 2.6–3.6 s after a swipe sent
  0.5 s into the hole.
- The app then redials with a fresh emulator.

What the user sees depends on whether the old path comes back:

| case (a+Terminal suite, mouse on) | runs | fate of the swipe |
|---|---|---|
| **True path change**: the old path never returns (Wi-Fi to cellular, a NAT rebind) | 3 of 3 | **lost**. tmux never sees it; nothing errors |
| **Healing hole**: a 4 s blackout that ends (Wi-Fi hiccup, elevator, a dead zone crossed) | 2 of 3 (this suite's runs 0, 3, 4) | **delivered late**, 5.4–5.6 s after the hole opened |
| | 1 of 3 | **lost** |
| | earlier, 2026-10-11, six runs (test-file record) | delivered late at 5.29–5.48 s three times, **lost** three times |
| The swipe after the redial | 3 of 3 | correct |

- **Replica disagreement:** the meshyy replica suite delivered the healing-hole
  swipe late in every run: 10 of 10 at 4.0–4.8 s, and 4.4–5.7 s when it also
  redialled the way the app does. The real app lost it 4 times in 9.
  The real app abandons the connection at heartbeat death and builds a new one, so
  whether the old connection's queued bytes leave before teardown is a race.
- **Mouse off:** the swipe is not sent at all (route `native`, see §2), so its
  fate here is moot. In the replica, whose belief was still right, the arrow keys
  were sent and lost on a path change.

So a dead swipe during a network change shows up as one of two things:
- **"nothing happens"**: lost, until the redial about 3–4 s later, after which
  swiping works again;
- **"starts working after a few seconds"**: the late delivery lands about 5 s
  later as a sudden scroll the user did not make at that moment.

Both match Aaron's original wording ("works inconsistently").

**Can the trace tell?** At the moment of the swipe, not reliably.
- The pong-inclusive inbound age was 0.53–1.16 s at +0.5 s into the hole, over
  all 15 legs. A healthy session reads up to about 1 s, because the heartbeat is
  1 s.
- A swipe 2 s or more into a hole would read about 2 s and stand out.
- After the fact, the record is unambiguous:
  - `transportState` stays `connected` while the trace's
    `msToFirstInboundAfterSend` is empty ("no reply");
  - the next record shows a fresh `lastModesFrame` from the redial.

### How often on a real phone (estimate; build 75 will measure)

- Every Wi-Fi to cellular handoff, every carrier NAT rebind and every network
  switch opens one 3–4 s window. Network framework does not do QUIC connection
  migration, so every one is a full redial (`meshyy/docs/qa/known-debt.md`).
- **At a desk on stable Wi-Fi:** rare. Mostly brief hiccups, where the swipe is
  delivered late about half the time and lost the rest (4 of 9 lost).
- **Moving around:** several windows an hour. A swipe lands in one only if the
  user scrolls in those 3–4 s, which is likely right after unlocking the phone or
  walking into Wi-Fi range, the exact moments people pick a session back up.

### Fix options and costs

| option | what it does | cost and risk |
|---|---|---|
| **A. Redial on path change, not on heartbeat death** | Call the library's existing `MeshyySession.enableAutomaticReconnect(bootstrap:)`, whose `PathWatcher` (`NWPathMonitor`) reconnects the moment the interface changes. a+Terminal never calls it today. | **Small–medium.** App only. The redial provider must re-run the SSH bootstrap, which `reattach` already does. Removes most of the window for true path changes. Does nothing for a hole on an unchanged interface. |
| **B. Tell the user the session is not live** | Mark the tab "reconnecting" when the pong-inclusive inbound age passes ~1.5 s (heartbeat 1 s), not after 3 misses. Swipes in that state are dropped on purpose, and the UI says so. | **Small.** App only, using `lastInboundFrameAt` (0.1.22). Risk: a flicker on a slow link; tune the threshold against build 75 traces. |
| **C. Queue input and replay it on redial** | Hold unacknowledged input and resend it after the redial. | **Large.** meshyy acknowledges output, not input. Exactly-once keystrokes need input sequence numbers and daemon-side dedupe: an additive frame plus golden fixtures. Wrong for scroll anyway: replaying a 4-second-old swipe scrolls something the user has stopped looking at. Only worth it for keystrokes, as its own design. |
| **D. QUIC connection migration** | Keep the connection across the path change. | **Not available.** Network framework has no public API (`nw_quic_migration_*` is SPI). |

**Recommendation:** A, then B. Drop stale swipes instead of replaying them, and
keep C out of scroll entirely.

---

## 2. `.screenMode` ignored by the app

### What breaks

- **The mechanism.** A fresh emulator learns the mouse modes from the daemon's
  `.modes` frame. It learns the alternate screen from nothing:
  - `MeshyyTransport` records the `.screenMode` frame for the scroll trace but
    deliberately never applies it to the emulator;
  - the replay begins after tmux's `?1049h`;
  - `TerminalSession.establish()` calls `resetToInitialState()` on **every**
    connect, including every redial.
- **The result.** After a relaunch, a redial or any reconnect, the emulator
  believes the primary screen is showing while tmux holds the alternate one.
  `ScrollBridge` routes on that belief:

| tmux | pane | route over SSH | route over meshyy after a fresh emulator | outcome |
|---|---|---|---|---|
| `mouse on` | anything | `sgrWheel` (mouse armed) | `sgrWheel` (the `.modes` frame restores the mouse) | **correct**: masked |
| `mouse off` | shell or inline Claude Code | `arrowKeys` (alt screen, no mouse) | **`native`**: nothing sent, SwiftTerm scrolls its own local scrollback | **diverges** |
| `mouse off` | fullscreen Claude Code | `sgrWheel` (tmux arms the outer mouse for that pane) | `sgrWheel` | correct |
| no tmux, alt-screen program without mouse (`less`, `man`, `vim` with mouse off) | n/a | `arrowKeys` | **`native`** | **diverges** (inferred from the same mechanism; not measured, since every suite scenario runs inside tmux) |

Measured in the a+Terminal suite, mouse off, the same pattern in 5 of 5 runs
(run0 to run4; 7 of 7 counting the two mutation-run controls):
- **Relaunch:** SSH sent 9 Up arrows. meshyy sent 0 bytes on route `native`, and
  the pane received nothing.
- **Persistence:** the wrong belief **persists**. Every later step diverged:
  reconnect-mid-burst, path-drop, path-drop-after, path-change, path-change-after,
  claude-inline.
- **Exception:** claude-fullscreen matched, because it arms the mouse.
- **Before the first relaunch:** the attach and all five keyboard cycles matched.
- **Replica disagreements:**
  - The replica showed reconnect-mid-burst and ring-overrun-resume matching
    (5 of 5). In the real app, the emulator that reconnects was already wrong
    from the relaunch, and the reset on reconnect cannot fix it.
  - In the replica, a redial **alone** turned a correct belief wrong:
    `path-drop-heal-redial-after` diverged on `native` with `alt=0` in 5 of 5
    runs. A redial resets belief just as a relaunch does.

What the user sees: **"the wrong thing scrolls"**. The local scrollback moves
instead of the program or tmux, or nothing visible happens on a short screen.

### Does it affect Aaron?

**Not with his current setup.** tmux `mouse on` masks it completely, and so does
fullscreen Claude Code under `mouse off` (both measured). By the same mechanism,
not measured, it should also affect:
- any tmux with `mouse off`, which is the tmux default (this case is measured);
- screen and zellij setups without mouse;
- every plain alternate-screen program run over meshyy after a relaunch or a
  redial.

### Fix options and costs

| option | what it does | cost and risk |
|---|---|---|
| **A. Honor `.screenMode` as routing belief** | Keep the last `.screenMode` (the trace already records it, `lastScreenModeFrame`). `ScrollBridge` uses it for the alt-screen input to `ScrollBridgeCore.mode` while meshyy carries the pty. The daemon sends it on attach and on every flip. | **Small.** App only, a few lines plus tests. The strict expected failures in both oracle suites turn red the moment it works, and that is the signal to delete them. Risk: two sources of truth (the emulator and the frame); prefer the frame only under meshyy. |
| **B. Don't reset the emulator on a meshyy redial** | Skip `resetToInitialState()` when reattaching the same meshyy session. The emulator already holds everything up to `consumedOffset`, and the replay continues from there. | **Small–medium.** Fixes redials, not relaunches (a relaunch is a new emulator). Needs care with the geometry reset and the "old and new frames overlay" problem the reset exists for. |
| **C. Synthesize `?1049h`** | Feed the emulator the alt-screen switch it missed. | **Risky.** Switches SwiftTerm to an empty alternate buffer before the replay. Whether tmux's resync redraw then repaints it fully was not measured. The 2026-08-07 investigation advised against it for blanking the visible buffer. |

**Recommendation:** A. B is optional on top.

---

## 3. Also found while measuring (not deferred items; reported, not fixed)

1. **Ring overrun leaves the app's networking spinning.**
   - **Repro:** an unpaced full-screen flood while the client is detached
     overruns the daemon's 4 MiB ring in 10–12 s. The resume swipe itself matched
     SSH with mouse on. With mouse off it diverged as in §2.
   - **Then, by the harness agent's account:** the simulator app's
     `com.apple.network.connections` queue sat at 100% of a core for at least
     28 s, with a stack of `nw_flow_disconnected → nw_flow_process_input_frames →
     dispatch_data_create_concat`. That account is recorded only in the test
     file's comment; no sample was saved. Re-capture it before acting on it.
   - **Effect:** heartbeats stalled and meshyy was lost afterwards in all 7
     overrun runs.
     - A redial soon after the overrun sometimes still connected (about 4.9 s).
     - A later one, or the next test's first connect, hit "no QUIC connection
       within 4000ms" (6 of 7) and the tab fell back to SSH.
     - One run instead never came back while still reading `connected`.
     - The healing-hole swipe in those runs was lost 5 of 5.
   - **Reproducibility:** 7 of 7. It was kept out of the suite rather than
     committed red; the repro is
     `~/Developer/cc-sessions/scroll-evidence/app-oracle-ring-overrun-step.patch`.
   - **Relevance to Aaron:** this is the shape of "phone in pocket while Claude
     Code writes a lot, then come back".
   - **Status:** found in the simulator harness, unconfirmed on a device. Not
     root-caused.
2. **A swipe right after the keyboard is dismissed can be taken at the old
   size.** tmux applies the resize late on **any** transport.
   - Over SSH, 2–8 of 10 dismiss-then-immediate-swipe pairs landed at the old
     size across the replica runs. meshyy took 10 of 10 at the new size in the
     final runs, but 3 of 10 at the old size in one earlier run.
   - Not a meshyy divergence, and the build-72 bottom-row clamp keeps it off the
     status line. Recorded because it looks like a dead swipe.
3. **The #63 single-lane fix is load-bearing and now guarded.** With it reverted,
   the meshyy row-order check went red in 3 of 3 runs (15 of 60 seeds). See
   `meshyy/docs/qa/mutation-log.md`.

## What to look for in Aaron's build 75 trace

| what he reports | trace signature | points to |
|---|---|---|
| nothing happens | `route=sgrWheel`, `sendOK=1`, "no reply", `transportState=connected`, then a record with a fresh `lastModesFrame` about 3–4 s later | §1, path change (lost) |
| starts working after a few seconds | `sendOK=1`, `maxSendLatencyMs` small but the reply 3.5 s or more after the swipe (measured 3.5–5.1 s), or several swipes landing together | §1, healing hole (late) |
| wrong thing scrolls | `route=native` with `belief.altScreen=false` while `lastScreenModeFrame.alt=true` | §2 |
| anything after a long time away | `transportState` stuck reconnecting or dead, the SSH fallback (`meshyyUnavailableReason`) set, high inbound age | §3.1 |
| "no previous window" | the emitted `row` ≥ `lastPtyResize.rows` | pty smaller than the emulator (lost resize); the daemon's `--trace-modes` log on the Mac lines up by time |
