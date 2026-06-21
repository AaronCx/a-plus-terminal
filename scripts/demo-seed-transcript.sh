#!/usr/bin/env bash
# demo-seed-transcript.sh — prints ~200 lines of realistic-looking CLI dev/agent
# session output so the App Store review demo's tmux session has tall, scrollable
# scrollback. Cosmetic only: the point is that the reviewer has something to
# two-finger pan through to see a+Terminal's gesture→tmux-scroll feature.
#
# Pure stdout, no side effects. Safe to run repeatedly.

set -u

ts() { printf '%02d:%02d:%02d' $(( (SECONDS/3600)%24 )) $(( (SECONDS/60)%60 )) $(( SECONDS%60 )); }
say()  { printf '%s\n' "$*"; }

say "Connected. Starting agent session in tmux (session: demo)."
say "Working dir: ~/project   branch: main   $(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null || true)"
say "--------------------------------------------------------------------------"
say "> review the failing test suite and fix the regression"
say ""

files=(api/server.go store/cache.go store/cache_test.go cmd/root.go \
       internal/auth/token.go internal/auth/token_test.go ui/render.go \
       ui/render_test.go pkg/log/log.go Makefile README.md)

# Phase 1 — scanning the tree
say "[plan] scanning repository…"
for f in "${files[@]}"; do
  say "  read   $f   ($(( (RANDOM % 400) + 20 )) lines)"
done
say ""

# Phase 2 — a build
say "\$ make build"
say "go build ./...  →  ok (1.84s)"
say "swiftc compile aPlusTerminal  →  ok"
say ""

# Phase 3 — a test run with one failure (looks real)
say "\$ make test"
total=0; pass=0
for f in store/cache auth/token ui/render pkg/log api/server cmd/root; do
  for n in 1 2 3 4; do
    total=$((total+1))
    if [ "$f/$n" = "store/cache/3" ]; then
      say "FAIL  $f  ›  case $n  (expected 200, got 404)   [$(ts)]"
    else
      pass=$((pass+1))
      say "ok    $f  ›  case $n   ($(( (RANDOM % 90) + 3 ))ms)"
    fi
  done
done
say "----"
say "Tests: $pass passed, $((total-pass)) failed, $total total."
say ""

# Phase 4 — a diff (the part with the most lines to scroll)
say "[edit] store/cache.go — fix stale TTL on the reattach path"
say "diff --git a/store/cache.go b/store/cache.go"
say "index 7e3a1c4..b92d017 100644"
say "--- a/store/cache.go"
say "+++ b/store/cache.go"
say "@@ -41,12 +41,18 @@ func (c *Cache) Get(key string) (Entry, bool) {"
for i in $(seq 1 135); do
  case $(( i % 6 )) in
    0) say "+        if e.expiresAt.Before(now) {            // line $i" ;;
    1) say "-        return e, true                          // line $i" ;;
    2) say "+            c.evict(key)                          // line $i" ;;
    3) say "         e, ok := c.entries[key]                  // line $i" ;;
    4) say "+            return Entry{}, false                 // line $i" ;;
    *) say "         }                                         // line $i" ;;
  esac
done
say ""

# Phase 5 — re-run, green
say "\$ make test"
say "Tests: $total passed, 0 failed, $total total.   [$(ts)]"
say "All green. Committing."
say "\$ git commit -am 'fix: evict stale cache entries on reattach'"
say "[main 4bf6a25] fix: evict stale cache entries on reattach"
say ""
say "=========================================================================="
say "  Welcome to the a+Terminal App Store review demo."
say "  Two-finger pan up/down on the terminal to scroll this transcript."
say "  (That scrolling is the app's headline feature.)"
say "=========================================================================="
