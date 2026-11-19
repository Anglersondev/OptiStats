#!/bin/bash
# Publishes the versioned static site using the repository's existing GitHub Pages branch.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(python3 -c 'import json; print(json.load(open("scripts/release-version.json"))["version"])')
TAG="v$VERSION"
ASSET="OptiStats-$VERSION.dmg"
python3 scripts/check_site.py
if [[ ${1:-} == "--check" ]]; then exit 0; fi
if [[ $# != 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi
# Keep the Pages download aligned with the repository's latest stable release.
if [[ "$(gh release view --json tagName --jq .tagName)" != "$TAG" ]]; then
  echo "Publish $TAG as the latest release before deploying the site." >&2
  exit 1
fi
gh release view "$TAG" --json isDraft,isPrerelease,assets | python3 -c '
import json, sys
release = json.load(sys.stdin)
uploaded = {asset["name"] for asset in release["assets"]}
asset = sys.argv[1]
if release["isDraft"] or release["isPrerelease"] or {asset, asset + ".sha256"} - uploaded:
    sys.exit("Publish the stable release with its DMG and checksum before deploying the site.")
' "$ASSET"
git fetch origin gh-pages
STAGE=$(mktemp -d)
cleanup() {
  git worktree remove --force "$STAGE/site" 2>/dev/null || true
  rmdir "$STAGE"
}
trap cleanup EXIT
git worktree add --detach "$STAGE/site" FETCH_HEAD
rsync -a --delete --exclude=/.git --exclude=/.nojekyll "$ROOT/site/" "$STAGE/site/"
touch "$STAGE/site/.nojekyll"
git -C "$STAGE/site" add -A
if git -C "$STAGE/site" diff --cached --quiet; then
  echo "The site is already up to date."
  exit 0
fi
git -C "$STAGE/site" commit -m "Publish OptiStats $VERSION website"
git -C "$STAGE/site" push origin HEAD:refs/heads/gh-pages
