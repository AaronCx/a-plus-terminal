#!/bin/bash
# ship-ci-archive.sh <build-number> <archive.zip> <commit-sha> [--app-store]
# — sign and upload a TestFlight build whose archive was built on CI.
#
# Why this exists: the iPhone Duo work needs the iOS 27.1 SDK (Xcode 27.1),
# which this Mac Mini doesn't have. So .github/workflows/duo-archive.yml
# archives the App Store scheme UNSIGNED on GitHub's xcode-27 image, and this
# script does the rest here, where the signing identity lives: no signing
# material ever reaches GitHub.
#
# Without --app-store it ships a TEST build, and What to Test says it is not a
# candidate. With --app-store it ships an App Store candidate. That requires
# an archive from the Xcode 27.1 release (RELEASE_XCODE_BUILD): App Store
# Connect takes beta-Xcode builds for TestFlight only, never for review.
# Every other build still goes through ship-testflight.sh.
#
# Steps:
#  1. The tree is clean, and <commit-sha> is the remote branch head the
#     archive was built from. With --app-store, ci.yml passed on it.
#  2. Unpack the archive. Its CFBundleVersion must equal <build-number>, it
#     must have been built with the iOS 27.1 SDK and, with --app-store, with
#     the Xcode 27.1 release.
#  3. Sign the widget, then the app, with the Apple Distribution identity and
#     the entitlements the last ship-testflight archive was signed with (the
#     entitlements files are unchanged since then; checked against the
#     reference archive's commit).
#  4. The archive gates of ship-testflight.sh --app-store:
#     - ITMS-90626, dyld/@rpath (0 references), asset bundles;
#     - check-no-meshyy.sh on the archived app;
#     - plus agent-notification copy that matches the commit's project.yml
#       switch, AGENT_NOTIFY_CONDITION: absent when it is empty (compiled
#       out, as in the 1.0.4 candidate), present when it is AGENT_NOTIFY
#       (develop).
#     Its Debug-build meshyy check runs in ci.yml instead, so --app-store
#     also requires ci.yml green on the commit (step 1).
#  5. Upload with xcodebuild -exportArchive (Xcode 26.5 here).
#  6. Poll to VALID, write What to Test, and send ONE Pushover.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

USAGE="usage: ship-ci-archive.sh <build-number> <archive.zip> <commit-sha> [--app-store]"
(( $# >= 3 && $# <= 4 )) || { echo "$USAGE" >&2; exit 2; }
BUILD_N="$1"; ZIP="$2"; SHA="$3"
[[ "$BUILD_N" =~ ^[0-9]+$ ]] || { echo "$USAGE" >&2; exit 2; }
case "${4:-}" in
  "") APP_STORE=0 ;;
  --app-store) APP_STORE=1 ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
# The Xcode 27.1 release. Keep in step with the pin in duo-archive.yml.
RELEASE_XCODE_BUILD="27A9275"
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
if (( APP_STORE )); then
  ARCHIVE="$ARCHIVE_DIR/build-$BUILD_N-appstore.xcarchive"
  LOG="$ARCHIVE_DIR/build-$BUILD_N-appstore.log"
  LABEL="App Store candidate $BUILD_N"
else
  ARCHIVE="$ARCHIVE_DIR/build-$BUILD_N-duo-test.xcarchive"
  LOG="$ARCHIVE_DIR/build-$BUILD_N-duo-test.log"
  LABEL="test build $BUILD_N"
fi
# Entitlements source: the last archive ship-testflight.sh signed, and the
# commit it was built from.
REF_ARCHIVE="${REF_ARCHIVE:-$ARCHIVE_DIR/build-76-appstore.xcarchive}"
REF_COMMIT="${REF_COMMIT:-ec114a4}"

die() {
  echo "ABORT: $1" >&2
  "$PUSHOVER" "Ship $LABEL ABORTED" "$1" '' >/dev/null 2>&1 || true
  exit 1
}

cd "$REPO_DIR"
mkdir -p "$ARCHIVE_DIR" || die "could not create $ARCHIVE_DIR"
# --app-store names match ship-testflight.sh's, so never touch the archive the
# entitlements come from.
[[ "$ARCHIVE" != "$REF_ARCHIVE" ]] || die "build $BUILD_N's archive is the entitlements reference $REF_ARCHIVE — refusing to replace it"

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
# Agent notifications follow project.yml's AGENT_NOTIFY_CONDITION switch:
# empty compiles them out, AGENT_NOTIFY compiles them in. Exactly one line may
# set it, so a second (say, target-level) value can't go unnoticed.
notify_lines=$(git show "$remote_head:project.yml" | grep '^ *AGENT_NOTIFY_CONDITION:' || true)
[[ $(grep -c . <<<"$notify_lines") -eq 1 ]] \
  || die "project.yml must set AGENT_NOTIFY_CONDITION on exactly one line; found: ${notify_lines:-none}"
notify_switch=$(sed 's/^ *AGENT_NOTIFY_CONDITION: *//' <<<"$notify_lines" | tr -d '"')
case "$notify_switch" in
  "") NOTIFY=0 ;;
  AGENT_NOTIFY) NOTIFY=1 ;;
  *) die "project.yml's AGENT_NOTIFY_CONDITION is '$notify_switch'; expected empty or AGENT_NOTIFY" ;;
esac
if (( APP_STORE )); then
  # The Debug-build meshyy check (make build-appstore check-appstore) runs in
  # ci.yml, not here, so a candidate needs ci.yml green on this exact commit.
  ci=$(gh run list -R AaronCx/a-plus-terminal --workflow ci.yml --commit "$remote_head" \
    --json conclusion --jq '.[0].conclusion // ""') || die "could not read ci.yml's result for ${remote_head:0:9}"
  [[ "$ci" == success ]] || die "ci.yml on ${remote_head:0:9} is '${ci:-missing}'; it runs the Debug-build meshyy check a candidate needs"
fi

# [2] Unpack and identify. Checks run on a temporary copy, so a wrong build
# number or archive never replaces an existing archive or empties its log.
tmp=$(mktemp -d "$ARCHIVE_DIR/.unpack.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
ditto -x -k "$ZIP" "$tmp" || die "could not unzip $ZIP"
src=$(find "$tmp" -maxdepth 1 -name '*.xcarchive' | head -1)
[[ -n "$src" ]] || die "no .xcarchive inside $ZIP"
app_rel="Products/Applications/aPlusTerminal.app"
widget_rel="$app_rel/PlugIns/aPlusTerminalWidgets.appex"
[[ -d "$src/$app_rel" && -d "$src/$widget_rel" ]] || die "archive lacks the app or the widget"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
ver=$(plist "$src/$app_rel" CFBundleVersion); mkt=$(plist "$src/$app_rel" CFBundleShortVersionString)
sdk=$(plist "$src/$app_rel" DTSDKName); xc=$(plist "$src/$app_rel" DTXcodeBuild)
[[ "$ver" == "$BUILD_N" ]] || die "archive CFBundleVersion is $ver, expected $BUILD_N"
[[ "$(plist "$src/$widget_rel" CFBundleVersion)" == "$BUILD_N" ]] || die "widget CFBundleVersion differs from $BUILD_N"
[[ "$sdk" == iphoneos27.1* ]] || die "archive built with $sdk, expected the iOS 27.1 SDK"
if (( APP_STORE )); then
  [[ "$xc" == "$RELEASE_XCODE_BUILD" ]] \
    || die "archive built with Xcode $xc; an App Store candidate needs the Xcode 27.1 release ($RELEASE_XCODE_BUILD)"
fi
rm -rf "$ARCHIVE"
mv "$src" "$ARCHIVE"
app_dir="$ARCHIVE/$app_rel"
widget_dir="$ARCHIVE/$widget_rel"
: >"$LOG"
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
# The notification copy must match the switch. Capture the strings once:
# under pipefail, `strings | grep -q` reads a hit as a miss (grep exits on the
# match and strings dies of SIGPIPE).
copy=$(strings -a "$app_bin" "$widget_dir/aPlusTerminalWidgets") || die "strings failed on $app_bin"
for needle in 'Send test notification' 'preferredNotifChannel' 'To get notified' \
  'requestAuthorizationWithOptions:completionHandler:'; do
  if grep -qF -- "$needle" <<<"$copy"; then has=1; else has=0; fi
  if (( NOTIFY && !has )); then
    die "agent-notification copy \"$needle\" is missing; this commit's AGENT_NOTIFY_CONDITION is AGENT_NOTIFY, so notifications must be compiled in"
  elif (( !NOTIFY && has )); then
    die "agent-notification copy \"$needle\" is in the binary; this commit's AGENT_NOTIFY_CONDITION is empty, so notifications must be compiled out"
  fi
done
if (( NOTIFY )); then notify_gate="notification copy present"; else notify_gate="no notification copy"; fi
echo "gates: ITMS-90626 ok, 0 @rpath, $(wc -l <<<"$icons" | tr -d ' ') agent icons in app and widget, no meshyy, $notify_gate" | tee -a "$LOG"

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
if (( APP_STORE )); then
  if (( NOTIFY )); then
    notify_note="Agent notifications are compiled in."
  else
    notify_note="Agent notifications are compiled out and come back in a later release; the agent badge, Live Activity, custom agents and Sessions widget are unchanged."
  fi
  WHAT_TO_TEST="App Store candidate — $mkt (build $BUILD_N), the iPhone Duo build, from branch $branch @ ${SHA:0:9}, built on CI with Xcode 27.1 ($xc, iOS 27.1 SDK). This is the build that gets submitted. $notify_note"
  VALID_TITLE="App Store candidate $BUILD_N VALID"
else
  if (( NOTIFY )); then
    notify_note="Agent notifications are compiled in."
  else
    notify_note="Agent notifications are compiled out of this build; the agent badge, Live Activity and custom agents are unchanged."
  fi
  WHAT_TO_TEST="TEST build — $mkt (build $BUILD_N) from branch $branch @ ${SHA:0:9}, built on CI with Xcode build $xc (iOS 27.1 SDK) for iPhone Duo support. Not an App Store candidate and never to be submitted. $notify_note"
  VALID_TITLE="TestFlight test build $BUILD_N VALID"
fi
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
    "$PUSHOVER" "$VALID_TITLE" \
      "${SHIP_PUSHOVER_MESSAGE:-$WHAT_TO_TEST}" \
      "https://appstoreconnect.apple.com/apps/$APP_ID/testflight/ios" >/dev/null 2>&1 \
      || echo "warning: the VALID Pushover did not send" >&2
    echo "$LABEL VALID"
    exit 0
  fi
  [[ "$state" == "INVALID" || "$state" == "FAILED" ]] && die "build $BUILD_N processingState=$state"
  if [[ $i -eq 20 && "$state" == "ABSENT" && $alarmed -eq 0 ]]; then
    alarmed=1
    "$PUSHOVER" "Build $BUILD_N MISSING at 10 min — likely silent rejection" \
      "Baseline is VALID in 1-2 min. Check aaronc3214@icloud.com for the ITMS code. Still polling to 30 min." \
      '' >/dev/null 2>&1 || true
  fi
  echo "poll $i: $state"
  sleep 30
done
die "build $BUILD_N not VALID after 30 min (last state: $state)"
