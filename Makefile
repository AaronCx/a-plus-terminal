DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# First available iPhone simulator (works locally and on CI regardless of Xcode version)
# DEVELOPER_DIR is passed inline because $(shell) does not see `export`ed vars on make 3.81
SIM_NAME ?= $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun simctl list devices available | grep -oE 'iPhone [A-Za-z0-9 ]+' | head -1 | sed 's/ *$$//')
DEST := platform=iOS Simulator,name=$(SIM_NAME)

XCBUILD := xcodebuild -project aPlusTerminal.xcodeproj -scheme aPlusTerminal -destination '$(DEST)'

.PHONY: generate build test test-meshyy-live clean

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

clean:
	rm -rf aPlusTerminal.xcodeproj build DerivedData
