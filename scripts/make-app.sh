#!/usr/bin/env bash
# Assemble ClaudeUsageApp into a real .app bundle.
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
# Output: build/ClaudeUsageApp.app
set -euo pipefail

CONFIG="${1:-release}"
BUNDLE_ID="com.alexcharland.ClaudeUsageMenuBar"
APP_NAME="ClaudeUsageApp"
DISPLAY_NAME="Claude Usage"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">> Building ($CONFIG)..."
swift build -c "$CONFIG" --product "$APP_NAME"

BIN="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
APP_DIR="$ROOT/build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

echo ">> Assembling bundle at ${APP_DIR} ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$APP_DIR/Contents/Resources"
cp "$BIN" "$MACOS_DIR/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>      <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
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
