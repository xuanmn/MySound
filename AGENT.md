# MySound — AI Developer & Agent Guide

## 1. Tech Stack & Runtimes

- **Language & Runtime:** Swift 5.9+ (compiled natively targeting macOS 14.2+ Sonoma & macOS 15.0+ Sequoia; Universal Binary `arm64` + `x86_64`).
- **Core Frameworks & APIs:**
  - `SwiftUI`: Menu bar popover window interface (`MenuBarExtra` with `.window` style).
  - `AppKit` / `Cocoa`: macOS lifecycle, `NSWorkspace` notifications (app launch/termination), `NSImage` icon caching.
  - `CoreAudio`: macOS 14.2+ Process Taps private SPI (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`), Audio HAL listeners, dynamic aggregate output switching.
  - `Accelerate` (`vDSP`): Real-time SIMD audio buffer volume gain multiplication.
  - `ServiceManagement`: Native background login item management via `SMAppService`.
  - `Combine` / `Foundation`: Reactive state management (`ObservableObject`, `@Published`), ephemeral `URLSession` for un-cached update checks.
- **Dependency Management:** Zero external dependencies (no SPM, CocoaPods, or Carthage). All linking is against native macOS system SDK frameworks via `swiftc`.
- **Build & Distribution Tooling:** Standalone Bash scripts (`build.sh`, `install.sh`) leveraging `swiftc`, `lipo`, `codesign`, `hdiutil`, `zip`, and `xcrun notarytool`.

---

## 2. Key Commands

### Build & Package
```bash
# Build Universal Binary (arm64 + x86_64), ad-hoc sign, and package DMG + ZIP into build/
./build.sh

# Build and sign with an official Apple Developer ID certificate
DEVELOPER_ID="Developer ID Application: Your Name (ID)" ./build.sh

# Build, sign, and submit for Apple Notarization
NOTARIZE_PROFILE="MyProfile" DEVELOPER_ID="Developer ID Application: Your Name (ID)" ./build.sh
```

### Run & Manage Locally
```bash
# Launch local build from workspace
open build/MySound.app

# Terminate running MySound process
killall MySound 2>/dev/null || true

# Test 1-line installation script locally (installs to /Applications)
./install.sh
```

### Debugging & Diagnostics
```bash
# Stream live application and CoreAudio HAL diagnostic logs
tail -f ~/Library/Logs/MySound.log

# Verify code signature & active entitlements on the compiled bundle
codesign -d --entitlements :- build/MySound.app
```

---

## 3. Project Structure & Architecture

```
MySound/
├── AGENT.md                 # Agent context, architecture guide, and conventions
├── .agentignore             # Files/folders excluded from agent context
├── Entitlements.plist       # macOS security entitlements (audio capture, audio input, sandbox disabled)
├── version.json             # Single source of truth for release versioning and changelog
├── build.sh                 # Universal compiler, bundler, code signer, and DMG/ZIP packager
├── install.sh               # 1-line curl/bash installer for end-users
├── Resources/               # Application icons (.icns, .png) and assets
└── Sources/
    ├── App.swift            # Main entry point (@main MySoundApp); menu bar extra popover setup
    ├── AudioTapManager.swift# CoreAudio engine: private SPI process taps, vDSP scaling, device routing, VolumeStore, AppLogger
    ├── VolumeControlView.swift # SwiftUI UI: AppManager (active audio polling), master & per-app sliders, output picker
    └── UpdateManager.swift  # Auto-updater: GitHub Releases API & version.json fetching, background DMG/ZIP extraction & relaunch
```

### Core Architecture Flow
1. **Audio Tap Lifecycle (`AudioTapManager.swift`)**:
   - Intercepts audio output of running apps by PID using `CATapDescription` (`AudioHardwareCreateProcessTap`).
   - Mutes default app output and routes intercepted buffers into a virtual Aggregate Device targeting the selected physical output.
   - Applies volume gain scaling on raw PCM buffers inside the real-time audio callback using `vDSP_vsmul`.
2. **App Discovery & UI State (`VolumeControlView.swift` / `AppManager`)**:
   - `AppManager` polls active audio processes using `NSWorkspace` notifications and a 1.5s interval timer.
   - State flows down to SwiftUI view hierarchy via `ObservableObject` singletons (`AudioTapManager.shared`, `AppManager.shared`, `UpdateManager.shared`).
3. **Distribution & Version Sync (`version.json` + `build.sh`)**:
   - `version.json` defines the canonical version string. `build.sh` extracts this version at compile time to stamp `Info.plist`.

---

## 4. Coding Standards & Invariants

- **Swift Concurrency & Actor Isolation:**
  - UI updates and `@Published` properties MUST be executed on `@MainActor`.
  - Non-isolated state shared across threads must conform to `Sendable` or `@unchecked Sendable` with explicit lock synchronization (e.g., `VolumeStore` using `os_unfair_lock`).
- **Real-Time Audio Safety Rules (`AudioTapManager.swift`):**
  - The CoreAudio IO callback runs on a high-priority real-time thread.
  - **NEVER** allocate memory (`malloc`, Swift `Array`/`String` copies), call Objective-C runtime methods, invoke Swift actor hops, or perform blocking locks in the audio callback.
  - Use `VolumeStore` (`os_unfair_lock`) only for microsecond scalar lookups.
- **Error Handling & Resilience:**
  - Check CoreAudio `OSStatus` codes explicitly; log failures via `AppLogger.shared.log(...)` and provide graceful fallbacks.
  - In `build.sh`, maintain graceful dual-architecture compilation fallbacks if one architecture toolchain fails.
  - In `UpdateManager.swift`, try unmetered static `version.json` first before falling back to rate-limited GitHub REST API.
- **Formatting & Style:**
  - Structure all Swift files with clear `// MARK: - <Section Name>` dividers.
  - Document all public and internal classes, structs, and methods with three-slash docstrings (`///`).
  - Follow standard Swift naming conventions: PascalCase for types/protocols, camelCase for properties/methods.
