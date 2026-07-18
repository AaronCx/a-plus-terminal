#!/bin/bash
# ship-testflight.sh <build-number> — one-command TestFlight pipeline.
#
# Encodes the proven build 3-29 recipe: version-bump PR -> CI -> merge ->
# manual-signed archive -> ITMS-90626 metadata gate -> single-step upload ->
# poll to VALID with the silent-rejection alarm. One Pushover per outcome.
#
# Machine-local prerequisites (this is Aaron's Mac Mini pipeline; runs nowhere
# else): relay-ci.keychain + ~/.appstoreconnect key/pass files, full Xcode at
# /Applications/Xcode.app, gh authed as AaronCx.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

BUILD_N="${1:?usage: ship-testflight.sh <build-number>}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="6779393452"
TEAM="P6VJJ7XQN9"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_B8TL82C268.p8"
KID="B8TL82C268"
ISSUER="12c7020e-9bb7-4f89-aa7d-0b9818f9bc61"
DEV_DIR="/Applications/Xcode.app/Contents/Developer"
PUSHOVER="$HOME/bin/pushover.sh"
ARCHIVE="/tmp/aPlusTerminal-build$BUILD_N.xcarchive"
GIT_ID=(-c user.name="Aaron Character" -c user.email="116983481+AaronCx@users.noreply.github.com")

die() {
  echo "ABORT: $1" >&2
  "$PUSHOVER" "Ship build $BUILD_N ABORTED" "$1" '' >/dev/null 2>&1 || true
  exit 1
}

cd "$REPO_DIR"

# [1] Pre-flight: clean tree on fresh main; marketing version must be ahead of live.
[[ -z "$(git status --porcelain)" ]] || die "working tree dirty — commit/stash first"
git checkout main >/dev/null 2>&1
git pull >/dev/null 2>&1
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
  git checkout -b "$branch" >/dev/null
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 $BUILD_N/" project.yml
  make generate >/dev/null
  grep -q "CURRENT_PROJECT_VERSION = $BUILD_N" aPlusTerminal.xcodeproj/project.pbxproj || die "bump did not land in generated pbxproj"
  git "${GIT_ID[@]}" commit -am "chore: bump build number to $BUILD_N" >/dev/null
  git push -u origin "$branch" >/dev/null 2>&1
  pr_url=$(gh pr create --base main --title "chore: bump build number to $BUILD_N" \
    --body "Build-number bump for TestFlight build $BUILD_N (ship-testflight.sh).")
  pr_num=$(basename "$pr_url")
  echo "PR #$pr_num open — watching checks"
  gh pr checks "$pr_num" --watch --fail-fast --interval 15 || die "CI red on bump PR #$pr_num — fix and re-run"
  gh pr merge "$pr_num" --squash --delete-branch >/dev/null || die "merge of PR #$pr_num failed"
  git checkout main >/dev/null 2>&1 && git pull >/dev/null 2>&1
  make generate >/dev/null
else
  echo "CURRENT_PROJECT_VERSION already $BUILD_N — skipping bump PR"
  make generate >/dev/null
fi

# [3] Keychain
security unlock-keychain -p "$(cat "$HOME/.appstoreconnect/relay-ci-keychain-pass")" relay-ci.keychain

# [4] Archive (manual signing; DEVELOPER_DIR mandatory or archives silently no-op)
rm -rf "$ARCHIVE"
DEVELOPER_DIR="$DEV_DIR" xcodebuild -project aPlusTerminal.xcodeproj -scheme aPlusTerminal \
  -destination 'generic/platform=iOS' archive -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM="$TEAM" \
  APLUSTERMINAL_PROFILE_APP="aPlusTerminal App Store" \
  APLUSTERMINAL_PROFILE_WIDGET="aPlusTerminal Widgets App Store" \
  OTHER_CODE_SIGN_FLAGS="--keychain relay-ci.keychain" \
  | tail -5
[[ -d "$ARCHIVE/Products" ]] || die "archive produced nothing (DEVELOPER_DIR? signing?)"

# [5] ITMS-90626 gate: platform words in App Intents metadata = silent ingest rejection.
meta=$(find "$ARCHIVE/Products" -type d -name 'Metadata.appintents' | head -1)
if [[ -n "$meta" ]] && grep -riE 'mac|iphone|ipad|siri|apple' "$meta" >/dev/null 2>&1; then
  die "ITMS-90626 gate: platform word found in $meta — fix App Intents phrases before uploading"
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
  | tail -5
rm -f "$exp"

# [7] Poll to VALID. Baseline: healthy uploads go VALID in 1-2 min; missing at
# 10 min = silent email-only ingest rejection (ITMS class) — alarm but keep polling.
echo "Polling ASC for build $BUILD_N processingState..."
alarmed=0
for i in $(seq 1 60); do
  state=$(python3 - <<PY 2>/dev/null
import json, subprocess, time
import jwt
now = int(time.time())
tok = jwt.encode({'iss': '$ISSUER', 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'},
                 open('$KEY_PATH').read(), algorithm='ES256', headers={'kid': '$KID'})
url = 'https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD_N&limit=1'
for extra in ([], ['--resolve', 'api.appstoreconnect.apple.com:443:17.56.10.18']):
    p = subprocess.run(['curl', '-g', '-sS', '-m', '25', '-H', 'Authorization: Bearer ' + tok, *extra, url],
                       capture_output=True, text=True)
    if p.returncode == 0 and p.stdout.strip():
        try:
            d = json.loads(p.stdout).get('data', [])
            print(d[0]['attributes']['processingState'] if d else 'ABSENT')
            break
        except Exception:
            continue
PY
)
  if [[ "$state" == "VALID" ]]; then
    "$PUSHOVER" "TestFlight build $BUILD_N VALID" \
      "Upload processed clean in ~$((i / 2)) min. Install via TestFlight — state the build number when testing." \
      "https://appstoreconnect.apple.com/apps/$APP_ID/testflight/ios" >/dev/null 2>&1
    echo "build $BUILD_N VALID"
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
