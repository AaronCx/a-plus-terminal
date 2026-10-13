#!/bin/bash
# Host-side capture helper for DuoLayoutUITests (duo.yml). The test writes
# "<label> <token>" to ~/.aplus-duo/pose-request; this loop screenshots both
# displays of the iPhone Duo simulator into $SHOTS as <n>-<label>-display<d>.png,
# writes their pixel sizes to ~/.aplus-duo/display.txt ("<id> <w> <h>" per
# line), and answers with the token in pose-done.
#
# On the iPhone Duo simulator profile (Xcode 27.1) display 1 is the outer
# ("primary", 1398x2034 px) panel and display 3 the inner ("primary-1",
# 2007x2853 px) one. This helper deliberately does NOT fold the device:
# `simctl io screenConfig --display=N power off`, the only scriptable fold
# control, wedged the CI runner each time it was used.
#
# Usage: scripts/duo-capture.sh <udid> <shots-dir>   (runs until killed)
set -uo pipefail

udid="$1"
shots="$2"
dir="$HOME/.aplus-duo"
mkdir -p "$shots"

t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
log() { echo "$(date +%H:%M:%S) $*"; }

capture() {
  local name="$1" sizes="" d file start w h
  for d in 1 3; do
    file="$shots/$name-display$d.png"
    start=$SECONDS
    if t 30 xcrun simctl io "$udid" screenshot --mask=ignored --display="$d" "$file" >/dev/null 2>&1; then
      w=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')
      h=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')
      sizes+="$d $w $h"$'\n'
      log "shot $file ${w}x${h} in $((SECONDS - start))s"
    else
      rm -f "$file"
      log "shot display $d failed after $((SECONDS - start))s"
    fi
  done
  printf '%s' "$sizes" > "$dir/display.txt"
}

n=0
last=""
while :; do
  request=$(cat "$dir/pose-request" 2>/dev/null || true)
  if [ -n "$request" ] && [ "$request" != "$last" ]; then
    last="$request"
    set -- $request
    n=$((n + 1))
    log "capture $n: $1"
    # Let the app finish re-laying out after whatever the test just did.
    sleep 2
    capture "$1"
    printf '%s\n' "$request" > "$dir/pose-done.tmp" && mv "$dir/pose-done.tmp" "$dir/pose-done"
  fi
  sleep 0.3
done
