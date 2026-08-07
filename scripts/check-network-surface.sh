#!/usr/bin/env bash
# a+Terminal — the privacy claim, CI-enforced.
#
# "Zero data collection: only user-initiated SSH traffic and on-device
# dictation" is a claim in the README and the App Store listing. This gate is
# what stops it rotting: any use of a network-capable symbol OUTSIDE the
# audited layers fails the build, so a new analytics call, update ping, or
# telemetry SDK cannot arrive quietly.
#
# Audited layers (each explains its own traffic):
#   aPlusTerminal/SSH/       — the product: user-initiated SSH
#   aPlusTerminal/Meshyy/    — the meshyy transport (QUIC to the user's host)
#   aPlusTerminal/VNC/ + Vendor/royalvnc — the VNC monitor
#   aPlusTerminal/Network/   — Bonjour discovery, reachability, wake-on-LAN:
#                              local-network only, no internet endpoints
#   aPlusTerminal/Preview/   — the localhost preview's loopback listener
set -euo pipefail
cd "$(dirname "$0")/.."

symbols='import Network|URLSession|NWConnection|NWListener|NWBrowser|CFSocket|CFStream|getaddrinfo\('
allowed='^(aPlusTerminal/(SSH|Meshyy|VNC|Network|Preview)/|Vendor/royalvnc/|aPlusTerminalTests/|aPlusTerminalUITests/)'

fail=0
while IFS= read -r file; do
    [[ $file == *.swift ]] || continue
    [[ $file =~ $allowed ]] && continue
    if grep -nE "$symbols" "$file" > /tmp/net-hits.$$ 2>/dev/null; then
        while IFS= read -r hit; do
            echo "FAIL: $file:$hit — network symbol outside the audited layers."
            fail=1
        done < /tmp/net-hits.$$
    fi
done < <(git ls-files)
rm -f /tmp/net-hits.$$

if [[ $fail -eq 0 ]]; then
    echo "OK: no network symbols outside SSH/Meshyy/VNC/Network/Preview."
else
    echo ""
    echo "If the new use is legitimate, it belongs in an audited layer — or this"
    echo "gate's allowlist grows in the SAME pr, where a reviewer sees both."
fi
exit $fail
