#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ruby Scripts/check_localization.rb
swift test --package-path Packages/NetDockCore
xcodebuild -project NetDock.xcodeproj -scheme NetDockMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
test "$(lipo -archs build/Build/Products/Debug/NetDockMac.app/Contents/MacOS/NetDockMac)" = arm64
xcodebuild -project NetDock.xcodeproj -scheme NetDockMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build-release build
test "$(lipo -archs build-release/Build/Products/Release/NetDockMac.app/Contents/MacOS/NetDockMac)" = arm64
xcodebuild -project NetDock.xcodeproj -scheme NetDockMobile \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-mobile \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
