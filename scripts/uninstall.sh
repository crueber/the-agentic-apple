#!/bin/bash
# Remove The Agentic Apple, its CLI link, settings and cached numbers.
set -euo pipefail
APP_NAME="The Agentic Apple"
osascript -e "tell application id \"com.crueber.agentic-apple\" to quit" >/dev/null 2>&1 || true
pkill -x agentic-apple >/dev/null 2>&1 || true
rm -rf "$HOME/Applications/$APP_NAME.app" "/Applications/$APP_NAME.app"
rm -f "$HOME/.local/bin/agentic-apple"
rm -rf "$HOME/Library/Caches/com.crueber.agentic-apple"
defaults delete com.crueber.agentic-apple >/dev/null 2>&1 || true
echo "✓ The Agentic Apple removed"
