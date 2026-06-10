DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# First available iPhone simulator (works locally and on CI regardless of Xcode version)
# DEVELOPER_DIR is passed inline because $(shell) does not see `export`ed vars on make 3.81
SIM_NAME ?= $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun simctl list devices available | grep -oE 'iPhone [A-Za-z0-9 ]+' | head -1 | sed 's/ *$$//')
DEST := platform=iOS Simulator,name=$(SIM_NAME)

XCBUILD := xcodebuild -project aTerminal.xcodeproj -scheme aTerminal -destination '$(DEST)'

.PHONY: generate build test clean

generate:
	xcodegen generate

build: generate
	$(XCBUILD) build

test: generate
	$(XCBUILD) test

clean:
	rm -rf aTerminal.xcodeproj build DerivedData
