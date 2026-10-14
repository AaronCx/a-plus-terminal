#!/bin/bash
# Host-side fold driver for DuoLayoutUITests (duo.yml). XCUITest cannot fold
# a simulator, so the test writes "<pose> <token>" to ~/.aplus-duo/pose-request
# and this loop puts the iPhone Duo simulator in that pose and answers with
# the token in ~/.aplus-duo/pose-done ("error <token> ..." when it could not).
#
# On the iPhone Duo simulator profile (Xcode 27.1) display 1 is the outer
# ("primary", 1398x2034 px) panel and display 3 the inner ("primary-1",
# 2007x2853 px) one. The simulator boots folded (the app on the outer
# panel); `simctl io screenConfig --display=N power on|off` switches which
# panel is lit, which is how it folds and unfolds:
#   unfolded: inner on, outer off
#   folded:   outer on, inner off
# Only screen power — no simctl screenshots: XCTest takes those in-app.
#
# Usage: scripts/duo-pose-driver.sh <udid>   (runs until killed)
set -uo pipefail

udid="$1"
dir="$HOME/.aplus-duo"

t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
log() { echo "$(date +%H:%M:%S) $*" >&2; }

power() {
  local start=$SECONDS rc=0
  t 45 xcrun simctl io "$udid" screenConfig --display="$1" power "$2" || rc=$?
  log "power display $1 $2: rc=$rc in $((SECONDS - start))s"
  return $rc
}

apply() {
  case "$1" in
    unfolded) power 3 on && power 1 off ;;
    folded) power 1 on && power 3 off ;;
    *) log "unknown pose $1"; return 2 ;;
  esac
}

answer() {
  printf '%s\n' "$1" > "$dir/pose-done.tmp" && mv "$dir/pose-done.tmp" "$dir/pose-done"
}

last=""
while :; do
  request=$(cat "$dir/pose-request" 2>/dev/null || true)
  if [ -n "$request" ] && [ "$request" != "$last" ]; then
    last="$request"
    set -- $request
    log "pose $1 requested"
    if apply "$1"; then
      # Let the system move the scene and the app re-lay out.
      sleep 4
      answer "$request"
      log "pose $1 done"
    else
      answer "error $request"
    fi
  fi
  sleep 0.3
done
