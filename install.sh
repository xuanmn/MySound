#!/bin/bash

# MySound 1-Line Installer Script for macOS
set -e

echo "================================================="
echo "🔊  MySound One-Line Installer"
echo "================================================="

APP_NAME="MySound"
INSTALL_DIR="/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"
REPO="xuanmn/MySound"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "⬇️  Downloading latest MySound build..."
DMG_PATH="${TMP_DIR}/MySound.dmg"

# Fetch latest release DMG URL from GitHub Releases, fallback to main branch asset
DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep "browser_download_url.*dmg" | cut -d : -f 2,3 | tr -d \" | xargs 2>/dev/null || true)

if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL="https://raw.githubusercontent.com/${REPO}/main/build/${APP_NAME}.dmg"
fi

curl -cL "$DOWNLOAD_URL" -o "$DMG_PATH" || {
    echo "❌ Download failed. Please download MySound manually from GitHub Releases."
    exit 1
}

echo "📦 Mounting installer package..."
MOUNT_DIR=$(mktemp -d)
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

echo "🚚 Installing to ${INSTALL_DIR}..."
# Stop running instance if currently active
killall "${APP_NAME}" 2>/dev/null || true

rm -rf "$APP_PATH"
cp -R "${MOUNT_DIR}/${APP_NAME}.app" "$INSTALL_DIR/"

hdiutil detach "$MOUNT_DIR" -quiet

echo "🛡️  Clearing Gatekeeper quarantine & refreshing local signature..."
xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null || true
# Preserve entitlements when re-signing — without this, the system-audio-capture
# and audio-input entitlements are stripped, causing process tap failures.
ENTITLEMENTS_TMP="${TMP_DIR}/entitlements.plist"
codesign -d --entitlements - "$APP_PATH" > "$ENTITLEMENTS_TMP" 2>/dev/null || true
if [ -s "$ENTITLEMENTS_TMP" ]; then
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS_TMP" "$APP_PATH" 2>/dev/null || true
else
    codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true
fi

echo "================================================="
echo "✅  MySound installed successfully to /Applications!"
echo "🚀  Launching MySound..."
echo "================================================="

open "$APP_PATH"
