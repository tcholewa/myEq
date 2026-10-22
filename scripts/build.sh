#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
mkdir -p build dist
artifacts=build/artifacts.noindex
mkdir -p "$artifacts"
app="$artifacts/myEq.app"
# Do not replace an executable or resources used by a development preview.
if /usr/sbin/lsof -t "$app/Contents/MacOS/myEq" "$artifacts/xcode/Build/Products/Release/myEq.app/Contents/MacOS/myEq" >/dev/null 2>&1; then
    echo 'Quit the development preview before rebuilding. The installed app may stay open.' >&2
    exit 1
fi
bash scripts/build-native.sh
xcodebuild -project myEq.xcodeproj -scheme myEq -configuration Release -derivedDataPath "$artifacts/xcode" CODE_SIGNING_ALLOWED=NO build > build/xcodebuild.log 2>&1 || {
    tail -100 build/xcodebuild.log
    exit 1
}
package_dir=$(mktemp -d "$artifacts/package.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT
ditto "$artifacts/xcode/Build/Products/Release/myEq.app" "$package_dir/myEq.app"
mkdir -p "$package_dir/myEq.app/Contents/Resources"
cp LICENSE THIRD_PARTY_NOTICES.md "$package_dir/myEq.app/Contents/Resources/"
mkdir -p "$package_dir/myEq.app/Contents/Helpers" "$package_dir/myEq.app/Contents/Library/LaunchAgents"
cp build/native/myEqRecovery "$package_dir/myEq.app/Contents/Helpers/"
python3 scripts/package-trust.py agent "$package_dir/myEq.app/Contents/Library/LaunchAgents/com.tc.myEq.recovery.plist" "$package_dir/myEq.app/Contents/Helpers/myEqRecovery"
swift scripts/icon.swift build/AppIcon.iconset
cp build/AppIcon.icns "$package_dir/myEq.app/Contents/Resources/AppIcon.icns"
sign_code "$package_dir/myEq.app" com.tc.myEq
codesign --verify --strict --verbose=2 "$package_dir/myEq.app"
# Publish only the complete, verified bundle; retain the previous output until the move succeeds.
if [ -e "$app" ]; then
    mv "$app" "$package_dir/previous-myEq.app"
fi
if ! mv "$package_dir/myEq.app" "$app"; then
    if [ -e "$package_dir/previous-myEq.app" ]; then
        mv "$package_dir/previous-myEq.app" "$app"
    fi
    exit 1
fi
printf 'Built: %s/%s\n' "$PWD" "$app"
