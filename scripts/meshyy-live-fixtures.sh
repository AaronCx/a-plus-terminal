#!/usr/bin/env bash
# Mints the single-use bootstrap tokens MeshyyLiveTests needs.
#
# Tokens are single-use and short-TTL, so this must run immediately before the test
# run — a stale fixture is a refused attach, which reads like a broken transport and
# is not one. One fixture per attach; one session name per test, so a test shutting
# its own session down cannot strand another.
set -euo pipefail
MESHYYD="${MESHYYD:-$HOME/bin/meshyyd}"

if ! "$MESHYYD" version >/dev/null 2>&1; then
    echo "meshyyd not found at $MESHYYD — build it from the meshyy repo:" >&2
    echo "  swift build -c release --product meshyyd && cp .build/release/meshyyd ~/bin/" >&2
    exit 1
fi
if ! pgrep -f "meshyyd serve" >/dev/null; then
    echo "starting meshyyd serve…" >&2
    "$MESHYYD" serve > /tmp/meshyyd.log 2>&1 &
    sleep 2
fi

mint() { "$MESHYYD" attach --session "$2" --json > "/tmp/meshyy-live-$1.json"; chmod 644 "/tmp/meshyy-live-$1.json"; }
mint drive     meshyy-live-drive
mint replay-a  meshyy-live-replay
mint replay-b  meshyy-live-replay
echo "fixtures written: /tmp/meshyy-live-{drive,replay-a,replay-b}.json"
