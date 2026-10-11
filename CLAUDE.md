# a+Terminal — CC environment notes

Privacy-first iOS SSH terminal. Spec: `~/Documents/github/relay-ios-terminal-spec.md`.

## Build rules

- The Xcode project is **generated**: always run `make generate` after editing `project.yml`. Never edit `aPlusTerminal.xcodeproj` directly (it is gitignored).
- Xcode is not the system default toolchain on this Mac — the Makefile exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Prefix any raw `xcodebuild`/`xcrun` call with it.
- Build: `make build` (picks the first available iPhone simulator; locally that is iPhone 17 Pro). Tests: `make test`.
- Signing, device deploys, and App Store Connect / StoreKit Connect setup are human-in-Xcode steps — stop and ask.

## Branch & release policy (2026-08-19)

- **`develop` is the integration branch.** Feature branches base on `develop`;
  open PRs with `--base develop` (the global pr-base-main reminder is
  satisfied by any explicit base). CI runs on all PRs.
- **`main` = latest App Store–approved release only** (currently 1.0.3,
  build 43). Never push app code to `main`; it moves via a `release/vX.Y.Z`
  PR after Apple approves — full process in `RELEASING.md`. A server-side
  ruleset enforces PR-only, no force pushes.
- `/ship N` (scripts/ship-testflight.sh) builds TestFlight uploads from
  `develop`.
- On approval: tag `vX.Y.Z` at the approved bump commit, GitHub release
  titled "X.Y.Z (build N)", then merge `main` back into `develop`.

## Constraints

- Dependency policy: SwiftTerm, Citadel, swift-crypto, XcodeGen (build-time), RoyalVNCKit (vendored under `Vendor/royalvnc`, view-only VNC monitor) — nothing else. RoyalVNCKit is a patched vendor copy, not an SPM URL reference: see the header of `Vendor/royalvnc/Package.swift` before touching it.
- Zero data collection: no analytics, no crash SDKs, no third-party network calls. Only user-initiated SSH traffic and on-device dictation.
- iOS 26.0+, iPhone only.

## "Fixed" means Aaron confirmed it on a device

Never report a user-visible bug as fixed, resolved or "gone" on the strength of
tests, the simulator or CI. Those prove the theory you tested, not the bug he
hit. Until Aaron confirms on a named TestFlight build, the status is:
"fixed in harness, unconfirmed on device (build N)". Every report names the
build number and what he should try.
