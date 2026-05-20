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

echo "Compiling Swift files..."
swiftc -o "${MACOS_DIR}/${APP_NAME}" Sources/App.swift Sources/VolumeControlView.swift Sources/AudioTapManager.swift Sources/UpdateManager.swift -target arm64-apple-macos14.2

# Check if compile succeeded
if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

echo "Creating Info.plist..."
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
    <string>1.0</string>
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

echo "============================================================"
echo "✅  Standalone package created at: ${BUILD_DIR}/${APP_NAME}.zip"
echo "   You can send this .zip file to other users."
echo "   They just need to unzip it and they can move the app"
echo "   to their Applications folder to use it."
echo "============================================================"
echo "You can run it locally with: open ${APP_BUNDLE}"
