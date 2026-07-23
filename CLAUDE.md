# a+Terminal — CC environment notes

Privacy-first iOS SSH terminal. Spec: `~/Documents/github/relay-ios-terminal-spec.md`.

## Build rules

- The Xcode project is **generated**: always run `make generate` after editing `project.yml`. Never edit `aPlusTerminal.xcodeproj` directly (it is gitignored).
- Xcode is not the system default toolchain on this Mac — the Makefile exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Prefix any raw `xcodebuild`/`xcrun` call with it.
- Build: `make build` (picks the first available iPhone simulator; locally that is iPhone 17 Pro). Tests: `make test`.
- Signing, device deploys, and App Store Connect / StoreKit Connect setup are human-in-Xcode steps — stop and ask.

## Constraints

- Dependency policy: SwiftTerm, Citadel, swift-crypto, XcodeGen (build-time), RoyalVNCKit (vendored under `Vendor/royalvnc`, view-only VNC monitor) — nothing else. RoyalVNCKit is a patched vendor copy, not an SPM URL reference: see the header of `Vendor/royalvnc/Package.swift` before touching it.
- Zero data collection: no analytics, no crash SDKs, no third-party network calls. Only user-initiated SSH traffic and on-device dictation.
- iOS 26.0+, iPhone only.
