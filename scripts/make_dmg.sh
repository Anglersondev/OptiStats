#!/bin/bash
# Gera OptiStats.dmg a partir de OptiStats.app (assinatura ad-hoc; sem notarização).
# Uso: scripts/make_dmg.sh caminho/OptiStats.app [saida.dmg]
set -euo pipefail
APP=${1:?caminho do OptiStats.app}; OUT=${2:-OptiStats.dmg}
codesign --force --deep --sign - "$APP"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "OptiStats" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"; echo "Gerado: $OUT"
