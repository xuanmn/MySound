---
name: build-and-release
description: Build universal macOS binaries, sign with entitlements, package DMG & ZIP artifacts, and bump versions for MySound.
---

# Build and Release Skill

This skill guides the automated compilation, code-signing, packaging, and version bumping workflow for the MySound macOS application.

## Workflow

### 1. Update Version Information
If cutting a new release, bump the version string and release notes in [version.json](file:///Users/xuanmn/Developer/MySound/version.json):
```json
{
  "version": "1.3.1",
  "downloadUrl": "https://github.com/xuanmn/MySound/releases/latest/download/MySound.zip",
  "releaseNotes": "Summary of changes..."
}
```

### 2. Compile Universal Binary and Package
Run the build script to compile `arm64` and `x86_64` targets, bundle the app, sign with entitlements, and produce DMG and ZIP installers:
```bash
./build.sh
```

For production builds with Developer ID & Notarization:
```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)" NOTARIZE_PROFILE="YourProfile" ./build.sh
```

### 3. Verify Artifacts & Entitlements
Ensure all output artifacts exist and entitlements are properly embedded:
```bash
# Check generated outputs
ls -lh build/MySound.app build/MySound.dmg build/MySound.zip

# Verify security entitlements (audio capture, audio input, sandbox false)
codesign -d --entitlements :- build/MySound.app

# Verify Universal Binary architecture
lipo -info build/MySound.app/Contents/MacOS/MySound
```

### 4. Test Local Execution
Verify the newly compiled build opens cleanly without crashing:
```bash
killall MySound 2>/dev/null || true
open build/MySound.app
```
