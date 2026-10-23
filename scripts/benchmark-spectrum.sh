#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination=build/artifacts.noindex/spectrum-benchmark
mkdir -p "$destination"
printf 'module CDSP { header "%s/Sources/CDSP/include/CDSP.h" export * }\n' "$PWD" > "$destination/CDSP.modulemap"
# Compile the production sources together with optimization; omit only the UI's module import.
python3 - "$destination/InputSpectrumView.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Sources/MyEqApp/InputSpectrumView.swift').read_text()
pathlib.Path(sys.argv[1]).write_text(source.replace('import MyEqCore\n', ''))
PY
xcrun clang++ -std=c++17 -O3 -arch arm64 -mmacosx-version-min=27.0 \
  -I Sources/CDSP/include -c Sources/CDSP/DSP.cpp -o "$destination/DSP.o"
xcrun swiftc -parse-as-library -swift-version 5 -O -module-name SpectrumBenchmark \
  -I Sources/CDSP/include -Xcc -fmodule-map-file="$destination/CDSP.modulemap" \
  Sources/MyEqCore/InputSpectrum.swift Sources/MyEqCore/InputSpectrumMonitor.swift \
  "$destination/InputSpectrumView.swift" scripts/spectrum-benchmark.swift "$destination/DSP.o" \
  -framework AppKit -framework CoreAudio -framework Accelerate -lc++ -o "$destination/benchmark"
"$destination/benchmark" "${1:-8}" "${2:-}"
