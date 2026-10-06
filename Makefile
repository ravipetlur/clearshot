PROJECT := ClearShot.xcodeproj
SCHEME := ClearShot
DERIVED := build/DerivedData
APP_DEBUG := $(DERIVED)/Build/Products/Debug/ClearShot.app
APP_RELEASE := $(DERIVED)/Build/Products/Release/ClearShot.app

.PHONY: generate build test run install clean

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet build

test:
	swift test --package-path ClearShotKit

run: build
	-pkill -x ClearShot; while pgrep -x ClearShot >/dev/null; do sleep 0.1; done
	open $(APP_DEBUG)

install: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -quiet build
	-pkill -x ClearShot; while pgrep -x ClearShot >/dev/null; do sleep 0.1; done
	rm -rf /Applications/ClearShot.app
	cp -R $(APP_RELEASE) /Applications/ClearShot.app
	open /Applications/ClearShot.app

clean:
	rm -rf build
