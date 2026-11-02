#!/bin/bash
# Runs on macOS with Command Line Tools or Xcode. Does NOT write to physical fans.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-"$ROOT/build/regression"}
mkdir -p "$BUILD"
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys
r,b=map(Path,sys.argv[1:])
files=sorted((r/'Packages/OptiStatsCore/Sources').rglob('*.swift'))
(b/'core-sources').write_text('\n'.join('"'+str(p)+'"' for p in files)+'\n')
PY
swiftc -O -swift-version 5 -emit-library -static -emit-module -module-name OptiStatsCore \
  -emit-module-path "$BUILD/OptiStatsCore.swiftmodule" -o "$BUILD/libOptiStatsCore.a" @"$BUILD/core-sources"
swiftc -O -swift-version 5 -I "$BUILD" -L "$BUILD" -lOptiStatsCore \
  "$ROOT/Helper/OptiStatsHelper/SMCFanIO.swift" \
  "$ROOT/Helper/OptiStatsHelper/SMCConnection.swift" \
  "$ROOT/Helper/OptiStatsHelper/SMCFanDriver.swift" \
  "$ROOT/App/OptiStats/Fans/FanControlSettings.swift" \
  "$ROOT/Tests/HardwareRegression/main.swift" -o "$BUILD/hardware-regressions"
"$BUILD/hardware-regressions"
