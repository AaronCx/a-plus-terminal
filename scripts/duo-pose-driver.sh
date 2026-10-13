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

exec 3>&1
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
log() { echo "$(date +%H:%M:%S) $*" >&3; }
power() {
  local start=$SECONDS rc=0
  t 30 xcrun simctl io "$udid" screenConfig --display="$1" power "$2" || rc=$?
  log "power display $1 $2: rc=$rc in $((SECONDS - start))s"
  return $rc
}

# Screenshots the lit display only (a dark one has nothing to show and has
# been seen to stall), then records its pixel size for the test.
shoot() {
  local d=$2 file="$shots/$1-display$2.png" start=$SECONDS
  if t 30 xcrun simctl io "$udid" screenshot --mask=ignored --display="$d" "$file" >/dev/null 2>&1; then
    local w h
    w=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')
    printf '%s %s %s\n' "$d" "$w" "$h" > "$dir/display.txt"
    log "shot $file ${w}x${h} in $((SECONDS - start))s"
  else
    rm -f "$file" "$dir/display.txt"
    log "shot display $d failed after $((SECONDS - start))s"
    return 1
  fi
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
    log "pose $n: $pose requested"
    if out=$(apply "$pose" 2>&1); then
      # Let the system move the scene and the app re-lay out.
      sleep 4
      lit=3; [ "$pose" = folded ] && lit=1
      shoot "$(printf %02d "$n")-$pose" "$lit" || true
      printf '%s\n' "$request" > "$dir/pose-done.tmp" && mv "$dir/pose-done.tmp" "$dir/pose-done"
      log "pose $n: $pose done"
    else
      log "pose $pose failed: $out"
      printf 'error %s %s\n' "$request" "$(echo "$out" | tr '\n' ' ')" > "$dir/pose-done.tmp" && mv "$dir/pose-done.tmp" "$dir/pose-done"
    fi
  fi
  sleep 0.3
done
