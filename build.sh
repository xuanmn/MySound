#!/bin/bash

APP_NAME="MySound"
BUNDLE_ID="com.xuanmn.mysound"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

if [ -f "Resources/AppIcon.icns" ]; then
    echo "Copying app icon..."
    cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/"
fi

echo "Compiling Swift files (Universal Binary arm64 + x86_64)..."
swiftc -o "${MACOS_DIR}/${APP_NAME}_arm64" Sources/App.swift Sources/VolumeControlView.swift Sources/AudioTapManager.swift Sources/UpdateManager.swift -target arm64-apple-macos14.2
ARM64_STATUS=$?

swiftc -o "${MACOS_DIR}/${APP_NAME}_x86_64" Sources/App.swift Sources/VolumeControlView.swift Sources/AudioTapManager.swift Sources/UpdateManager.swift -target x86_64-apple-macos14.2
X86_STATUS=$?

if [ $ARM64_STATUS -eq 0 ] && [ $X86_STATUS -eq 0 ]; then
    lipo -create -output "${MACOS_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}_arm64" "${MACOS_DIR}/${APP_NAME}_x86_64"
    rm -f "${MACOS_DIR}/${APP_NAME}_arm64" "${MACOS_DIR}/${APP_NAME}_x86_64"
elif [ $ARM64_STATUS -eq 0 ]; then
    echo "Warning: x86_64 target failed, falling back to arm64 binary."
    mv "${MACOS_DIR}/${APP_NAME}_arm64" "${MACOS_DIR}/${APP_NAME}"
    rm -f "${MACOS_DIR}/${APP_NAME}_x86_64"
elif [ $X86_STATUS -eq 0 ]; then
    echo "Warning: arm64 target failed, falling back to x86_64 binary."
    mv "${MACOS_DIR}/${APP_NAME}_x86_64" "${MACOS_DIR}/${APP_NAME}"
    rm -f "${MACOS_DIR}/${APP_NAME}_arm64"
else
    echo "Compilation failed!"
    exit 1
fi

echo "Creating Info.plist..."

# Fix 13: Read version dynamically from version.json instead of hardcoding "1.0.0"
if [ -f "version.json" ]; then
    APP_VERSION=$(python3 -c "import json,sys; print(json.load(open('version.json'))['version'])" 2>/dev/null || echo "1.0.0")
else
    APP_VERSION="1.0.0"
fi
echo "Building version: ${APP_VERSION}"

cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MySound needs access to audio to mix your application volumes.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>MySound needs access to system audio to capture per-app sounds.</string>
</dict>
</plist>
EOF

echo "Signing app..."
codesign --force --sign - --entitlements Entitlements.plist "${APP_BUNDLE}"

echo "Build complete. App bundle created at ${APP_BUNDLE}"

echo "Packaging app for distribution..."
# Create a ZIP file for easy sharing
pushd "${BUILD_DIR}" > /dev/null
zip -r -q "${APP_NAME}.zip" "${APP_NAME}.app"
popd > /dev/null

# Create a DMG installer file with Applications drag-and-drop link
echo "Creating DMG installer..."
DMG_STAGE="${BUILD_DIR}/dmg_stage"
rm -rf "$DMG_STAGE" "${BUILD_DIR}/${APP_NAME}.dmg"
mkdir -p "$DMG_STAGE"
cp -R "${APP_BUNDLE}" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGE" -ov -format UDZO "${BUILD_DIR}/${APP_NAME}.dmg" > /dev/null
rm -rf "$DMG_STAGE"

echo "============================================================"
echo "✅  DMG Installer created at: ${BUILD_DIR}/${APP_NAME}.dmg"
echo "✅  ZIP Archive created at:   ${BUILD_DIR}/${APP_NAME}.zip"
echo ""
echo "   Users can double-click the .dmg file and drag ${APP_NAME}"
echo "   directly into their Applications folder!"
echo "============================================================"
echo "You can run it locally with: open ${APP_BUNDLE}"
