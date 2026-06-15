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
#   scripts/make-app.sh [debug|release] [--no-install]   (default: release, install)
#
# Output: build/Claude Usage.app, then deployed to /Applications/Claude Usage.app
# (the launch location) unless --no-install is passed for a pure dev build.
set -euo pipefail

CONFIG="release"
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --no-install)  INSTALL=0 ;;
        *) echo "Unknown argument: $arg (expected debug|release|--no-install)" >&2; exit 2 ;;
    esac
done
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

# Signing identity, in order of preference:
#
#   1. Apple Developer ID Application (Oddobot team). A real Apple-issued cert carries a
#      Team Identifier and chains to Apple's trusted root, so macOS can *verify* the app.
#      That downgrades the cross-app Keychain prompt from "type your login password" to a
#      one-click "Always Allow" (no password). We match the Oddobot team ID specifically so
#      an unrelated Developer ID in the keychain (e.g. another org) is never picked.
#   2. The stable self-signed cert. Gives ONE constant code identity across rebuilds (so a
#      grant isn't invalidated every build) but, lacking a Team Identifier, still forces the
#      heavier password prompt. See scripts/make-signing-cert.sh.
#   3. Ad-hoc (last resort) — identity changes every build, so the prompt always returns.
#
# NOTE: even with the Developer ID, the prompt still *recurs* (~daily): the `claude` CLI
# recreates its Keychain item on each token refresh, wiping the ACL grant. Developer ID
# makes each re-grant a single password-free click, it does not eliminate the prompt.
#
# Override the auto-pick with CODESIGN_IDENTITY="..." (any value `codesign --sign` accepts).
DEVID_TEAM="8WTQW8TNRJ"          # Oddobot Solutions, LLC
SELFSIGN_CN="Claude Usage Self-Signed"
DEVID_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | grep "$DEVID_TEAM" | head -1 | awk '{print $2}')"

sign_with() {  # $1 = identity (hash or name), $2 = human description
    echo ">> Signing bundle with $2 ..."
    codesign --force --deep --sign "$1" --identifier "$BUNDLE_ID" "$APP_DIR"
    codesign -v --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/   /'
}

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    sign_with "$CODESIGN_IDENTITY" "override identity \"$CODESIGN_IDENTITY\""
    echo "OK  Signed with CODESIGN_IDENTITY override"
elif [ -n "$DEVID_HASH" ]; then
    sign_with "$DEVID_HASH" "Developer ID Application (Oddobot, $DEVID_TEAM)"
    echo "OK  Signed with Developer ID — the Keychain prompt should now be a one-click"
    echo "    \"Always Allow\" with no password (though it can still recur on CLI refresh)."
elif security find-certificate -c "$SELFSIGN_CN" >/dev/null 2>&1; then
    sign_with "$SELFSIGN_CN" "stable self-signed identity \"$SELFSIGN_CN\""
    echo "OK  Signed with stable self-signed identity (password prompt; no Developer ID found)"
else
    echo ">> No signing identity found — ad-hoc signing instead." >&2
    echo "   Install the Oddobot Developer ID, or run scripts/make-signing-cert.sh." >&2
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "OK  Built ${APP_DIR}"

if [ "$INSTALL" -eq 1 ]; then
    APP_INSTALL="/Applications/$APP_NAME.app"
    echo ">> Installing to ${APP_INSTALL} ..."
    # Quit a running copy first so we don't overwrite a live bundle mid-run. The
    # login-item LaunchAgent points at this same path, so it self-heals on next launch.
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
    rm -rf "$APP_INSTALL"
    ditto "$APP_DIR" "$APP_INSTALL"   # ditto preserves the code signature
    echo "OK  Installed ${APP_INSTALL}"
    echo "  Run:  open \"${APP_INSTALL}\""
else
    echo "  Run:  open \"${APP_DIR}\"   (build only; --no-install)"
fi
echo "  Launch-at-login works unsigned; notarize only to clear Gatekeeper on other Macs."
