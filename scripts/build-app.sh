#!/bin/bash
# Build "The Agentic Apple.app" with SwiftPM (no Xcode needed).
#   scripts/build-app.sh            → dist/The Agentic Apple.app
#   VERSION=1.2.0 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="The Agentic Apple"
BUNDLE_ID="com.crueber.agentic-apple"
EXECUTABLE="agentic-apple"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.1.0)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SCRATCH="${SCRATCH_PATH:-.build}"

echo "→ swift build (release)"
swift build -c release --product "$EXECUTABLE" --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product "$EXECUTABLE" --scratch-path "$SCRATCH" --show-bin-path)/$EXECUTABLE"

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc codesign"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP"
echo "✓ $APP ($VERSION, build $BUILD)"
