#!/bin/bash
# Build an installable disk image: dist/The-Agentic-Apple-<version>.dmg
# Holds the app and an /Applications shortcut — open it, drag the app across.
#   scripts/make-dmg.sh               build the app, then the DMG
#   SKIP_BUILD=1 scripts/make-dmg.sh  package an existing dist/ app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="The Agentic Apple"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
DMG="dist/The-Agentic-Apple-$VERSION.dmg"

if [ "${SKIP_BUILD:-}" != "1" ]; then
  VERSION="$VERSION" ./scripts/build-app.sh
fi
[ -d "dist/$APP_NAME.app" ] || { echo "dist/$APP_NAME.app not found" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "dist/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# Volume icon (custom-icon flag needs SetFile from the Command Line Tools).
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$STAGE" || true; fi
fi

echo "→ hdiutil create"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
codesign --force --sign - "$DMG" >/dev/null 2>&1 || true
hdiutil verify -quiet "$DMG"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
