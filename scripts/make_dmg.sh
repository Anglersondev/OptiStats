#!/bin/bash
# Package a signed app without replacing its signatures.
# Usage: scripts/make_dmg.sh caminho/OptiStats.app [saida.dmg]
set -euo pipefail
APP=${1:?caminho do OptiStats.app}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT=${2:-"OptiStats-$VERSION.dmg"}
IDENTITY=${OPTISTATS_CODESIGN_IDENTITY:--}
NOTARY_PROFILE=${OPTISTATS_NOTARY_PROFILE:-}
if [[ -n "$NOTARY_PROFILE" && "$IDENTITY" == "-" ]]; then
  echo "Notarization requires OPTISTATS_CODESIGN_IDENTITY with a Developer ID certificate." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
if [[ -n "$NOTARY_PROFILE" ]] && ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
  echo "The app must already be signed with Developer ID." >&2
  exit 1
fi
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/volume"
ditto "$APP" "$STAGE/volume/OptiStats.app"
ln -s /Applications "$STAGE/volume/Applications"
DMG="$STAGE/OptiStats.dmg"
hdiutil create -volname "OptiStats $VERSION" -srcfolder "$STAGE/volume" -format UDZO "$DMG"
if [[ "$IDENTITY" != "-" ]]; then codesign --sign "$IDENTITY" --timestamp "$DMG"; fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
# DiskImages can briefly hold a new image busy after create/sign/staple on a runner.
# Fail the package if the final attempt still cannot verify it.
attempt=1
until hdiutil verify "$DMG"; do
  if [[ "$attempt" -ge 4 ]]; then exit 1; fi
  sleep "$attempt"
  attempt=$((attempt + 1))
done
mv -f "$DMG" "$OUT"
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Generated: $OUT"
