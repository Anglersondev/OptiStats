#!/bin/bash
# Reproducible Apple Silicon release build using macOS Command Line Tools or Xcode.
# Usage: scripts/build_app.sh [output-directory]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-"$ROOT/build/native"}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
APP="$BUILD/OptiStats.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 - "$ROOT" "$BUILD" <<'PY'
from pathlib import Path
import sys,plistlib,shutil
r,b=map(Path,sys.argv[1:])
for label,directory in [('core','Packages/OptiStatsCore/Sources'),('app','App/OptiStats'),('helper','Helper/OptiStatsHelper')]:
    (b/(label+'-sources')).write_text('\n'.join('"'+str(p)+'"' for p in sorted((r/directory).rglob('*.swift')))+'\n')
resources=b/'OptiStats.app/Contents/Resources'
for p in (r/'App/OptiStats/Resources').iterdir():
    if p.name.endswith('.lproj'):shutil.copytree(p,resources/p.name,dirs_exist_ok=True)
    elif p.is_file():shutil.copy2(p,resources/p.name)
info=plistlib.loads((r/'App/OptiStats/Support/Info.plist').read_bytes())
info.update(CFBundleExecutable='OptiStats',CFBundleIdentifier='dev.optistats.OptiStats',CFBundleName='OptiStats',
            CFBundleShortVersionString='1.0',CFBundleVersion='2',LSMinimumSystemVersion='13.0',CFBundleIconFile='OptiStats')
(b/'OptiStats.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
icons=b/'OptiStats.iconset';icons.mkdir(exist_ok=True)
for p in (r/'App/OptiStats/Resources/Assets.xcassets/AppIcon.appiconset').glob('*.png'):
    shutil.copy2(p,icons/p.name.replace('@1x',''))
PY
FLAGS=(-O -whole-module-optimization -swift-version 5 -target arm64-apple-macos13.0)
swiftc "${FLAGS[@]}" -emit-library -static -emit-module -module-name OptiStatsCore \
  -emit-module-path "$BUILD/OptiStatsCore.swiftmodule" -o "$BUILD/libOptiStatsCore.a" @"$BUILD/core-sources"
swiftc "${FLAGS[@]}" -I "$BUILD" -L "$BUILD" -lOptiStatsCore @"$BUILD/helper-sources" -o "$APP/Contents/Resources/OptiStatsHelper"
swiftc "${FLAGS[@]}" -I "$BUILD" -L "$BUILD" -lOptiStatsCore @"$BUILD/app-sources" -o "$APP/Contents/MacOS/OptiStats"
iconutil -c icns "$BUILD/OptiStats.iconset" -o "$APP/Contents/Resources/OptiStats.icns"
codesign --force --sign - "$APP/Contents/Resources/OptiStatsHelper"
codesign --force --sign - --entitlements "$ROOT/App/OptiStats/Support/OptiStats.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built and verified: $APP (version 1.0, build 2)"
