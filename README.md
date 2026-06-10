# Relay

Privacy-first iOS SSH terminal, optimized for one workflow: **iPhone → Tailscale → Mac mini → tmux → Claude Code**.

- Two tabs: **Terminal** (sessions + servers) and **Settings**.
- First-class tmux scrolling: pan gestures become SGR mouse-wheel events, so the Claude Code transcript scrolls like on desktop.
- On-device voice dictation straight into the terminal (never sent to a server).
- Live Activities + Dynamic Island session awareness with tap-to-reattach.
- **Zero data collection.** No analytics, no crash SDKs, no accounts, no third-party network calls. The only network traffic is your own SSH connection.

Free, donation-supported. No features are paywalled, ever.

## Development

Requires Xcode 26+ (iOS 26 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make generate   # regenerate Relay.xcodeproj from project.yml
make build      # build for the iOS simulator
make test       # run unit tests
```

The `.xcodeproj` is generated and gitignored — edit `project.yml` instead.

## License

MIT — see [LICENSE](LICENSE).
