DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# First available iPhone simulator (works locally and on CI regardless of Xcode version)
# DEVELOPER_DIR is passed inline because $(shell) does not see `export`ed vars on make 3.81
SIM_NAME ?= $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun simctl list devices available | grep -oE 'iPhone [A-Za-z0-9 ]+' | head -1 | sed 's/ *$$//')
DEST := platform=iOS Simulator,name=$(SIM_NAME)

XCBUILD := xcodebuild -project aPlusTerminal.xcodeproj -scheme aPlusTerminal -destination '$(DEST)'

.PHONY: generate build test test-meshyy-live test-scroll-oracle clean

generate:
	xcodegen generate

build: generate
	$(XCBUILD) build

test: generate
	$(XCBUILD) test

# Live meshyy tests against a real local meshyyd.
#
# The ORDER matters and is the whole point of this target. meshyy's bootstrap tokens
# have a 60-SECOND TTL, so minting them before a build races the compiler: `make test`
# rebuilds first, and by the time the live tests run the tokens have expired and the
# attach is refused — which reads exactly like a broken transport and is not one.
#
# So: build first, mint second, run third.
test-meshyy-live: generate
	$(XCBUILD) build-for-testing
	./scripts/meshyy-live-fixtures.sh
	$(XCBUILD) test-without-building \
	  -only-testing:aPlusTerminalTests/MeshyyLiveTests \
	  -only-testing:aPlusTerminalTests/MeshyySessionPileUpTests \
	  -only-testing:aPlusTerminalTests/MeshyyResizeAtConnectTests \
	  -only-testing:aPlusTerminalTests/MeshyySurvivorFlowTests

# SSH as the oracle for swipe-to-scroll (aPlusTerminalTests/ScrollOracleLiveTests):
# real swipes through the real ScrollBridge over a real SSH pty AND over the real
# launchd meshyyd, judged by what an isolated tmux actually did. Needs this Mac's
# sshd, tmux, and the host UDP relay for the path-drop step:
#   cd ../meshyy && swift build --product meshyy-chaos && cp .build/debug/meshyy-chaos ~/bin/
# Same order as test-meshyy-live: build, then fixtures, then run. Skips on CI
# (no /tmp/aplus-probe-* fixtures); FAILS on a dev Mac whose setup is broken.
test-scroll-oracle: generate
	@test -x $(HOME)/bin/meshyy-chaos || { echo "~/bin/meshyy-chaos missing (see the comment above this target)" >&2; exit 1; }
	$(XCBUILD) build-for-testing
	./scripts/meshyy-repro-setup.sh
	$(XCBUILD) test-without-building \
	  -only-testing:aPlusTerminalTests/ScrollOracleLiveTests

clean:
	rm -rf aPlusTerminal.xcodeproj build DerivedData
