# Contributing

Thanks for looking. This is a solo-maintained project with CI doing the
reviewing a second person would; the bar for merging is the bar the CI
encodes.

## Ground rules

- **Branch off `develop`, PR back to `develop`.** `main` tracks the latest
  App Store–approved release and only receives release merges — see
  RELEASING.md.
- **Zero data collection is enforced, not aspirational.**
  `scripts/check-network-surface.sh` fails the build if a network-capable
  symbol appears outside the audited SSH / meshyy / VNC / local-network
  layers. If your change legitimately needs network access, it belongs in an
  audited layer — or the allowlist grows in the same PR, where a reviewer
  sees both.
- **Dependency policy is closed.** SwiftTerm, Citadel, swift-crypto, meshyy,
  XcodeGen (build-time), and the vendored RoyalVNCKit. Proposing a new
  dependency is a design discussion, not a commit.
- **The Xcode project is generated.** Edit `project.yml`, run
  `make generate`; never commit `aPlusTerminal.xcodeproj` edits.
- **Tests ride with the change.** Live meshyy tests skip cleanly on machines
  without a local daemon (`./scripts/meshyy-repro-setup.sh` sets one up).
- **meshyy is beta-only and compiled out of App Store builds.** Code that
  touches it goes inside `#if MESHYY`. The `aPlusTerminal` scheme (beta,
  TestFlight) sets the condition and links the package; the
  `aPlusTerminalAppStore` scheme (App Store candidate) does neither. CI builds
  both, runs the App Store Settings UI test, and fails if
  `scripts/check-no-meshyy.sh` finds meshyy in the App Store binary.

## Building

```
make generate   # XcodeGen → project
make build      # first available iPhone simulator
make test       # full suite
make build-appstore test-appstore check-appstore   # App Store candidate (no meshyy)
```

## Reporting bugs

Use the issue templates. For anything security-sensitive, see meshyy's
SECURITY.md model: a GitHub security advisory beats a public issue.
