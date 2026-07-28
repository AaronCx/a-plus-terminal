# a+Terminal — CC environment notes

Privacy-first iOS SSH terminal. Spec: `~/Documents/github/relay-ios-terminal-spec.md`.

## Build rules

- The Xcode project is **generated**: always run `make generate` after editing `project.yml`. Never edit `aPlusTerminal.xcodeproj` directly (it is gitignored).
- Xcode is not the system default toolchain on this Mac — the Makefile exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Prefix any raw `xcodebuild`/`xcrun` call with it.
- Build: `make build` (picks the first available iPhone simulator; locally that is iPhone 17 Pro). Tests: `make test`.
- Signing, device deploys, and App Store Connect / StoreKit Connect setup are human-in-Xcode steps — stop and ask.

## Constraints

- Dependency policy: SwiftTerm, Citadel, swift-crypto, XcodeGen (build-time), RoyalVNCKit (vendored under `Vendor/royalvnc`, view-only VNC monitor), Meshyy (own MIT package, resumable transport behind the Settings toggle — only the `MeshyyCore`/`MeshyyKit` client half is linked; the daemon targets are macOS-only) — nothing else. RoyalVNCKit is a patched vendor copy, not an SPM URL reference: see the header of `Vendor/royalvnc/Package.swift` before touching it.
- Zero data collection: no analytics, no crash SDKs, no third-party network calls. Only user-initiated SSH traffic and on-device dictation.
- iOS 26.0+, iPhone only.

## meshyy (opt-in resumable transport)

- Off by default. `Settings → Connection → Use meshyy when available (beta)`.
- Replaces **only** the PTY byte stream. The SSH connection stays up and keeps doing
  attachments (SFTP), the Preview forward, and tmux discovery — so a failure anywhere
  in the meshyy path costs a feature, never the terminal.
- Bootstrap runs over SSH (`meshyyd attach --session <name> --json`), so the QUIC
  certificate is trusted via the SSH host key the user already pinned. No daemon on the
  host means no bootstrap means plain SSH, which is the majority case and not an error.
- Live tests need a local daemon and single-use tokens:
  `./scripts/meshyy-live-fixtures.sh && make test`. They SKIP without fixtures, so CI
  stays green. Tokens are single-use — mint immediately before the run, or a stale one
  fails as a refused attach and reads like a broken transport.
