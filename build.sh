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

echo "Compiling Swift files..."
swiftc -o "${MACOS_DIR}/${APP_NAME}" Sources/App.swift Sources/VolumeControlView.swift -target arm64-apple-macos13.0

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
    <string>13.0</string>
</dict>
</plist>
EOF

echo "Build complete. App bundle created at ${APP_BUNDLE}"
echo "You can run it with: open ${APP_BUNDLE}"
