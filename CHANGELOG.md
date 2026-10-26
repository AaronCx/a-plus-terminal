# Changelog

Notable user-facing changes per release. Versions map to App Store releases;
unreleased work accumulates at the top.

## Unreleased

These are compiled out of the 1.0.4 App Store build; TestFlight builds from
`develop` carry them.

- **Scroll trace (diagnostics):** Settings → Diagnostics → Scroll trace
  records, on this iPhone only, how each recent swipe was routed and what it
  sent, so a scroll that goes dead can be shared (share sheet or your
  server's inbox) and diagnosed. TestFlight (beta) builds only, on by
  default there; compiled out of App Store builds along with meshyy. (#155)
- **meshyy transport (opt-in, beta):** a session can run over meshyy, a
  clean-room resumable terminal transport — a dropped connection resumes
  where it left off instead of reconnecting into a fresh shell. Typing
  `exit` closes the tab like a real terminal, and a resumed terminal
  re-learns the running program's input modes after an auto-resume. While
  an agent waits, a one-tap palette answers it, and tapping an agent
  notification no longer races a meshyy connect into a crash. Off by
  default. (#135, #137, #138, #142, #145; first tried in #131 and #132,
  which #133 reverted)
- **Agent notifications:** the phone tells you when an agent asks for
  you — only when the agent itself signals it (the terminal bell, or an
  OSC 9 / OSC 777 / OSC 7501 notification sequence), never by guessing
  from its output, so leaving the app no longer produces a notification.
  Claude Code needs one setting on the server, which a one-time card
  (also in Settings → Notifications) shows with a Copy button; Settings
  also sends a test notification. A ring you have already seen stays
  quiet until you answer, and a custom agent's bell or notification
  sequence reaches your phone like a built-in's. Notifications arrive only
  while a+Terminal is still running: briefly after you leave it, or while a
  pop-out keeps it running. A pop-out of a session's terminal mutes that
  session, since you are already watching it. Claude Code's "finished"
  ring comes about a minute after a turn, so it usually arrives only while
  a pop-out keeps the app running. (#139, #143, #149, #160, #161)

## 1.0.4 (build 78) — 2026-10-25

- **Custom agents:** Settings → Agents lets you create your own agent for
  any command-line tool, with its own icon from Photos or Files: a+Terminal
  recognizes it from the command name or what it prints when it starts, and
  shows it on the session, the Live Activity and the Dynamic Island like a
  built-in. Agents export and import as JSON; your icons stay on your
  device. (#161)
- **Agent icons:** agents get icons on session rows, the Live Activity and
  the Dynamic Island, with an original doodle-style set as the default.
  Any agent's icon can be replaced with your own image, including files
  still in iCloud Drive, and it is sized to fit the Dynamic Island. A
  toggle in Settings turns the icons off. (#143, #144, #145, #146, #147,
  #148, #161)
- **Agent status at a glance:** the session list says when an agent is
  waiting for you, and each server shows how many are waiting. Agents are
  recognized from what is on screen, so Claude Code is now named inside
  tmux, and Claude Code's busy footer ("esc to interrupt") keeps a silent
  tool call from reading as waiting. (#140, #143, #160, #161)
- **Sessions widget:** a Home Screen widget that lists live sessions and
  saved servers: it opens exactly the session it shows, or starts a session
  on a saved server in one tap. (#135, #136)
- **Live Activity order:** with several sessions open, the Live Activity
  lists them in the order you opened them, first at the top, and tapping
  the compact Dynamic Island opens that first session. (#135)
- **iPhone Duo:** built with Xcode 27.1 and the iOS 27.1 SDK, which iPhone
  Duo needs to run an app full screen; 1.0.3 was built with the iOS 26 SDK.
  (d4f42a9, 5ddf139)
- **Fixes:** returning from a preview refocuses the terminal program
  (#136); a swipe near the bottom of the screen no longer switches tmux
  windows (#147); dictation's Insert + Return, and auto-send after
  silence, now press Return, so dictated answers submit in agent prompts
  and other full-screen apps (#135); closing a session while it is still
  connecting also closes the SSH connection it was opening (#135).

## 1.0.3 (build 43) — 2026-08-01

- **Preview pop-out and console:** a preview can now be popped out into the
  same floating window the Monitor uses — which is also the only way to keep
  it running while you're in another app, since the tunnel lives only as long
  as a+Terminal does. And because a phone has no developer tools, Settings →
  Preview can mirror the page's `console.log` into a pane inside the sheet.
  That one is off by default: it's the only part of Preview that injects
  anything into your page. Captured lines stay in memory and are discarded
  when the sheet closes.
- **In-app localhost preview:** a dev server running on the machine you're
  SSH'd into can now be viewed inside a+Terminal. Tap a `http://localhost:…`
  link in the terminal, or pick a port from the preview sheet — a+Terminal
  detects them from what your server printed and from what's actually
  listening — and the port is forwarded over the SSH connection you already
  have. Hot reload and WebSockets work, because the tunnel carries raw bytes
  instead of rewriting the page. Previously such a link opened in Safari,
  where `localhost` meant the phone and the load simply failed.
  Loopback-only and foreground-only by design: the listener on the phone is
  bound to `127.0.0.1` so nothing else on your network can reach it, the
  preview refuses to navigate anywhere that isn't loopback, and it keeps no
  cookies or site data.
- **Floating pop-out (Picture-in-Picture):** pop a Monitor (VNC) screen out
  into a small floating window to keep watching your Mac while you use other
  apps — the window shows live video of the screen. Tap it to jump back in;
  the system pause button freezes it. (A connected terminal session can also
  be popped out as a view-only surface.) Off by default (Settings →
  Pop-Out), with an optional auto pop-out on app switch. Never interrupts
  your music.
- **Monitor cursor bridge:** link a monitor to the same machine's saved SSH
  server and the remote pointer's real position streams over SSH — the
  cursor now tracks the physical mouse and anything running on the Mac, not
  just your own taps (macOS screen sharing reports nothing about the cursor,
  so this is the only way to show it). Optional; nothing changes if unlinked.
- **Monitor Control mode:** an opt-in toggle turns the view-only monitor
  into a remote control — tap to click, drag to drag, long-press to
  right-click, plus a keyboard sheet (secure text entry, Return/Esc/Tab/
  Delete) that can type a password into a locked Mac's login screen.
  View-only remains the default; nothing is ever sent until you enable it.
- Monitor (VNC): the remote mouse cursor is now visible, drawn by the app
  at the position your touches drive (macOS never draws a cursor into
  screen-sharing streams — verified against a real host; servers that
  report cursor position are also supported).
- **Monitor (VNC, beta):** a view-only window onto your own computer's screen
  sharing. macOS (ARD) authentication lands straight on the desktop; classic
  VNC password and no-auth servers are supported too. Pinch-zoom and pan;
  the same pop-out monitoring works on the remote screen. No keyboard,
  pointer, or clipboard data is ever sent to the host, and the connection
  goes only to the host you enter (use Tailscale or an SSH tunnel as
  transport — classic VNC's own encryption is weak).

## 1.0.2 (build 29) — 2026-07-13

- Settings shows the app version and build.
- Live Activity: recovers from system-ended activities without an app
  restart; proactive background wind-down no longer races the expiration
  watchdog.
- Discovered servers connect over VPN/LTE via candidate-host fallback.

## 1.0.1 (build 22) — 2026-07-04

- Live Activity persists paused sessions until the session closes.
- Path-aware reconnect, host-key review + explicit re-pin flow, Bonjour
  hostname support, App Intents ("Connect to Server", "Wake Server"),
  ECDSA key import/auth/export.

## 1.0 (build 18) — 2026-06-27

- Initial App Store release.
