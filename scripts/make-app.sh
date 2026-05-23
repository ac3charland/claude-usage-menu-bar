#!/usr/bin/env bash
# Assemble the ClaudeUsageApp product into a real "Claude Usage.app" bundle.
#
# Why a bundle: a clean LSUIElement (no Dock icon) needs the executable inside an
# .app, and launch-at-login points its LaunchAgent at the bundled executable for a
# stable path. Running the bare SwiftPM binary works for development but does neither.
# Launch-at-login uses a ~/Library/LaunchAgents plist (see LoginItem.swift) and needs
# no code signing.
#
# Usage:
#   scripts/make-app.sh [debug|release]   (default: release)
#
# Output: build/Claude Usage.app
set -euo pipefail

CONFIG="${1:-release}"
BUNDLE_ID="com.alexcharland.ClaudeUsageMenuBar"
PRODUCT="ClaudeUsageApp"        # SwiftPM product / build binary (internal identifier)
APP_NAME="Claude Usage"         # user-facing .app bundle and executable name

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">> Building ($CONFIG)..."
swift build -c "$CONFIG" --product "$PRODUCT"

BIN="$(swift build -c "$CONFIG" --product "$PRODUCT" --show-bin-path)/$PRODUCT"
APP_DIR="$ROOT/build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

echo ">> Assembling bundle at ${APP_DIR} ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$APP_DIR/Contents/Resources"
cp "$BIN" "$MACOS_DIR/$APP_NAME"

echo ">> Generating app icon..."
TMP_ICON="$(mktemp -d)"
"$MACOS_DIR/$APP_NAME" --render-icon "$TMP_ICON"
SRC="$TMP_ICON/AppIcon-1024.png"
ICONSET="$TMP_ICON/AppIcon.iconset"
mkdir -p "$ICONSET"
# Required sizes: point size + @2x (double) variant.
for PT in 16 32 128 256 512; do
    sips -z "$PT" "$PT" "$SRC" --out "$ICONSET/icon_${PT}x${PT}.png"          > /dev/null
    DBL=$((PT * 2))
    sips -z "$DBL" "$DBL" "$SRC" --out "$ICONSET/icon_${PT}x${PT}@2x.png"     > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$TMP_ICON"
echo "OK  App icon written"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>      <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <!-- Menu bar agent: no Dock icon, no app menu. -->
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>Personal use.</string>
</dict>
</plist>
PLIST

echo "OK  Built ${APP_DIR}"
echo "  Run:  open \"${APP_DIR}\""
echo "  Launch-at-login works unsigned; codesign + notarize only to clear Gatekeeper."
