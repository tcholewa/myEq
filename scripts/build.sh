#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
xcodebuild -project myEq.xcodeproj -scheme myEq -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build > build/xcodebuild.log 2>&1 || {
    tail -100 build/xcodebuild.log
    exit 1
}
ditto build/Build/Products/Release/myEq.app dist/myEq.app
mkdir -p dist/myEq.app/Contents/Resources
swift scripts/icon.swift build/AppIcon.iconset
cp build/AppIcon.icns dist/myEq.app/Contents/Resources/AppIcon.icns
codesign --force --sign - --options runtime dist/myEq.app
codesign --verify --strict --verbose=2 dist/myEq.app
printf 'Built: %s/dist/myEq.app\n' "$PWD"
