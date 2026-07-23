# a+Terminal

Privacy-first iOS SSH terminal for working on your own machines from your iPhone — **agent- and multiplexer-agnostic**. Run any terminal multiplexer (tmux, zellij, screen) and any CLI AI coding agent (Claude Code, Codex, aider, Gemini CLI, Hermes, …) over plug-and-play profiles you can extend yourself.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/id6779393452)

Free, tip-supported. No features are paywalled, ever.

> Not affiliated with Anthropic, OpenAI, Google, or Nous Research; product names are trademarks of their respective owners.

## Screenshots

<p align="center">
  <img src=".github/assets/screenshot-tmux-agents.png" width="30%" alt="tmux session with a CLI AI agent's git log, key bar and keyboard visible" />
  <img src=".github/assets/screenshot-servers.png" width="30%" alt="Terminal tab listing live sessions and saved servers" />
  <img src=".github/assets/screenshot-reconnect.png" width="30%" alt="Settings for scroll-as-mouse-wheel, auto-reattach multiplexer and dictation" />
</p>

## Features

- Two tabs: **Terminal** (sessions + servers) and **Settings**.
- First-class multiplexer scrolling: pan gestures become SGR mouse-wheel events, so your tmux/agent output scrolls like it does on the desktop.
- Attach an image or file from your phone over the existing SSH connection.
- On-device voice dictation straight into the terminal (never sent to a server).
- Live Activities + Dynamic Island session awareness with tap-to-reattach.
- **Pop-Out Sessions (beta):** watch a session's tail in a small floating Picture-in-Picture window while you use other apps — view-only monitoring with a running/waiting state chip and tap-to-return.
- Reconnect where you left off: background drops offer reattach, with a live session picker when several multiplexer sessions are running.

## Privacy

**Zero data collection.** No analytics, no crash SDKs, no accounts, no third-party network calls. The only network traffic is your own SSH connection.

Full policy: [privacy policy](https://aaroncx.github.io/a-plus-terminal/privacy/).

## Requirements

- iOS 26.0 or later, iPhone only.
- A machine you can reach over SSH (password or key auth; ed25519 and ECDSA keys supported).

## Support

- Questions or bug reports: [GitHub Issues](https://github.com/AaronCx/a-plus-terminal/issues) — this is the support channel for the App Store listing.
- Guides: [tmux setup](https://aaroncx.github.io/a-plus-terminal/tmux-setup.html) and the [project site](https://aaroncx.github.io/a-plus-terminal/).

## Development

Requires Xcode 26+ (iOS 26 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make generate   # regenerate aPlusTerminal.xcodeproj from project.yml
make build      # build for the iOS simulator
make test       # run unit tests
```

The `.xcodeproj` is generated and gitignored — edit `project.yml` instead.

## License

MIT — see [LICENSE](LICENSE).
