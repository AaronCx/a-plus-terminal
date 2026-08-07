# Contributing

Thanks for looking. This is a solo-maintained project with CI doing the
reviewing a second person would; the bar for merging is the bar the CI
encodes.

## Ground rules

- **Branch off `main`, PR back to `main`.** PRs to any other base silently
  skip most CI here.
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

## Building

```
make generate   # XcodeGen → project
make build      # first available iPhone simulator
make test       # full suite
```

## Reporting bugs

Use the issue templates. For anything security-sensitive, see meshyy's
SECURITY.md model: a GitHub security advisory beats a public issue.
