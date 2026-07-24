# Changelog

Notable user-facing changes per release. Versions map to App Store releases;
unreleased work accumulates at the top.

## Unreleased

- **Pop-Out Sessions (beta):** monitor a session in a floating
  Picture-in-Picture window while using other apps. View-only by design — a
  header with the session name and a running / waiting-for-input /
  disconnected chip above the last rows of terminal output, updating live.
  Tap the window to jump back to the session; the system pause button freezes
  the view without touching the session. Off by default (Settings → Pop-Out),
  with an optional auto pop-out on app switch. Never interrupts your music.
- Monitor (VNC): the remote mouse cursor is now visible — the server draws
  it into the screen image (previously the connection claimed client-side
  cursor rendering and then nothing rendered it).
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

## 1.0 (build 13) — 2026-06-27

- Initial App Store release.
