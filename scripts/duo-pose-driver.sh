#!/bin/bash
# Host-side fold driver for DuoLayoutUITests (duo.yml). XCUITest cannot fold
# a simulator, so the test writes "<pose> <token>" to ~/.aplus-duo/pose-request
# and this loop puts the iPhone Duo simulator in that pose, screenshots both
# of its displays into $SHOTS, and answers with the token in pose-done
# ("error <token> ..." when it could not).
#
# Poses, on the iPhone Duo simulator profile (Xcode 27.1): display 1 is the
# outer ("primary", 466x678 pt) screen and display 3 the inner ("primary-1",
# 669x951 pt) one; `simctl io screenConfig --display=N power on|off` switches
# which one is lit, which is how the simulator folds and unfolds.
#   unfolded: inner on, outer off
#   folded:   outer on, inner off
#
# Usage: scripts/duo-pose-driver.sh <udid> <shots-dir>   (runs until killed)
set -uo pipefail

udid="$1"
shots="$2"
dir="$HOME/.aplus-duo"
mkdir -p "$shots"

t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
power() { t 30 xcrun simctl io "$udid" screenConfig --display="$1" power "$2"; }

shoot() {
  for d in 1 3; do
    t 30 xcrun simctl io "$udid" screenshot --mask=ignored --display="$d" \
      "$shots/$1-display$d.png" >/dev/null 2>&1 || rm -f "$shots/$1-display$d.png"
  done
}

apply() {
  case "$1" in
    unfolded) power 3 on && power 1 off ;;
    folded) power 1 on && power 3 off ;;
    *) echo "unknown pose $1" >&2; return 2 ;;
  esac
}

n=0
last=""
while :; do
  request=$(cat "$dir/pose-request" 2>/dev/null || true)
  if [ -n "$request" ] && [ "$request" != "$last" ]; then
    last="$request"
    set -- $request
    pose="$1"
    n=$((n + 1))
    echo "pose $n: $pose"
    if out=$(apply "$pose" 2>&1); then
      # Let the system move the scene and the app re-lay out.
      sleep 4
      shoot "$(printf %02d "$n")-$pose"
      printf '%s\n' "$request" > "$dir/pose-done.tmp" && mv "$dir/pose-done.tmp" "$dir/pose-done"
    else
      echo "pose $pose failed: $out" >&2
      printf 'error %s %s\n' "$request" "$(echo "$out" | tr '\n' ' ')" > "$dir/pose-done.tmp" && mv "$dir/pose-done.tmp" "$dir/pose-done"
    fi
  fi
  sleep 0.3
done
