# Releasing

This repo mirrors the App Store: `main` is always the source of the newest
**approved** release, and the [releases page](https://github.com/AaronCx/a-plus-terminal/releases)
lists exactly the versions Apple has approved.

## Branch model

- **`develop`** — integration branch. Feature branches merge here via PR; CI
  runs on every PR. TestFlight builds ship from here.
- **`main`** — approved releases only. Protected: PRs only, no force pushes.
  App code reaches `main` only after Apple approves the build that carries it.
  (Docs-only changes — README, this file — may land via PR at any time; they
  don't ship in builds.)

## TestFlight builds

`scripts/ship-testflight.sh <build>` runs from `develop`: version-bump PR →
CI → merge → signed archive → metadata gate → upload → poll to VALID.

## App Store candidates

App Store candidates are cut with `scripts/ship-testflight.sh <build> --app-store`.
It archives the `aPlusTerminalAppStore` scheme, which is built without the
`MESHYY` condition and without the Meshyy package, so meshyy, and the scroll
trace that exists to debug it, are not in the binary at all (App Review tests
the exact uploaded binary; a runtime "off" is not enough). On top of the usual gates it refuses a dirty tree or a local
`develop` that differs from `origin/develop`, runs `scripts/check-no-meshyy.sh`
on a Debug simulator build of the same commit (only an unoptimized binary
shows short UI strings) and on the archived app, requires 0 `@rpath`
references, and writes "App Store candidate" into the build's TestFlight What to Test
notes. The candidate Aaron tests is the build that gets submitted; any change
after his review means a new candidate. Archives are kept in
`~/Library/Developer/Xcode/Archives/aPlusTerminal/`.

The iPhone Duo build needs the iOS 27.1 SDK, which this Mac doesn't have.
`.github/workflows/duo-archive.yml` therefore archives it unsigned on GitHub's
`xcode-27` image, pinned to the Xcode 27.1 release (27A9275). That runs when a
push to a `test/**` branch has `[duo-archive]` in its head commit message.
Then `scripts/ship-ci-archive.sh <build> <archive.zip> <commit> --app-store`
signs it here and uploads it as the candidate. It runs the archive gates
above, including `check-no-meshyy.sh` on the archived app. The Debug-build
meshyy check runs in `ci.yml` (`make check-appstore`), so the script requires
`ci.yml` to have passed on that commit. Run the dev-signed launch proof on the
iPhone before the upload. The script refuses an archive from any other Xcode,
since beta-Xcode builds can't go to App Review.

When Apple approves a candidate cut this way, the commit in step 1 below is
the `test/**` commit its archive was built from, not a bump merge on
`develop`. That branch compiles agent notifications out
(`AGENT_NOTIFY_CONDITION: ""` in `project.yml`). After merging `main` back
into `develop` in step 5, set it to `AGENT_NOTIFY` on `develop`, unless
notifications are meant to stay out of the next release as well.

`main` will contain meshyy source behind `#if MESHYY` after a release merge.
That is expected: the approved binary did not include it.

## When Apple approves version X.Y.Z (build N)

1. Find the commit the approved build was archived from — the
   `chore: bump build number to N` merge on `develop`.
2. Branch `release/vX.Y.Z` at that commit, push, open a PR to `main`, merge
   when green.
3. Tag that commit: `git tag -a vX.Y.Z -m "X.Y.Z (build N)"` and push the tag.
4. Create the GitHub release: title `X.Y.Z (build N)`, notes summarizing the
   user-facing changes with PR references, marked as the latest release.
5. Merge `main` back into `develop` so `develop` stays a superset.

## Invariants

- `git diff vX.Y.Z main` right after a release merge shows at most docs-only
  drift.
- No tag or release exists for a build Apple has not approved.
- The `review-demo` release is not an app release: it hosts the demo video
  whose URL is cited in App Store review notes. Keep it.
