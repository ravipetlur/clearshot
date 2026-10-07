PROJECT := ClearShot.xcodeproj
SCHEME := ClearShot
DERIVED := build/DerivedData
# Any Mac rather than this one: ARCHS is arm64 either way, and xcodebuild doesn't have to pick one of several matching
# destinations (it warns when it does).
DESTINATION := generic/platform=macOS
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) -quiet
APP_DEBUG := $(DERIVED)/Build/Products/Debug/ClearShot.app
APP_RELEASE := $(DERIVED)/Build/Products/Release/ClearShot.app

# A release's version, its tag without the v (1.2.0, or 1.2.0-beta.1). The DMG is build/ClearShot-$(VERSION).dmg, and the
# app's CFBundleShortVersionString is the version's leading three numbers (1.2.0), the form macOS expects; a version
# without them keeps project.yml's MARKETING_VERSION. Defaults to project.yml's MARKETING_VERSION, or dev.
VERSION ?= $(or $(shell sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9A-Za-z.+-]+)"?.*/\1/p' project.yml | head -n 1),dev)
# The Release build's CFBundleVersion (the release workflow passes its run number). Empty keeps project.yml's
# CURRENT_PROJECT_VERSION.
BUILD_NUMBER ?=
SHORT_VERSION = $(shell printf '%s\n' '$(VERSION)' | sed -n -E 's/^([0-9]+\.[0-9]+\.[0-9]+)([^0-9.].*)?$$/\1/p')

.PHONY: generate build build-release dmg test run install clean

generate:
	xcodegen generate --quiet

build: generate
	$(XCODEBUILD) -configuration Debug build

build-release: generate
	$(XCODEBUILD) -configuration Release $(if $(SHORT_VERSION),MARKETING_VERSION=$(SHORT_VERSION)) \
		$(if $(BUILD_NUMBER),CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)) build

dmg: build-release
	scripts/make-dmg.sh $(APP_RELEASE) '$(VERSION)' build

test:
	swift test --package-path ClearShotKit

run: build
	-pkill -x ClearShot; while pgrep -x ClearShot >/dev/null; do sleep 0.1; done
	open $(APP_DEBUG)

install: build-release
	-pkill -x ClearShot; while pgrep -x ClearShot >/dev/null; do sleep 0.1; done
	rm -rf /Applications/ClearShot.app
	cp -R $(APP_RELEASE) /Applications/ClearShot.app
	open /Applications/ClearShot.app

clean:
	rm -rf build
