#!/bin/bash
# Remove The Agentic Apple, its login item, CLI link, settings and cached numbers.
set -euo pipefail
APP_NAME="The Agentic Apple"
osascript -e "tell application id \"com.crueber.agentic-apple\" to quit" >/dev/null 2>&1 || true
pkill -x agentic-apple >/dev/null 2>&1 || true
# Unregister the launch-at-login item while the bundle still exists (SMAppService
# can only remove it on behalf of the app that registered it).
for dir in "$HOME/Applications" "/Applications"; do
  exe="$dir/$APP_NAME.app/Contents/MacOS/agentic-apple"
  if [ -x "$exe" ]; then
    "$exe" --unregister-login-item >/dev/null 2>&1 || echo "! could not remove the login item for $dir/$APP_NAME.app (System Settings › General › Login Items)"
  fi
done
rm -rf "$HOME/Applications/$APP_NAME.app" "/Applications/$APP_NAME.app"
rm -f "$HOME/.local/bin/agentic-apple"
rm -rf "$HOME/Library/Caches/com.crueber.agentic-apple"
defaults delete com.crueber.agentic-apple >/dev/null 2>&1 || true
echo "✓ The Agentic Apple removed"
