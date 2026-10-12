# Mutation log

Deliberate defects introduced to prove a test can fail. Per the hardening brief:
"A correctness test nobody has ever seen fail is not evidence."

Each entry records the mutation, what each test saw, and what that proves.
Append only: new entries go at the bottom, and earlier entries are never
rewritten. A correction is a new entry.

---

## 2026-10-12 — modeEscapes 1006 ordering (#145) reverted against the SSH oracle

The brief: revert the `modeEscapes` 1006-ordering fix and confirm the scroll
oracle goes red before trusting it. Planted in the working tree only, on
`scroll-oracle`, and run on the iOS 26 simulator against the launchd meshyyd
0.1.22 and tmux 3.6a.

Mutation site: `MeshyyTransport.modeEscapes(active:)`. The mutant moves the
`?1006 h|l` escape after the mouse-family block, which is the pre-#145 order:

```swift
static func modeEscapes(active: Set<Int>) -> Data {
    var out = ""                                                    // MUTANT: no leading 1006
    let mouseFamily: [Int] = [1000, 1002, 1003]
    if mouseFamily.contains(where: active.contains) {
        for mode in mouseFamily where active.contains(mode) { out += "\u{1B}[?\(mode)h" }
    } else {
        for mode in mouseFamily { out += "\u{1B}[?\(mode)l" }
    }
    out += "\u{1B}[?1006\(active.contains(1006) ? "h" : "l")"      // MUTANT: trailing (pre-#145)
    for mode in [1, 1004, 2004] { out += "\u{1B}[?\(mode)\(active.contains(mode) ? "h" : "l")" }
    return Data(out.utf8)
}
```

SwiftTerm reads `?1006l` as "mouse off" outright. For a program that arms
mouse without SGR, the daemon reports `{1000}`, and the trailing `?1006l`
cancels the arming that the synthesis exists to assert.

**Results, mutant planted**

| test | result |
|---|---|
| `ModeSynthesisTests.testModeSynthesisCannotDisarmTheMouseItJustArmed` | **red** |
| `ModeSynthesisTests.testModeSynthesisArmsTheTmuxSet` | green |
| `ModeSynthesisTests.testModeSynthesisStillDisarmsWhenEverythingIsOff` | green |
| `MeshyyTransportTests` (14 tests) | green |
| `ScrollOracleLiveTests.testAnX10ProgramStillGetsWheelBytesAfterAFreshEmulatorResumes` | **red** |
| `ScrollOracleLiveTests.testMouseOffEverySwipeOverMeshyyDoesWhatSSHDoes` | green |
| `ScrollOracleLiveTests.testMouseOnEverySwipeOverMeshyyDoesWhatSSHDoes` | green |

The unit test's message:

```
MeshyyTransportTests.swift:425: XCTAssertTrue failed - ?1006l must not follow the family arming it would cancel
```

The X10 step, first run (the harness as committed in `0a47414`):

```
ScrollOracleLiveTests.swift:1108: failed: caught error: "the meshyy emulator does not believe
mouse on after the program armed X10 mouse — the modes-frame synthesis disarmed it (1006 ordering?)"
```

That run was red, but on a belief wait (`mouseMode != .off` on the live
meshyy emulator) that threw. The fresh-emulator differential the step was
written for never ran, and the red was about belief, not about whether
the program got its bytes. The harness was changed (`809cbc4`): the live
emulator is now swiped and judged by what the program received, and the
fresh-emulator swipe counts only the bytes after that. Second run with the
mutant planted:

```
MEASURE scrollOracle x10-live-emulator:  ssh route=sgrWheel mouse=vt200 sent=36B wheels=3 | meshyy route=native mouse=off sent=0B wheels=0
MEASURE scrollOracle x10-fresh-emulator: ssh route=sgrWheel mouse=vt200 sent=36B wheels=3 | meshyy route=native mouse=off sent=0B wheels=0 modesFrame=[1000]
ScrollOracleLiveTests.swift:118: XCTAssertEqual failed: ("") is not equal to ("^[[<64;66;20M^[[<64;66;20M^[[<64;66;20M")
  - DIVERGENCE x10-live-emulator: the program armed X10 mouse; over ssh its wheel bytes arrived,
    over meshyy — same emulator, no relaunch — they did not (the daemon's modes frame disarmed it: 1006 ordering?)
ScrollOracleLiveTests.swift:129: XCTAssertEqual failed: ("") is not equal to ("^[[<64;66;20M^[[<64;66;20M^[[<64;66;20M")
  - DIVERGENCE x10-fresh-emulator: the program armed X10 mouse; over ssh its wheel bytes arrived,
    over meshyy a fresh emulator resumed and they did not
```

**The tmux steps were measured, not assumed.** Under the mutant, both tmux
scenarios passed. Every mouse-on step except path-change (an expected
failure: `inMode=0 … landed=never`, lost) and path-drop (measured, not
asserted) matched ssh (`via sgrWheel sent=36B`, `inMode=1 scroll=10`), and
mouse-off claude-fullscreen matched (3 SGR wheel-ups). They hit the same 14 strict expected failures as the unmutated
baseline (`app-oracle-run4.log`), on the same seven steps:

- mouse-off relaunch, reconnect-mid-burst, path-drop-after, path-change, path-change-after and claude-inline;
- mouse-on path-change.

No other step went red. tmux arms 1006 together with the mouse family, so
both orderings end armed.

**Restored:** with the harness change and the original code, all 20 tests
passed (X10 live and fresh `wheels=3` on both sides, `modesFrame=[1000]`),
with the same 14 strict expected failures.

**What this proves.**

- The #145 revert is caught twice: by the unit test, which pins the order
  against a model of SwiftTerm's semantics, and by the live oracle, which
  asserts the outcome with real SwiftTerm, the real `ScrollBridge` and the
  real daemon.
- Only the X10 step catches it live. The tmux differential cannot: with
  tmux in front, the bug is invisible to the user too.
- The bug is wider than "a fresh emulator after a relaunch". The daemon's
  live modes frame disarmed the emulator that had just seen `?1000h` itself,
  so an X10 program lost scroll without any suspend at all.
- Status: found in the simulator harness, not confirmed on a device.

Logs are in `~/Developer/cc-sessions/scroll-evidence/`:

- `app-oracle-mutant-1006-run1.log`: the mutant, with the original harness;
- `app-oracle-mutant-1006-run2.log`: the mutant, with the hardened harness;
- `app-oracle-postmutant-clean.log`: the restored code.

Reverted after the run; git diff clean; suite green.

---

## 2026-10-12 — #63 one ordered lane: measured in meshyy, pointer only

The #63 revert (one ordered QUIC lane for control and pty) is a meshyy change,
so it is measured in meshyy and not here. See meshyy
`docs/qa/mutation-log.md`, entry "2026-10-11 — #63 one ordered lane, against
the SSH oracle", on its `scroll-oracle` branch.

In short:

- The row checker (`dismissAndSwipeStayOrdered`) caught the routing revert in
  3 of 3 runs, with **15/60 seeds red**.
- The tmux-outcome tests alone (`swipeOutcomeMatchesTheOracle`,
  `reorderedClientsMatchTheOracle`) did **not** catch it on loopback. tmux
  applies a resize late on every transport, and that hides transport
  reordering.

This app suite cannot observe that mutant as wired. The app links meshyy by
version, so seeing it from here would need a local-path package, a second
mutant daemon and a socket seam. See `harness-design.md` §6.1.
