#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
products=$(swift build --show-bin-path)
destination=build/artifacts.noindex/design-preview
mkdir -p "$destination"
sources=()
for source in Sources/MyEqApp/*.swift; do
  if [ "$(basename "$source")" != MyEqApp.swift ]; then sources+=("$source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -O -g -module-name MyEqDesignPreview \
  -I "$products" -I .build/out/Intermediates.noindex/GeneratedModuleMaps \
  -I Sources/CDSP/include -I Sources/CTransport/include \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/CDSP.modulemap \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/CTransport.modulemap \
  "${sources[@]}" scripts/design-preview.swift scripts/spectrum-proposal.swift \
  "$products/libMyEqCore.a" -framework AppKit -framework SwiftUI -framework ServiceManagement \
  -framework CoreAudio -framework AudioToolbox -lc++ \
  -o "$destination/render"
"$destination/render" "$destination" "$@"
