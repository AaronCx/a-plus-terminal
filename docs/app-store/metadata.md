# App Store metadata

## Identity

- **Name:** a+Terminal — SSH Terminal
- **Subtitle:** SSH terminal for AI agents
- **Bundle ID:** `com.aaroncx.aplusterminal`
- **SKU:** `aplusterminal-ios`
- **Primary category:** Developer Tools
- **Secondary category:** Utilities
- **Price:** Free (IAP: 3 consumable tips)
- **Age rating:** 4+

## Description (draft)

a+Terminal is a privacy-first SSH terminal for working on your own machines
from your iPhone — built around tmux and CLI AI coding agents. It's
**agent-agnostic**: run any CLI coding agent, with plug-and-play profiles you
can extend yourself.

**Scrolling that actually works.** Swipes become real mouse-wheel events, so
tmux and your agent's output scroll natively, with momentum — no more
fighting copy-mode.

**Speak your prompts.** Push-to-talk dictation inserts straight into the
terminal. Recognition runs entirely on your iPhone; audio never leaves the
device.

**Never lose your session.** Live Activities and the Dynamic Island show your
active sessions at a glance. Tap to jump back in — a+Terminal reconnects and
re-attaches your session multiplexer (tmux, zellij, and more) automatically.

**See what you're building.** Your dev server prints `http://localhost:5173`
— on a phone that means nothing, because localhost is the phone. a+Terminal
forwards that port over the SSH connection you already have and renders the
page in the app, live reload and all. Nothing is proxied through anyone's
servers, because there are no servers: it's your machine, your connection,
your page. It works only while the app is open, and it only ever loads your
own dev server — it's a preview, not a browser.

**Zero data collection.** No analytics, no accounts, no crash SDKs, no
servers of ours. The App Privacy label says "Data Not Collected" because
there is nothing to collect it with. The only network traffic is your own
SSH connection.

**Free forever.** Every feature is free. If a+Terminal saves you time, there's a
tip jar. Nothing is paywalled, ever.

- ed25519 keys generated on-device, stored in the Keychain (this device only,
  never in backups; exportable only by your explicit action in Manage Keys)
- Trust-on-first-use host key pinning with hard mismatch failures
- Sticky Ctrl key, Esc/Tab/arrows accessory bar
- Attach an image or file from your phone over the existing SSH connection
- Preview a dev server running on the remote machine, forwarded over the SSH
  connection you already have — loopback-only, foreground-only, never proxied
- Plug-and-play agent & multiplexer profiles — any CLI agent, tmux, zellij,
  screen — or define your own, no update required
- Multiple simultaneous sessions
- Light, dark, and follow-system themes

## Keywords

`ssh,terminal,tmux,ssh client,shell,console,server,sysadmin,developer,vim,remote,cli,ai agent,preview,localhost,port forward`

## URLs

- Support URL: https://github.com/AaronCx/a-plus-terminal/issues
- Marketing URL: https://github.com/AaronCx/a-plus-terminal
- Privacy Policy URL: https://aaroncx.github.io/a-plus-terminal/privacy/

## Review notes

See `review-notes.md`. Record the demo video before submission.
