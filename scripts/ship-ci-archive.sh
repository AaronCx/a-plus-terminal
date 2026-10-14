#!/bin/bash
# ship-ci-archive.sh <build-number> <archive.zip> <commit-sha> — sign and upload
# a TestFlight TEST build whose archive was built on CI.
#
# Why this exists: the iPhone Duo work needs the iOS 27.1 SDK (Xcode 27.1),
# and Xcode 27.1 needs macOS 26.6+, which this Mac Mini doesn't run yet. So
# .github/workflows/duo-archive.yml archives the App Store scheme UNSIGNED on
# GitHub's xcode-27 image, and this script does the rest here, where the
# signing identity lives: no signing material ever reaches GitHub.
#
# It is NOT a release path. ship-testflight.sh stays the only way to cut a
# beta or an App Store candidate. The image's Xcode 27.1 is beta 1, and App
# Store Connect accepts beta-SDK builds for TestFlight only, so a build from
# here can be tested but never submitted. What to Test says so.
#
# Steps:
#  1. The tree is clean, and <commit-sha> is the remote branch head the
#     archive was built from.
#  2. Unpack the archive. Its CFBundleVersion must equal <build-number>, and
#     it must have been built with the iOS 27.1 SDK.
#  3. Sign the widget, then the app, with the Apple Distribution identity and
#     the entitlements the last ship-testflight archive was signed with (the
#     entitlements files are unchanged since then; checked against the
#     reference archive's commit).
#  4. The same gates as ship-testflight.sh --app-store:
#     - ITMS-90626, dyld/@rpath (0 references), asset bundles;
#     - check-no-meshyy.sh;
#     - plus no agent-notification copy.
#  5. Upload with xcodebuild -exportArchive (Xcode 26.5 here).
#  6. Poll to VALID, write What to Test, and send ONE Pushover.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

USAGE="usage: ship-ci-archive.sh <build-number> <archive.zip> <commit-sha>"
BUILD_N="${1:?$USAGE}"; ZIP="${2:?$USAGE}"; SHA="${3:?$USAGE}"
[[ "$BUILD_N" =~ ^[0-9]+$ ]] || { echo "$USAGE" >&2; exit 2; }
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="6779393452"
TEAM="P6VJJ7XQN9"
IDENTITY="Apple Distribution: Aaron Character ($TEAM)"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_B8TL82C268.p8"
KID="B8TL82C268"
ISSUER="12c7020e-9bb7-4f89-aa7d-0b9818f9bc61"
DEV_DIR="/Applications/Xcode.app/Contents/Developer"
PUSHOVER="$HOME/bin/pushover.sh"
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/aPlusTerminal"
ARCHIVE="$ARCHIVE_DIR/build-$BUILD_N-duo-test.xcarchive"
LOG="$ARCHIVE_DIR/build-$BUILD_N-duo-test.log"
# Entitlements source: the last archive ship-testflight.sh signed, and the
# commit it was built from.
REF_ARCHIVE="${REF_ARCHIVE:-$ARCHIVE_DIR/build-76-appstore.xcarchive}"
REF_COMMIT="${REF_COMMIT:-ec114a4}"
LABEL="test build $BUILD_N"

die() {
  echo "ABORT: $1" >&2
  "$PUSHOVER" "Ship $LABEL ABORTED" "$1" '' >/dev/null 2>&1 || true
  exit 1
}

cd "$REPO_DIR"
mkdir -p "$ARCHIVE_DIR" || die "could not create $ARCHIVE_DIR"
: >"$LOG"

# [1] Provenance: clean tree; the archive's commit is this branch's pushed head.
[[ -z "$(git status --porcelain)" ]] || die "working tree dirty — commit or remove first"
branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" == test/* ]] || die "on $branch — this script ships test/* branches only"
remote_head=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
[[ -n "$remote_head" ]] || die "could not read origin/$branch"
[[ "$remote_head" == "$SHA"* && "$(git rev-parse HEAD)" == "$remote_head" ]] \
  || die "archive commit $SHA, local HEAD $(git rev-parse --short HEAD) and origin/$branch ${remote_head:0:9} must all match"
git diff --quiet "$REF_COMMIT" HEAD -- '*.entitlements' \
  || die "entitlements changed since $REF_COMMIT — the reference archive's entitlements no longer apply"

# [2] Unpack and identify.
rm -rf "$ARCHIVE"
tmp=$(mktemp -d "$ARCHIVE_DIR/.unpack.XXXXXX")
ditto -x -k "$ZIP" "$tmp" || die "could not unzip $ZIP"
src=$(find "$tmp" -maxdepth 1 -name '*.xcarchive' | head -1)
[[ -n "$src" ]] || die "no .xcarchive inside $ZIP"
mv "$src" "$ARCHIVE" && rm -rf "$tmp"
app_dir="$ARCHIVE/Products/Applications/aPlusTerminal.app"
widget_dir="$app_dir/PlugIns/aPlusTerminalWidgets.appex"
[[ -d "$app_dir" && -d "$widget_dir" ]] || die "archive lacks the app or the widget"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
ver=$(plist "$app_dir" CFBundleVersion); mkt=$(plist "$app_dir" CFBundleShortVersionString)
sdk=$(plist "$app_dir" DTSDKName); xc=$(plist "$app_dir" DTXcodeBuild)
[[ "$ver" == "$BUILD_N" ]] || die "archive CFBundleVersion is $ver, expected $BUILD_N"
[[ "$(plist "$widget_dir" CFBundleVersion)" == "$BUILD_N" ]] || die "widget CFBundleVersion differs from $BUILD_N"
[[ "$sdk" == iphoneos27.1* ]] || die "archive built with $sdk, expected the iOS 27.1 SDK"
echo "archive: $mkt ($ver), SDK $sdk, Xcode build $xc, commit ${SHA:0:9}" | tee -a "$LOG"

# [3] Sign: widget first, then the app that contains it.
kc_pass=$(<"$HOME/.appstoreconnect/relay-ci-keychain-pass") || die "could not read the relay-ci.keychain password file"
[[ "$kc_pass" != *[\"\\]* ]] || die "relay-ci.keychain password contains a quote or backslash, which security -i cannot take"
printf 'unlock-keychain -p "%s" relay-ci.keychain\n' "$kc_pass" | security -i >/dev/null 2>&1 \
  || { unset kc_pass; die "could not unlock relay-ci.keychain"; }
unset kc_pass
ent=$(mktemp -d "$ARCHIVE_DIR/.ent.XXXXXX")
ref_app="$REF_ARCHIVE/Products/Applications/aPlusTerminal.app"
codesign -d --entitlements - --xml "$ref_app/PlugIns/aPlusTerminalWidgets.appex" >"$ent/widget.plist" 2>/dev/null \
  && codesign -d --entitlements - --xml "$ref_app" >"$ent/app.plist" 2>/dev/null \
  || die "could not read entitlements from $REF_ARCHIVE"
for f in "$ent"/*.plist; do
  plutil -lint "$f" >/dev/null || die "bad entitlements extracted: $f"
  grep -q '<key>get-task-allow</key><false/>' <(plutil -convert xml1 -o - "$f" | tr -d ' \n\t') \
    || die "$(basename "$f") entitlements are not distribution (get-task-allow is not false)"
done
for target in "$widget_dir:$ent/widget.plist" "$app_dir:$ent/app.plist"; do
  codesign --force --sign "$IDENTITY" --keychain relay-ci.keychain --timestamp=none \
    --entitlements "${target#*:}" "${target%%:*}" >>"$LOG" 2>&1 || die "codesign failed on ${target%%:*} — see $LOG"
done
rm -rf "$ent"
codesign --verify --deep --strict "$app_dir" >>"$LOG" 2>&1 || die "signature does not verify — see $LOG"

# [4] Gates (same as ship-testflight.sh --app-store, on this archive).
meta=$(find "$ARCHIVE/Products" -type d -name 'Metadata.appintents' | head -1)
if [[ -n "$meta" ]] && grep -riE 'mac|iphone|ipad|siri|apple' "$meta" >/dev/null 2>&1; then
  die "ITMS-90626 gate: platform word found in $meta"
fi
app_bin="$app_dir/aPlusTerminal"
libs=$(DEVELOPER_DIR="$DEV_DIR" xcrun otool -L "$app_bin") || die "otool -L failed on $app_bin"
rpaths=$(grep -c '@rpath/' <<<"$libs" || true)
[[ "$rpaths" -eq 0 ]] || die "dyld gate: $rpaths @rpath reference(s); expected 0"
icons=$(find AgentIcons.xcassets -maxdepth 1 -name '*.imageset' -exec basename {} .imageset \; | LC_ALL=C sort)
for car in "$app_dir/Assets.car" "$widget_dir/Assets.car"; do
  [[ -f "$car" ]] || die "asset gate: $car missing"
  names=$(DEVELOPER_DIR="$DEV_DIR" xcrun assetutil --info "$car" 2>/dev/null \
    | python3 -I -c 'import json, sys; print("\n".join(sorted({a["Name"] for a in json.load(sys.stdin) if "Name" in a})))') \
    || die "asset gate: assetutil could not read $car"
  missing=$(LC_ALL=C comm -23 <(echo "$icons") <(echo "$names") | tr '\n' ' ')
  [[ -z "$missing" ]] || die "asset gate: $car lacks agent icons: $missing"
done
"$REPO_DIR/scripts/check-no-meshyy.sh" "$app_dir" >>"$LOG" 2>&1 || die "check-no-meshyy.sh FAILED on the archive — see $LOG"
for needle in 'Send test notification' 'preferredNotifChannel' 'To get notified'; do
  if strings -a "$app_bin" "$widget_dir/aPlusTerminalWidgets" | grep -qF "$needle"; then
    die "agent-notification copy \"$needle\" is in the binary; this build must have notifications compiled out"
  fi
done
echo "gates: ITMS-90626 ok, 0 @rpath, $(wc -l <<<"$icons" | tr -d ' ') agent icons in app and widget, no meshyy, no notification copy" | tee -a "$LOG"

# [5] Upload (Xcode 26.5's exportArchive re-signs with the App Store profiles).
exp=$(mktemp -t exportopts).plist
cat >"$exp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
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
  >>"$LOG" 2>&1 || { rm -f "$exp"; tail -20 "$LOG" >&2; die "export/upload failed — see $LOG"; }
rm -f "$exp"
tail -3 "$LOG"

# [6] Poll to VALID; What to Test; one Pushover.
asc_call() {  # asc_call METHOD PATH [BODY] — exit 0 JSON / 2 unreachable / 3 ASC error
  ASC_ISSUER="$ISSUER" ASC_KID="$KID" ASC_KEY_PATH="$KEY_PATH" python3 -I - "$@" <<'PY'
import json, os, subprocess, sys, tempfile, time
import jwt
method, path = sys.argv[1], sys.argv[2]
body = sys.argv[3] if len(sys.argv) > 3 else None
now = int(time.time())
with open(os.environ['ASC_KEY_PATH']) as key:
    tok = jwt.encode({'iss': os.environ['ASC_ISSUER'], 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'},
                     key.read(), algorithm='ES256', headers={'kid': os.environ['ASC_KID']})
fd, header = tempfile.mkstemp(prefix='asc-header-')
try:
    with os.fdopen(fd, 'w') as f:
        f.write('Authorization: Bearer ' + tok + '\n')
        if body:
            f.write('Content-Type: application/json\n')
    for extra in ([], ['--resolve', 'api.appstoreconnect.apple.com:443:17.56.10.18']):
        cmd = ['curl', '-g', '-sS', '-m', '25', '-X', method, '-H', '@' + header, *extra]
        if body:
            cmd += ['--data-binary', body]
        p = subprocess.run(cmd + ['https://api.appstoreconnect.apple.com' + path], capture_output=True, text=True)
        try:
            d = json.loads(p.stdout)
        except ValueError:
            continue
        if d.get('errors'):
            e = d['errors'][0]
            print(f"ASC {e.get('status')} {e.get('code')}: {e.get('title')} — {e.get('detail')}")
            sys.exit(3)
        print(json.dumps(d))
        sys.exit(0)
    print('ASC unreachable')
    sys.exit(2)
finally:
    os.unlink(header)
PY
}
json_get() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }
WHAT_TO_TEST="TEST build — $mkt (build $BUILD_N) from branch $branch @ ${SHA:0:9}. NOT the $mkt App Store candidate (that is build 76) and never to be submitted: built with Xcode 27.1 beta 1 (iOS 27.1 SDK) on CI for iPhone Duo support. Agent notifications are compiled out of this build; the agent badge, Live Activity and custom agents are unchanged."
set_what_to_test() {
  local out loc_id body
  out=$(asc_call GET "/v1/builds/$1/betaBuildLocalizations?limit=50") || return $?
  loc_id=$(json_get "$out" "next((x['id'] for x in d.get('data', []) if x['attributes'].get('locale') == 'en-US'), '')")
  if [[ -n "$loc_id" ]]; then
    body=$(python3 -I -c 'import json, sys; print(json.dumps({"data": {"type": "betaBuildLocalizations", "id": sys.argv[1], "attributes": {"whatsNew": sys.argv[2]}}}))' "$loc_id" "$2")
    asc_call PATCH "/v1/betaBuildLocalizations/$loc_id" "$body" >/dev/null
  else
    body=$(python3 -I -c 'import json, sys; print(json.dumps({"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": sys.argv[2]}, "relationships": {"build": {"data": {"type": "builds", "id": sys.argv[1]}}}}}))' "$1" "$2")
    asc_call POST "/v1/betaBuildLocalizations" "$body" >/dev/null
  fi
}
echo "Polling ASC for build $BUILD_N..."
alarmed=0; notes=0; build_id=""
for i in $(seq 1 60); do
  state="ABSENT"
  if resp=$(asc_call GET "/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD_N&limit=1"); then
    state=$(json_get "$resp" "d['data'][0]['attributes']['processingState'] if d.get('data') else 'ABSENT'")
    build_id=$(json_get "$resp" "d['data'][0]['id'] if d.get('data') else ''")
  else
    rc=$?; [[ $rc -eq 2 ]] || die "ASC build query failed: $resp"
  fi
  [[ -n "$build_id" && $notes -eq 0 ]] && set_what_to_test "$build_id" "$WHAT_TO_TEST" && notes=1 && echo "What to Test set"
  if [[ "$state" == "VALID" ]]; then
    [[ $notes -eq 1 ]] || { set_what_to_test "$build_id" "$WHAT_TO_TEST" && notes=1; } \
      || die "build $BUILD_N is VALID but What to Test could not be written — set it before handing the build out"
    "$PUSHOVER" "TestFlight test build $BUILD_N VALID" \
      "${SHIP_PUSHOVER_MESSAGE:-Test build $mkt ($BUILD_N) processed. Not the App Store candidate.}" \
      "https://appstoreconnect.apple.com/apps/$APP_ID/testflight/ios" >/dev/null 2>&1 \
      || echo "warning: the VALID Pushover did not send" >&2
    echo "$LABEL VALID"
    exit 0
  fi
  [[ "$state" == "INVALID" || "$state" == "FAILED" ]] && die "build $BUILD_N processingState=$state"
  if [[ $i -eq 20 && "$state" == "ABSENT" && $alarmed -eq 0 ]]; then
    alarmed=1
    "$PUSHOVER" "Build $BUILD_N MISSING at 10 min — likely silent rejection" \
      "Baseline is VALID in 1-2 min. Check aaronc3214@icloud.com for the ITMS code (a beta-Xcode build would be ITMS-90111). Still polling to 30 min." \
      '' >/dev/null 2>&1 || true
  fi
  echo "poll $i: $state"
  sleep 30
done
die "build $BUILD_N not VALID after 30 min (last state: $state)"
