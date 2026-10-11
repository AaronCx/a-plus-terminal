#!/usr/bin/env bash
# check-no-meshyy.sh <path/to/aPlusTerminal.app> — prove meshyy is compiled
# OUT of an App Store candidate. Exit 0 = PASS, 1 = FAIL, 2 = bad input.
#
# Why a binary check: App Review tests the exact binary that was uploaded, and
# guideline 2.3.1 forbids hidden or dormant features, so "the toggle is off"
# is not enough — the code must not be in the binary at all. The source-level
# gates (`#if MESHYY`, the aPlusTerminalAppStore target that never links the
# Meshyy package) are what make this pass; this script is what proves they
# did, on the artifact itself. Run by CI on the simulator build of the
# aPlusTerminalAppStore scheme and by `ship-testflight.sh N --app-store` on the
# archived app before upload.
#
# Every check runs on every Mach-O in the bundle — the app binary, the widget
# appex binary, and in a Debug simulator build the `*.debug.dylib` that holds
# the actual code (the main binary there is a stub):
#   1. `strings -a` has zero case-insensitive "meshyy" hits (Swift type names
#      and @Observable backing fields survive dead-stripping, so this only
#      passes when the package is unlinked AND every meshyy symbol is gated);
#   2. none of the meshyy / scroll-trace UI copy needles appear (also checked
#      in the bundle's text resources — the bundled privacy policy ships);
#   3. no Meshyy framework or file anywhere in the bundle;
#   4. `otool -L` links nothing Meshyy;
#   5. no QUIC symbol is imported from Network.framework. Plain "quic" STRINGS
#      are NOT checked on purpose: NIOCore (QUICBinaryEncodingStrategy) and
#      BoringSSL (QUIC_INTERNAL_ERROR, …) carry them, in build 43 too, and
#      neither can open a QUIC connection — only Network.framework's
#      NWProtocolQUIC can, and only meshyy ever imported it.
# Plus, on the app's Info.plist and both PrivacyInfo.xcprivacy files:
#   6. the NS*UsageDescription keys are exactly {NSLocalNetworkUsageDescription,
#      NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription} and
#      ITSAppUsesNonExemptEncryption is false (export-compliance Lane A);
#   7. NSPrivacyCollectedDataTypes is empty and NSPrivacyTracking is false.
#
# UDP that REMAINS in the App Store binary, shipped since 1.0.3 and not meshyy:
#   - Wake-on-LAN: aPlusTerminal/Network/WakeOnLAN.swift sends the magic
#     packet over NWConnection(.udp) to the LAN broadcast address, only when
#     the user taps Wake.
#   - Bonjour/mDNS: aPlusTerminal/Network/BonjourBrowser.swift browses
#     _ssh._tcp. with NWBrowser (multicast DNS on the local network), only on
#     the Add Server discovery screen.
# Neither is QUIC and neither leaves the local network.
set -uo pipefail

app="${1:-}"
if [[ -z "$app" || ! -f "$app/Info.plist" ]]; then
    echo "usage: $0 <path/to/aPlusTerminal.app>" >&2
    exit 2
fi
app="${app%/}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fails=()
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; fails+=("$1"); }

# Exact UI copy, case-sensitive ("Still Running" lower-cased is legitimate
# SSH copy: "Your work is still running on the server").
copy_needles=("Use meshyy" "meshyyd" "Resuming your session" "Still Running" "Resume Session"
              "Scroll trace" "Record scroll trace" "aplus-scroll-trace")
# Distinctive enough to match in any case — also catches prose such as a
# privacy-policy paragraph about "the optional scroll trace".
icase_needles=("scroll trace" "aplus-scroll-trace")
quic_symbols='NWProtocolQUIC|NWParametersC4quic|_nw_quic_|nw_protocol_copy_quic|nw_protocol_options_is_quic'

plist_value() {  # plist_value <plist> <key> — prints the value as JSON, or nothing
    python3 -I -c '
import json, plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
if sys.argv[2] in d:
    print(json.dumps(d[sys.argv[2]]))' "$1" "$2"
}

executable=$(plist_value "$app/Info.plist" CFBundleExecutable | tr -d '"')
widget="$app/PlugIns/aPlusTerminalWidgets.appex"
widget_exec=$( [[ -f "$widget/Info.plist" ]] && plist_value "$widget/Info.plist" CFBundleExecutable | tr -d '"')

echo "check-no-meshyy: $app"

# Both binaries the brief names must exist, or the scan below proves nothing.
[[ -n "$executable" && -f "$app/$executable" ]] && pass "app binary present ($executable)" \
    || fail "app binary missing (CFBundleExecutable=$executable)"
[[ -n "$widget_exec" && -f "$widget/$widget_exec" ]] && pass "widget appex binary present ($widget_exec)" \
    || fail "widget appex binary missing ($widget)"

machos=()
texts=()
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then machos+=("$f"); else texts+=("$f"); fi
done < <(find "$app" -type f ! -path '*/_CodeSignature/*' -print0)

echo "Mach-O files scanned: ${#machos[@]}"
for bin in "${machos[@]}"; do
    rel="${bin#"$app"/}"
    s=$(strings -a "$bin")
    n=$(grep -ci meshyy <<<"$s")
    [[ "$n" -eq 0 ]] && pass "$rel: 0 \"meshyy\" strings" \
        || fail "$rel: $n \"meshyy\" strings, e.g. $(grep -i meshyy <<<"$s" | head -3 | tr '\n' ' ')"
    for needle in "${copy_needles[@]}"; do
        grep -qF -- "$needle" <<<"$s" && fail "$rel: UI copy \"$needle\" present"
    done
    for needle in "${icase_needles[@]}"; do
        grep -qiF -- "$needle" <<<"$s" && fail "$rel: \"$needle\" present (any case)"
    done
    libs=$(xcrun otool -L "$bin" 2>/dev/null | tail -n +2)
    grep -qi meshyy <<<"$libs" && fail "$rel: links $(grep -i meshyy <<<"$libs" | head -1 | awk '{print $1}')"
    q=$(xcrun nm -u "$bin" 2>/dev/null | grep -E "$quic_symbols" || true)
    [[ -z "$q" ]] && pass "$rel: no Network.framework QUIC imports" \
        || fail "$rel: imports QUIC ($(wc -l <<<"$q" | tr -d ' ') symbols, e.g. $(head -1 <<<"$q"))"
done

# Text resources (privacy policy, notices, profiles.json, App Intents metadata…).
text_hits=0
for f in "${texts[@]}"; do
    s=$(strings -a "$f")
    if grep -qi meshyy <<<"$s"; then fail "${f#"$app"/}: mentions meshyy"; text_hits=1; fi
    for needle in "${copy_needles[@]}"; do
        if grep -qF -- "$needle" <<<"$s"; then fail "${f#"$app"/}: UI copy \"$needle\" present"; text_hits=1; fi
    done
    for needle in "${icase_needles[@]}"; do
        if grep -qiF -- "$needle" <<<"$s"; then fail "${f#"$app"/}: \"$needle\" present"; text_hits=1; fi
    done
done
[[ $text_hits -eq 0 ]] && pass "${#texts[@]} non-Mach-O files: no meshyy or needle copy"

bundled=$(find "$app" -iname '*meshyy*' | sed "s|^$app/||")
[[ -z "$bundled" ]] && pass "no Meshyy framework or file in the bundle" \
    || fail "Meshyy in the bundle: $(tr '\n' ' ' <<<"$bundled")"

# Info.plist: usage strings and export compliance unchanged since 1.0.3.
usage=$(python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
print(" ".join(sorted(k for k in d if k.startswith("NS") and k.endswith("UsageDescription"))))' "$app/Info.plist")
expected="NSLocalNetworkUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription"
[[ "$usage" == "$expected" ]] && pass "Info.plist usage strings: $usage" \
    || fail "Info.plist usage strings are [$usage], expected [$expected]"
enc=$(plist_value "$app/Info.plist" ITSAppUsesNonExemptEncryption)
[[ "$enc" == "false" ]] && pass "ITSAppUsesNonExemptEncryption = false" \
    || fail "ITSAppUsesNonExemptEncryption = ${enc:-<missing>}, expected false"

for privacy in "$app/PrivacyInfo.xcprivacy" "$widget/PrivacyInfo.xcprivacy"; do
    rel="${privacy#"$app"/}"
    if [[ ! -f "$privacy" ]]; then fail "$rel missing"; continue; fi
    collected=$(plist_value "$privacy" NSPrivacyCollectedDataTypes)
    tracking=$(plist_value "$privacy" NSPrivacyTracking)
    [[ "$collected" == "[]" ]] && pass "$rel: NSPrivacyCollectedDataTypes empty" \
        || fail "$rel: NSPrivacyCollectedDataTypes = ${collected:-<missing>}"
    [[ "$tracking" == "false" ]] && pass "$rel: NSPrivacyTracking false" \
        || fail "$rel: NSPrivacyTracking = ${tracking:-<missing>}"
done

echo
if [[ ${#fails[@]} -eq 0 ]]; then
    echo "PASS: meshyy is compiled out of $(basename "$app")."
    exit 0
fi
echo "FAIL: ${#fails[@]} check(s) failed for $(basename "$app"):"
printf '  - %s\n' "${fails[@]}"
exit 1
