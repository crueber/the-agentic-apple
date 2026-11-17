#!/bin/bash
# Build and install The Agentic Apple into ~/Applications, then launch it.
#   scripts/install.sh            build, install, launch
#   scripts/install.sh --no-open  build and install only
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="The Agentic Apple"
DEST="${INSTALL_DIR:-$HOME/Applications}"

./scripts/build-app.sh
mkdir -p "$DEST"
# Quit a running copy so the new build takes over.
osascript -e "tell application id \"com.crueber.agentic-apple\" to quit" >/dev/null 2>&1 || true
pkill -x agentic-apple >/dev/null 2>&1 || true
rm -rf "$DEST/$APP_NAME.app"
cp -R "dist/$APP_NAME.app" "$DEST/"
echo "✓ installed $DEST/$APP_NAME.app"

# Optional command-line helper: agentic-apple --text | --json
mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/$APP_NAME.app/Contents/MacOS/agentic-apple" "$HOME/.local/bin/agentic-apple"
echo "✓ linked ~/.local/bin/agentic-apple"

if [ "${1:-}" != "--no-open" ]; then
  open "$DEST/$APP_NAME.app"
fi
