# a+Terminal

Privacy-first iOS SSH terminal for working on your own machines from your iPhone — **agent- and multiplexer-agnostic**. Run any terminal multiplexer (tmux, zellij, screen) and any CLI AI coding agent (Claude Code, Codex, aider, Gemini CLI, Hermes, …) over plug-and-play profiles you can extend yourself.

- Two tabs: **Terminal** (sessions + servers) and **Settings**.
- First-class multiplexer scrolling: pan gestures become SGR mouse-wheel events, so your tmux/agent output scrolls like it does on the desktop.
- Attach an image or file from your phone over the existing SSH connection.
- On-device voice dictation straight into the terminal (never sent to a server).
- Live Activities + Dynamic Island session awareness with tap-to-reattach.
- **Zero data collection.** No analytics, no crash SDKs, no accounts, no third-party network calls. The only network traffic is your own SSH connection.

Free, tip-supported. No features are paywalled, ever.

> Not affiliated with Anthropic, OpenAI, Google, or Nous Research; product names are trademarks of their respective owners.

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
