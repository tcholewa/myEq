#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/native/myEq.driver/Contents/MacOS build/native/myEq.driver/Contents/Resources
common=(-std=c++17 -O2 -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -I Sources/CTransport -I Sources/CDSP/include)
xcrun clang++ "${common[@]}" Helpers/Bridge.mm -framework Foundation -framework SystemConfiguration -o build/native/myEqBridge
xcrun clang++ "${common[@]}" Helpers/Recovery.mm -framework Foundation -framework AppKit -framework CoreAudio -framework SystemConfiguration -o build/native/myEqRecovery
codesign --force --sign - --identifier com.tc.myEq.bridge --options runtime build/native/myEqBridge
codesign --force --sign - --identifier com.tc.myEq.recovery --options runtime build/native/myEqRecovery
xcrun clang++ "${common[@]}" -bundle Driver/Driver.mm -framework Foundation -framework CoreAudio -o build/native/myEq.driver/Contents/MacOS/myEqDriver
cp Driver/Info.plist build/native/myEq.driver/Contents/Info.plist
python3 scripts/package-trust.py driver
codesign --force --sign - build/native/myEq.driver
codesign --verify --strict build/native/myEq.driver
