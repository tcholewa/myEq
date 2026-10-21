#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/native-tests
common=(-std=c++17 -O2 -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -fblocks -I Sources/CTransport -I Sources/CDSP/include)
if [ "${1:-}" = "asan" ]; then common+=(-fsanitize=address -fno-omit-frame-pointer); fi
xcrun clang++ "${common[@]}" Tests/Native/TransportTests.mm Sources/CDSP/DSP.cpp -framework Foundation -framework CoreAudio -framework AudioToolbox -o build/native-tests/transport
xcrun clang++ "${common[@]}" Tests/Native/DriverTests.mm -framework Foundation -framework CoreAudio -o build/native-tests/driver
xcrun clang++ "${common[@]}" Tests/Native/RecoveryTests.mm -framework Foundation -framework CoreAudio -framework AppKit -framework SystemConfiguration -o build/native-tests/recovery
build/native-tests/driver
build/native-tests/recovery
build/native-tests/transport
