#!/bin/bash
# Native Apple Silicon release build using macOS Command Line Tools or Xcode.
# Usage: scripts/build_app.sh [output-directory]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-"$ROOT/build/native"}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
STAGE=$(mktemp -d "$BUILD/.app-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/OptiStats.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
IDENTITY=${OPTISTATS_CODESIGN_IDENTITY:--}
SIGNING=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then SIGNING+=(--options runtime --timestamp); fi
MIN_OS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimum_macos"])' "$ROOT/scripts/release-version.json")
python3 - "$ROOT" "$STAGE" <<'PY'
from pathlib import Path
import json
import plistlib
import shutil
import sys

root, stage = map(Path, sys.argv[1:])
release = json.loads((root / "scripts/release-version.json").read_text())
for label, directory in [
    ("core", "Packages/OptiStatsCore/Sources"),
    ("app", "App/OptiStats"),
    ("helper", "Helper/OptiStatsHelper"),
]:
    files = sorted((root / directory).rglob("*.swift"))
    (stage / (label + "-sources")).write_text("\n".join(json.dumps(str(path), ensure_ascii=False) for path in files) + "\n")

resources = stage / "OptiStats.app/Contents/Resources"
for path in (root / "App/OptiStats/Resources").iterdir():
    if path.name.endswith(".lproj"):
        shutil.copytree(path, resources / path.name)
    elif path.is_file():
        shutil.copy2(path, resources / path.name)
info = plistlib.loads((root / "App/OptiStats/Support/Info.plist").read_bytes())
info.update(CFBundleExecutable="OptiStats", CFBundleIdentifier="dev.optistats.OptiStats", CFBundleName="OptiStats",
            CFBundleShortVersionString=release["version"], CFBundleVersion=release["build"],
            LSMinimumSystemVersion=release["minimum_macos"], CFBundleIconFile="OptiStats")
(stage / "OptiStats.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
icons = stage / "OptiStats.iconset"
icons.mkdir()
for path in (root / "App/OptiStats/Resources/Assets.xcassets/AppIcon.appiconset").glob("*.png"):
    shutil.copy2(path, icons / path.name.replace("@1x", ""))
PY
FLAGS=(-O -whole-module-optimization -swift-version 5 -target "arm64-apple-macos$MIN_OS")
swiftc "${FLAGS[@]}" -emit-library -static -emit-module -module-name OptiStatsCore \
  -emit-module-path "$STAGE/OptiStatsCore.swiftmodule" -o "$STAGE/libOptiStatsCore.a" @"$STAGE/core-sources"
swiftc "${FLAGS[@]}" -I "$STAGE" -L "$STAGE" -lOptiStatsCore @"$STAGE/helper-sources" -o "$APP/Contents/Helpers/OptiStatsHelper"
swiftc "${FLAGS[@]}" -I "$STAGE" -L "$STAGE" -lOptiStatsCore @"$STAGE/app-sources" -o "$APP/Contents/MacOS/OptiStats"
iconutil -c icns "$STAGE/OptiStats.iconset" -o "$APP/Contents/Resources/OptiStats.icns"
codesign "${SIGNING[@]}" "$APP/Contents/Helpers/OptiStatsHelper"
codesign "${SIGNING[@]}" --entitlements "$ROOT/App/OptiStats/Support/OptiStats.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
FINAL="$BUILD/OptiStats.app"
if [[ -e "$FINAL" ]]; then mv "$FINAL" "$STAGE/previous.app"; fi
if ! mv "$APP" "$FINAL"; then
  if [[ -e "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$FINAL"; fi
  exit 1
fi
echo "Built and verified: $FINAL"
