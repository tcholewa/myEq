#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
xcodebuild -project myEq.xcodeproj -scheme myEq -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build > build/xcodebuild.log 2>&1 || {
    tail -100 build/xcodebuild.log
    exit 1
}
package_dir=$(mktemp -d build/package.XXXXXX)
ditto build/Build/Products/Release/myEq.app "$package_dir/myEq.app"
mkdir -p "$package_dir/myEq.app/Contents/Resources"
swift scripts/icon.swift build/AppIcon.iconset
cp build/AppIcon.icns "$package_dir/myEq.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime "$package_dir/myEq.app"
codesign --verify --strict --verbose=2 "$package_dir/myEq.app"
# Preserve the old executable inode if an earlier build is still running.
if [ -e dist/myEq.app ]; then
    mv dist/myEq.app "$package_dir/previous-myEq.app"
fi
if ! mv "$package_dir/myEq.app" dist/myEq.app; then
    if [ -e "$package_dir/previous-myEq.app" ]; then
        mv "$package_dir/previous-myEq.app" dist/myEq.app
    fi
    exit 1
fi
printf 'Built: %s/dist/myEq.app\n' "$PWD"
