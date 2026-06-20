# Live Activity — on-device test plan

Live Activities cannot be exercised in the simulator; run this on a physical
iPhone with Dynamic Island (to also cover compact/minimal presentations) and
once on a non-Island device (Lock Screen only). The unit tests cover the agent
status-gating logic; this matrix covers the runtime lifecycle they can't.

Setup: a Mac running tmux + Claude Code reachable over Tailscale, plus a way to
kill the network (toggle Wi-Fi / airplane mode) and to stop the server's sshd.

## A. Agent status (working / waiting)

1. Connect, attach tmux, start a Claude Code task that streams output.
   - Expect: Dynamic Island compact shows the orange `exclamationmark.bubble`
     only when **waiting**; while streaming it shows the session count.
   - Expect: expanded / Lock Screen row shows "Claude: working…" then
     "Claude: waiting for input" within ~3s of output going quiet.

## B. Connection close while the agent label is showing  ← primary fix

2. With the row showing "Claude: working…" or "waiting", drop the network
   (airplane mode).
   - Expect: within a few seconds the row stops showing the Claude label and
     the dot goes orange (state → reconnecting). **It must not keep showing
     "working…".**  (Pre-fix bug.)
3. Restore the network within the retry window.
   - Expect: session returns to connected (green dot); agent label reappears
     only if the agent is actually still active after reattach.
4. Type `exit` in the shell (clean end).
   - Expect: that session leaves the Activity; if it was the last one, the
     Activity shows the zero state then dismisses after the grace window.

## C. Multiple sessions

5. Open two sessions, agent active in one. Close one with `exit`.
   - Expect: count drops to 1, surviving session's state is correct, no ghost
     row, no stale agent label from the closed session.

## D. Background / foreground (must NOT clear the Activity)

6. With a live session, background the app for >25s (past the grace window),
   then foreground.
   - Expect: during background the session suspends (tmux survives); the
     Activity keeps showing the session as suspended (tap-to-reattach is the
     point). On foreground it reconnects and the agent label re-derives.

## E. Force-quit and stale handling

7. Force-quit from the app switcher with a live session.
   - Expect: if the app was foreground/in-grace it ends the Activity
     (willTerminate); if it was already suspended, the Activity goes stale
     ("Sessions ended — tap to reopen") after the stale window (~10 min).

## Open decision to confirm here — stuck suspended session

A session whose reconnect **fully fails in the foreground** ends in `.suspended`
and stays in the session list, so the Activity keeps counting it as a session
(orange) until you close it or the stale window elapses. This is intentional
for tap-to-reattach, but verify it reads as "disconnected", not "active/live".
If it feels wrong in practice, the options are: (a) auto-remove a session after
N failed foreground reconnects, or (b) add a distinct "disconnected" treatment
in the widget separate from a backgrounded suspend. Decide from real-device feel
before changing `activeCount` semantics — excluding suspended sessions outright
would break the legitimate backgrounded-reattach case in step 6.
