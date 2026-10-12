#!/bin/bash
# ship-testflight.sh <build-number> [--app-store] — one-command TestFlight pipeline.
#
# Encodes the proven build 3-29 recipe: version-bump PR -> CI -> merge ->
# manual-signed archive -> ITMS-90626 metadata gate -> single-step upload ->
# poll to VALID with the silent-rejection alarm. One Pushover per outcome.
# Optional env SHIP_PUSHOVER_MESSAGE replaces the VALID Pushover's body.
#
# --app-store cuts an App Store CANDIDATE instead of a beta: it archives the
# aPlusTerminalAppStore scheme (no MESHYY condition, no Meshyy package),
# refuses a dirty tree at every step, proves the archived binary with
# scripts/check-no-meshyy.sh and an @rpath count of 0, and writes "App Store
# candidate" into the build's TestFlight What to Test notes. The build Aaron
# tests is then the exact build that gets submitted.
#
# Machine-local prerequisites (this is Aaron's Mac Mini pipeline; runs nowhere
# else): relay-ci.keychain + ~/.appstoreconnect key/pass files, full Xcode at
# /Applications/Xcode.app, gh authed as AaronCx.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

USAGE="usage: ship-testflight.sh <build-number> [--app-store]"
BUILD_N="${1:?$USAGE}"
[[ "$BUILD_N" =~ ^[0-9]+$ ]] || { echo "$USAGE" >&2; exit 2; }
APP_STORE=0
for arg in "${@:2}"; do
  case "$arg" in
    --app-store) APP_STORE=1 ;;
    *) echo "unknown argument: $arg" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="6779393452"
TEAM="P6VJJ7XQN9"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_B8TL82C268.p8"
KID="B8TL82C268"
ISSUER="12c7020e-9bb7-4f89-aa7d-0b9818f9bc61"
DEV_DIR="/Applications/Xcode.app/Contents/Developer"
PUSHOVER="$HOME/bin/pushover.sh"
if [[ $APP_STORE -eq 1 ]]; then
  SCHEME="aPlusTerminalAppStore"
  LABEL="App Store candidate build $BUILD_N"
  ARCHIVE_NAME="build-$BUILD_N-appstore"
else
  SCHEME="aPlusTerminal"
  LABEL="build $BUILD_N"
  ARCHIVE_NAME="build-$BUILD_N"
fi
# Durable, not /tmp: the archive is the proof of what was uploaded (strings,
# otool, check-no-meshyy.sh can be re-run on it after the fact).
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/aPlusTerminal"
ARCHIVE="$ARCHIVE_DIR/$ARCHIVE_NAME.xcarchive"
ARCHIVE_LOG="$ARCHIVE_DIR/$ARCHIVE_NAME.log"
GIT_ID=(-c user.name="Aaron Character" -c user.email="116983481+AaronCx@users.noreply.github.com")

die() {
  echo "ABORT: $1" >&2
  "$PUSHOVER" "Ship $LABEL ABORTED" "$1" '' >/dev/null 2>&1 || true
  exit 1
}

# An App Store candidate must be built from exactly what is committed on
# develop. Untracked files count (`--porcelain` lists them): an untracked
# source file inside a synced folder is compiled into the app.
require_clean() {
  local dirty
  dirty=$(git status --porcelain) || die "git status failed ($1)"
  [[ -z "$dirty" ]] || die "working tree dirty $1 — commit or remove first: $(head -5 <<<"$dirty" | tr '\n' ' ')"
}

# asc_call METHOD PATH [JSON_BODY] — one App Store Connect API request.
# Exit 0: stdout is the response JSON. Otherwise stdout is ONE line saying why
# (stdout, not stderr, so a library warning on stderr can never be mistaken
# for the JSON): exit 2 = ASC unreachable (transient, retry); exit 3 = ASC
# answered with "errors" (fatal: e.g. 403
# FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED must not read as "build not
# there yet"); any other exit = this helper itself failed (key, PyJWT). The
# JWT goes to curl through a 0600 header file, never on argv.
asc_call() {
  ASC_ISSUER="$ISSUER" ASC_KID="$KID" ASC_KEY_PATH="$KEY_PATH" python3 -I - "$@" <<'PY'
import json, os, subprocess, sys, tempfile, time
import jwt
method, path = sys.argv[1], sys.argv[2]
body = sys.argv[3] if len(sys.argv) > 3 else None
now = int(time.time())
tok = jwt.encode({'iss': os.environ['ASC_ISSUER'], 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'},
                 open(os.environ['ASC_KEY_PATH']).read(), algorithm='ES256',
                 headers={'kid': os.environ['ASC_KID']})
fd, header = tempfile.mkstemp(prefix='asc-header-')  # mkstemp creates it 0600
try:
    with os.fdopen(fd, 'w') as f:
        f.write('Authorization: Bearer ' + tok + '\n')
        if body:
            f.write('Content-Type: application/json\n')
    url = 'https://api.appstoreconnect.apple.com' + path
    last = 'no response'
    for extra in ([], ['--resolve', 'api.appstoreconnect.apple.com:443:17.56.10.18']):
        cmd = ['curl', '-g', '-sS', '-m', '25', '-X', method, '-H', '@' + header, *extra]
        if body:
            cmd += ['--data-binary', body]
        p = subprocess.run(cmd + [url], capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout.strip():
            last = p.stderr.strip() or f'curl exit {p.returncode}'
            continue
        try:
            d = json.loads(p.stdout)
        except ValueError:
            last = 'non-JSON response'
            continue
        if d.get('errors'):
            e = d['errors'][0]
            print(f"ASC {e.get('status', '?')} {e.get('code', '?')}: {e.get('title', '')} — {e.get('detail', '')}")
            sys.exit(3)
        print(json.dumps(d))
        sys.exit(0)
    print('ASC unreachable: ' + last)
    sys.exit(2)
finally:
    os.unlink(header)
PY
}

# json_get JSON PYTHON_EXPR — evaluate EXPR against the parsed JSON `d`.
json_get() {
  python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# What to Test for an App Store candidate: PATCH the build's en-US
# betaBuildLocalization, or POST one if the build has none yet.
# Same exit codes and failure line as asc_call.
set_what_to_test() {  # set_what_to_test BUILD_ID TEXT
  local out loc_id body
  out=$(asc_call GET "/v1/builds/$1/betaBuildLocalizations?limit=50") || { local rc=$?; echo "$out"; return $rc; }
  loc_id=$(json_get "$out" "next((x['id'] for x in d.get('data', []) if x['attributes'].get('locale') == 'en-US'), '')")
  if [[ -n "$loc_id" ]]; then
    body=$(python3 -I -c 'import json, sys; print(json.dumps({"data": {"type": "betaBuildLocalizations", "id": sys.argv[1], "attributes": {"whatsNew": sys.argv[2]}}}))' "$loc_id" "$2")
    out=$(asc_call PATCH "/v1/betaBuildLocalizations/$loc_id" "$body") || { local rc=$?; echo "$out"; return $rc; }
  else
    body=$(python3 -I -c 'import json, sys; print(json.dumps({"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": sys.argv[2]}, "relationships": {"build": {"data": {"type": "builds", "id": sys.argv[1]}}}}}))' "$1" "$2")
    out=$(asc_call POST "/v1/betaBuildLocalizations" "$body") || { local rc=$?; echo "$out"; return $rc; }
  fi
}

cd "$REPO_DIR"

# [1] Pre-flight: clean tree on fresh develop; marketing version must be ahead of live.
if [[ $APP_STORE -eq 1 ]]; then
  require_clean "before checkout"
else
  [[ -z "$(git status --porcelain)" ]] || die "working tree dirty — commit/stash first"
fi
git checkout develop >/dev/null 2>&1 || die "git checkout develop failed (is develop checked out in another worktree?)"
git pull >/dev/null 2>&1 || die "git pull on develop failed"
[[ $APP_STORE -eq 1 ]] && require_clean "after checkout/pull of develop"
mkt=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}' | tr -d '"')
live=$(curl -sf -m 20 "https://itunes.apple.com/lookup?id=$APP_ID" | python3 -c "import json,sys; r=json.load(sys.stdin)['results']; print(r[0]['version'] if r else '0')")
if [[ -z "$mkt" ]]; then die "could not read MARKETING_VERSION from project.yml"; fi
if [[ "$(printf '%s\n%s\n' "$live" "$mkt" | sort -V | tail -1)" == "$live" && "$mkt" != "$live"01 ]]; then
  if [[ "$mkt" == "$live" ]]; then
    die "MARKETING_VERSION $mkt equals the LIVE store version — the $live train is closed (90062/90186). Bump MARKETING_VERSION in project.yml first."
  fi
fi

# [2] Bump CURRENT_PROJECT_VERSION via PR (project.yml is the source; pbxproj is generated).
cur=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}' | tr -d '"')
if [[ "$cur" != "$BUILD_N" ]]; then
  branch="build/$BUILD_N"
  git checkout -b "$branch" >/dev/null || die "could not create branch $branch"
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 $BUILD_N/" project.yml
  make generate >/dev/null || die "make generate failed on the bump branch"
  grep -q "CURRENT_PROJECT_VERSION = $BUILD_N" aPlusTerminal.xcodeproj/project.pbxproj || die "bump did not land in generated pbxproj"
  git "${GIT_ID[@]}" commit -am "chore: bump build number to $BUILD_N" >/dev/null || die "bump commit failed"
  git push -u origin "$branch" >/dev/null 2>&1 || die "git push of $branch failed"
  pr_url=$(gh pr create --base develop --title "chore: bump build number to $BUILD_N" \
    --body "Build-number bump for TestFlight build $BUILD_N (ship-testflight.sh).") || die "gh pr create failed"
  pr_num=$(basename "$pr_url")
  echo "PR #$pr_num open — watching checks"
  gh pr checks "$pr_num" --watch --fail-fast --interval 15 || die "CI red on bump PR #$pr_num — fix and re-run"
  gh pr merge "$pr_num" --squash --delete-branch >/dev/null || die "merge of PR #$pr_num failed"
  git checkout develop >/dev/null 2>&1 || die "git checkout develop failed after merging PR #$pr_num"
  git pull >/dev/null 2>&1 || die "git pull on develop failed after merging PR #$pr_num"
  make generate >/dev/null || die "make generate failed"
else
  echo "CURRENT_PROJECT_VERSION already $BUILD_N — skipping bump PR"
  make generate >/dev/null || die "make generate failed"
fi
# Generation writes only gitignored files; anything else showing up here would
# be built into the candidate without being on develop.
[[ $APP_STORE -eq 1 ]] && require_clean "after make generate"

# [3] Keychain
security unlock-keychain -p "$(cat "$HOME/.appstoreconnect/relay-ci-keychain-pass")" relay-ci.keychain \
  || die "could not unlock relay-ci.keychain"

# [4] Archive (manual signing; DEVELOPER_DIR mandatory or archives silently no-op)
mkdir -p "$ARCHIVE_DIR" || die "could not create $ARCHIVE_DIR"
rm -rf "$ARCHIVE"
echo "Archiving $SCHEME -> $ARCHIVE (log: $ARCHIVE_LOG)"
DEVELOPER_DIR="$DEV_DIR" xcodebuild -project aPlusTerminal.xcodeproj -scheme "$SCHEME" \
  -destination 'generic/platform=iOS' archive -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM="$TEAM" \
  APLUSTERMINAL_PROFILE_APP="aPlusTerminal App Store" \
  APLUSTERMINAL_PROFILE_WIDGET="aPlusTerminal Widgets App Store" \
  OTHER_CODE_SIGN_FLAGS="--keychain relay-ci.keychain" \
  >"$ARCHIVE_LOG" 2>&1 || { tail -20 "$ARCHIVE_LOG" >&2; die "xcodebuild archive of $SCHEME failed — see $ARCHIVE_LOG"; }
tail -5 "$ARCHIVE_LOG"
[[ -d "$ARCHIVE/Products" ]] || die "archive produced nothing (DEVELOPER_DIR? signing?)"

# [5] ITMS-90626 gate: platform words in App Intents metadata = silent ingest rejection.
meta=$(find "$ARCHIVE/Products" -type d -name 'Metadata.appintents' | head -1)
if [[ -n "$meta" ]] && grep -riE 'mac|iphone|ipad|siri|apple' "$meta" >/dev/null 2>&1; then
  die "ITMS-90626 gate: platform word found in $meta — fix App Intents phrases before uploading"
fi

# [5b] dyld gate (build-30 lesson): every @rpath framework the app binary
# references must exist inside the bundle's Frameworks/ — a missing embed
# (e.g. a dynamic SPM product XcodeGen doesn't embed) passes CI, the full
# test suite, sim runs, AND ASC processing, then aborts at launch on device.
app_dir=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' | head -1)
[[ -n "$app_dir" ]] || die "no .app in $ARCHIVE/Products/Applications"
app_bin="$app_dir/$(basename "$app_dir" .app)"
[[ -f "$app_bin" ]] || die "app binary $app_bin missing"
while read -r fw; do
  [[ -z "$fw" ]] && continue
  [[ -e "$app_dir/Frameworks/$fw" ]] \
    || die "dyld gate: app binary references @rpath/$fw but it is NOT embedded in Frameworks/ — this archive would crash at launch on device"
done < <(DEVELOPER_DIR="$DEV_DIR" xcrun otool -L "$app_bin" \
  | grep -oE '@rpath/[^/]+\.framework' | sed 's|@rpath/||' | sort -u)

# [5c] Asset-bundle gate: both compiled catalogs exist and carry every agent
# icon from AgentIcons.xcassets (the app draws them in rows; the widget draws
# them on the Live Activity and Dynamic Island).
widget_dir="$app_dir/PlugIns/aPlusTerminalWidgets.appex"
icons=$(find AgentIcons.xcassets -maxdepth 1 -name '*.imageset' -exec basename {} .imageset \; | LC_ALL=C sort)
[[ -n "$icons" ]] || die "asset gate: no agent icons found in AgentIcons.xcassets"
for car in "$app_dir/Assets.car" "$widget_dir/Assets.car"; do
  [[ -f "$car" ]] || die "asset gate: $car missing from the archive"
  names=$(DEVELOPER_DIR="$DEV_DIR" xcrun assetutil --info "$car" 2>/dev/null \
    | python3 -I -c 'import json, sys; print("\n".join(sorted({a["Name"] for a in json.load(sys.stdin) if "Name" in a})))') \
    || die "asset gate: assetutil could not read $car"
  missing=$(LC_ALL=C comm -23 <(echo "$icons") <(echo "$names") | tr '\n' ' ')
  [[ -z "$missing" ]] || die "asset gate: $(basename "$(dirname "$car")")/Assets.car lacks agent icons: $missing"
done
echo "asset gate: Assets.car present in app and widget, $(wc -l <<<"$icons" | tr -d ' ') agent icons in each"

if [[ $APP_STORE -eq 1 ]]; then
  # [5d] App Store candidate: no @rpath dylib references at all. Every package
  # links statically into a Release device build, so a reference here means a
  # dynamic framework was pulled in — the build-30 crash class, and for a
  # candidate also an unreviewed dependency.
  rpaths=$(DEVELOPER_DIR="$DEV_DIR" xcrun otool -L "$app_bin" | grep -c '@rpath/' || true)
  [[ "$rpaths" -eq 0 ]] || die "dyld gate: App Store candidate binary has $rpaths @rpath reference(s); expected 0"
  echo "dyld gate: 0 @rpath references in $(basename "$app_bin")"

  # [5e] meshyy is compiled out — proven on the archived binary itself.
  "$REPO_DIR/scripts/check-no-meshyy.sh" "$app_dir" \
    || die "check-no-meshyy.sh FAILED on $app_dir — meshyy is in the App Store candidate; do not upload"
fi

# [6] Single-step upload (no separate export+altool)
exp=$(mktemp -t exportopts).plist
cat > "$exp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
  <key>provisioningProfiles</key><dict>
    <key>com.aaroncx.aplusterminal</key><string>aPlusTerminal App Store</string>
    <key>com.aaroncx.aplusterminal.widgets</key><string>aPlusTerminal Widgets App Store</string>
  </dict>
</dict></plist>
PLIST
DEVELOPER_DIR="$DEV_DIR" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$exp" -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KID" -authenticationKeyIssuerID "$ISSUER" \
  >>"$ARCHIVE_LOG" 2>&1 || { rm -f "$exp"; tail -20 "$ARCHIVE_LOG" >&2; die "export/upload of $LABEL failed — see $ARCHIVE_LOG"; }
tail -5 "$ARCHIVE_LOG"
rm -f "$exp"

# [7] Poll to VALID. Baseline: healthy uploads go VALID in 1-2 min; missing at
# 10 min = silent email-only ingest rejection (ITMS class) — alarm but keep polling.
# An ASC "errors" answer (e.g. 403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED)
# is NOT "absent": it dies at once with ASC's own message.
WHAT_TO_TEST="App Store candidate — $mkt (build $BUILD_N). meshyy is compiled out of this binary. This is the exact build that will be submitted."
notes_written=0
notes_err="never attempted: build not found"
echo "Polling ASC for build $BUILD_N processingState..."
alarmed=0
state="ABSENT"
for i in $(seq 1 60); do
  if resp=$(asc_call GET "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD_N&limit=1"); then
    state=$(json_get "$resp" "d['data'][0]['attributes']['processingState'] if d.get('data') else 'ABSENT'")
    build_id=$(json_get "$resp" "d['data'][0]['id'] if d.get('data') else ''")
  else
    rc=$?
    [[ $rc -eq 2 ]] || die "App Store Connect build query failed (exit $rc): $resp"
    echo "poll $i: $resp (retrying)"
    state="UNREACHABLE"
  fi
  # App Store candidates: record what this build is as soon as it exists.
  # ASC may refuse the write while the build is still processing, so a
  # refusal is retried on the next poll; only at VALID is it fatal (below).
  if [[ $APP_STORE -eq 1 && $notes_written -eq 0 && -n "${build_id:-}" ]]; then
    if notes_err=$(set_what_to_test "$build_id" "$WHAT_TO_TEST"); then
      notes_written=1
      echo "What to Test set: $WHAT_TO_TEST"
    else
      echo "What to Test not set yet: $notes_err (retrying)"
    fi
  fi
  if [[ "$state" == "VALID" ]]; then
    [[ $APP_STORE -eq 1 && $notes_written -eq 0 ]] \
      && die "$LABEL is VALID but its What to Test notes could not be written ($notes_err) — set \"$WHAT_TO_TEST\" before handing it to Aaron"
    if [[ $APP_STORE -eq 1 ]]; then
      title="App Store candidate build $BUILD_N VALID"
      default_body="App Store candidate $mkt (build $BUILD_N) processed clean in ~$((i / 2)) min. meshyy is compiled out (check-no-meshyy.sh passed on the archive) and What to Test says so. This is the exact build that will be submitted — state build $BUILD_N when testing."
    else
      title="TestFlight build $BUILD_N VALID"
      default_body="Upload processed clean in ~$((i / 2)) min. Install via TestFlight — state the build number when testing."
    fi
    # SHIP_PUSHOVER_MESSAGE (optional) replaces the body — e.g. what Aaron
    # should try on this build — so a release needs ONE Pushover, not two.
    "$PUSHOVER" "$title" \
      "${SHIP_PUSHOVER_MESSAGE:-$default_body}" \
      "https://appstoreconnect.apple.com/apps/$APP_ID/testflight/ios" >/dev/null 2>&1
    echo "$LABEL VALID"
    exit 0
  fi
  if [[ "$state" == "INVALID" || "$state" == "FAILED" ]]; then
    die "build $BUILD_N processingState=$state — check ASC"
  fi
  if [[ $i -eq 20 && "$state" == "ABSENT" && $alarmed -eq 0 ]]; then
    alarmed=1
    "$PUSHOVER" "Build $BUILD_N MISSING at 10 min — likely silent rejection" \
      "Baseline is VALID in 1-2 min. Check aaronc3214@icloud.com for the ITMS code (e.g. ITMS-90626). Still polling to 30 min." \
      '' >/dev/null 2>&1
  fi
  sleep 30
done
die "build $BUILD_N not VALID after 30 min (state=$state)"
