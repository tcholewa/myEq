#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/native-tests
common=(-std=c++17 -O2 -arch arm64 -mmacosx-version-min=27.0 -fobjc-arc -fblocks -I Sources/CTransport -I Sources/CDSP/include)
if [ "${1:-}" = "installed-playback" ]; then
  xcrun clang++ "${common[@]}" Tests/Native/PlaybackProbe.mm -framework AudioToolbox -framework CoreAudio -o build/native-tests/playback-probe
  build/native-tests/playback-probe
  exit
fi
if [ "${1:-}" = "installed-ipc" ]; then
  xcrun clang++ "${common[@]}" Tests/Native/IPCProbe.mm -framework Foundation -o build/native-tests/ipc-probe
  codesign --force --sign - --identifier com.tc.myEq.unauthorized-test build/native-tests/ipc-probe
  build/native-tests/ipc-probe
  exit
fi
if [ "${1:-}" = "asan" ]; then common+=(-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all); fi
xcrun clang++ "${common[@]}" Tests/Native/TransportTests.mm Sources/CDSP/DSP.cpp -framework Foundation -framework CoreAudio -framework AudioToolbox -o build/native-tests/transport
xcrun clang++ "${common[@]}" Tests/Native/DriverTests.mm -framework Foundation -framework CoreAudio -o build/native-tests/driver
xcrun clang++ "${common[@]}" Tests/Native/RecoveryTests.mm -framework Foundation -framework CoreAudio -framework AppKit -framework SystemConfiguration -o build/native-tests/recovery
xcrun clang++ "${common[@]}" Tests/Native/BridgeLifecycleTests.mm -framework Foundation -framework SystemConfiguration -o build/native-tests/bridge-lifecycle
xcrun clang++ "${common[@]}" Tests/Native/SecurityTests.mm -framework Foundation -framework SystemConfiguration -framework Security -o build/native-tests/security
xcrun clang++ "${common[@]}" Tests/Native/HeartbeatTests.mm Sources/CDSP/DSP.cpp -framework Foundation -framework CoreAudio -framework AudioToolbox -o build/native-tests/heartbeat
build/native-tests/heartbeat
build/native-tests/security
build/native-tests/bridge-lifecycle
build/native-tests/driver
build/native-tests/recovery
build/native-tests/transport
