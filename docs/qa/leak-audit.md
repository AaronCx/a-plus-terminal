# Leak audit notes (Instruments)

Run before each release. Manual, on a device or simulator from Xcode.

## Procedure

1. Product → Profile (`Cmd+I`) → **Leaks** template.
2. Exercise the hot paths in this order, watching for leak flags and abandoned
   memory between generations (`Cmd+Shift+M` to mark):
   - Open a session → close it (red ✕) → repeat ×5. The `TerminalSession`,
     `SSHConnection`, and `RelayTerminalView` for each must be released.
   - Backgrounding: connect → background 30s (grace suspend) → foreground
     (reconnect) ×3. Each reconnect allocates a fresh `SSHConnection`; the
     prior one must be released after `channelEnded`.
   - Dictation sheet: open → speak → cancel ×3. `AVAudioEngine` taps and the
     recognition task must release; check no `SFSpeechRecognitionTask`
     accumulation.
   - ScrollBridge momentum: flick-scroll in tmux, leave the screen
     mid-momentum. The momentum `Task` holds `self` weakly — verify no
     `ScrollBridge` instances accumulate.
   - Live Activity: open/close sessions until the Activity ends (5-min grace
     can be shortened by editing `SessionActivityController.graceWindow` in a
     local build).

## Known retain relationships (by design, not leaks)

- `TerminalSession` ⇄ `SessionIO`: session holds IO strongly; IO holds the
  session weakly (SwiftTerm's `terminalDelegate` is weak).
- `TerminalSession.terminalView` is retained for the session's lifetime so
  scrollback survives navigation — released on `close()` via SessionManager
  removing the session.
- `SessionManager` lives for the app's lifetime (root `@State`).

## Last run

- _2026-06-10: code-level audit during PR 12 (closure capture lists reviewed:
  all `Task`/closure captures of sessions, bridges, and stores are `[weak …]`
  or owned-by-design as listed above). Instruments run pending first device
  deploy — human step._
