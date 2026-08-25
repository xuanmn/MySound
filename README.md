<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="MySound App Icon">
</p>

# MySound

**The ultimate per-app volume controller for macOS.**

MySound gives you total control over your Mac's audio. Adjust the volume of individual applications like Chrome, Spotify, or Zoom independently of your system volume—all from a beautiful, minimalist menu bar interface.

<p align="center">
  <img src="Resources/preview.png" width="440" alt="MySound UI Preview (v1.6.0)">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.6.0-blue.svg" alt="Version 1.6.0">
  <img src="https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey.svg" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/architecture-Universal%20(arm64%20%2B%20x86__64)-success.svg" alt="Universal Binary">
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT">
</p>

---

## ✨ Features

- **Per-App Volume Control**: Fine-tune audio levels for individual running applications (Chrome, Spotify, Zoom, Games, etc.) independently.
- **Dynamic Hardware Device Icons**: Output switcher intelligently displays native SF Symbols matching your connected device (`laptopcomputer` for Mac speakers, `airpodspro`, `headphones`, `tv`, `display`, and `desktopcomputer`).
- **Minimal Single-Line App Mixer**: Ultra-compact audio rows with high-res app icons, native name tooltips, responsive mute toggles, and smooth custom sliders.
- **Master & Quick Mute Controls**: Adjust overall system volume with double-click reset to 100%, click-to-mute, or use **Mute All** to instantly silence all active apps while saving individual gain settings.
- **Direct-Zero CoreAudio Architecture**: Low-latency CoreAudio process tap (`CATapDescription`) routing with event-driven property listeners for zero-CPU idle operation.
- **Smart App Detection**: Automatically detects active sound-producing applications and dynamically updates the control panel.
- **Native macOS Interface**: Crafted with Swift and SwiftUI utilizing native glassmorphic popover translucency and smooth hover feedback.
- **Keyboard Shortcuts & Quick Gestures**: Press `⌘Q` to quit, double-click any slider to reset to 100%.
- **Launch at Login**: Automatic background startup via Apple's native `SMAppService` framework.
- **Built-in Auto-Updater**: In-app version checks and automated background update downloads.
- **Standalone DMG Installer**: Fast Universal Binary (`arm64` + `x86_64`) package for instant drag-and-drop installation into `/Applications`.

---

## 🚀 Getting Started

### Prerequisites
- **macOS 14.2 (Sonoma)** or **macOS 15.0+ (Sequoia)**
- **Apple Silicon** (M1/M2/M3/M4) or **Intel** Mac

### Installation

#### Option 1: 1-Line Terminal Quick Install (Recommended)
Run this single command in your Terminal to automatically download, install to `/Applications`, clear Gatekeeper restrictions, and launch MySound:
```bash
curl -fsSL https://raw.githubusercontent.com/xuanmn/MySound/main/install.sh | bash
```

#### Option 2: Download DMG Package
1. Download **`MySound.dmg`** from the [Latest Releases](https://github.com/xuanmn/MySound/releases) page.
2. Double-click the DMG and drag **MySound** into your **Applications** folder.
3. On first launch, **Right-click** (or `Control` + click) on `MySound.app` in `/Applications` and select **Open**.

#### Option 3: Build & Run Locally (Recommended for Other Macs)
If installing on a different Mac without an official Apple Developer ID certificate, building from source directly on that machine ensures macOS correctly assigns local ad-hoc code signature entitlements and bypasses Gatekeeper restrictions:

1. Clone the repository:
   ```bash
   git clone https://github.com/xuanmn/MySound.git
   cd MySound
   ```
2. Build the Universal Binary locally:
   ```bash
   ./build.sh
   ```
3. Launch the app:
   ```bash
   open build/MySound.app
   ```
*(Note: Requires Xcode Command Line Tools `xcode-select --install`).*

---

## ⚡ Controls & Keyboard Shortcuts

| Control / Action | Description |
| :--- | :--- |
| **Output Selector** | Click top-left dropdown (e.g. *MacBook Air Speakers*) to switch active audio output device. |
| **Hardware Icon** | Dynamic indicator displaying device type (`laptopcomputer`, `airpodspro`, `headphones`, `tv`, `desktopcomputer`). |
| **Mute All / Unmute All** | Header button to instantly mute or restore volume across all active applications. |
| **Master Volume Row** | Drag master slider or click speaker icon to mute/unmute global system audio. |
| **Double-Click Slider** | Instantly resets master or app volume directly to 100%. |
| **Per-App Mixer Rows** | Single-line compact controls with application icon tooltip, dedicated mute toggle, custom slider, and percentage readout. |
| `⌘Q` | Keyboard shortcut to immediately quit MySound when window is focused. |
| **Gear Menu (⚙️)** | Toggle **Launch at Login** or manually trigger **Check for Updates...**. |

---

## 🔒 Permissions & Privacy Guide

MySound requires specific macOS permissions to intercept per-application audio streams. All audio processing is handled **100% locally on your Mac**.

### 1. System Audio Recording / Microphone Access
MySound uses Apple's CoreAudio process tap framework (`CATapDescription`) to intercept app audio streams.

> [!IMPORTANT]
> **Privacy Guarantee**: MySound **does NOT record your microphone or store your audio**. macOS categorizes process taps under system audio capture permissions. MySound only modifies sample volume gain in memory before outputting to your speakers.

**How to grant permission:**
1. MySound features a built-in **Permission Guidance Banner**. Click **Open System Settings** directly inside the app popover.
2. In **System Settings** > **Privacy & Security** > **Screen & System Audio Recording** (or **Microphone** on macOS Sonoma), ensure **MySound** is toggled **ON**.

---

### 2. Opening for the First Time (macOS Gatekeeper)
If installing via manual DMG download, macOS Gatekeeper may show a warning:
`"MySound cannot be opened because it is from an unidentified developer."`

**How to open on first launch:**
1. In Finder, open your **Applications** folder.
2. **Right-click** (or `Control` + click) on `MySound.app` and select **Open**.
3. Click **Open** in the confirmation popup.
*(Note: If you installed using the [Option 1 Terminal script](#option-1-1-line-terminal-quick-install-recommended), Gatekeeper is bypassed automatically).*

---

### 3. Launch at Login Permission
When you enable **Launch at Login** in the gear menu, MySound registers a login item via Apple's `SMAppService` framework.

**How to manage:**
- Toggle **Launch at Login** directly from the MySound menu bar gear menu.
- Or manage it in **System Settings** > **General** > **Login Items & Extensions**.

---

## 🏗️ Architecture & Codebase

- [App.swift](file:///Users/xuanmn/Developer/MySound/Sources/App.swift): Application entry point configuring the menu bar item window.
- [VolumeControlView.swift](file:///Users/xuanmn/Developer/MySound/Sources/VolumeControlView.swift): Main SwiftUI view containing master controls, output device picker, per-app volume sliders, mute all button, and footer shortcuts.
- [AudioTapManager.swift](file:///Users/xuanmn/Developer/MySound/Sources/AudioTapManager.swift): CoreAudio `CATapDescription` process tap manager handling per-PID audio routing and volume sample multiplication.
- [UpdateManager.swift](file:///Users/xuanmn/Developer/MySound/Sources/UpdateManager.swift): Release checking and automatic in-app DMG update installer.

---

## 🛠 Troubleshooting

- **App fails to control audio or open on another Mac?** Pre-built binaries are signed with an ad-hoc identity. On other Macs, Gatekeeper or TCC permission policies may block process tapping. Solve this by cloning the repository on that Mac and running `./build.sh` (Option 3).
- **An app isn't appearing in the list?** MySound automatically detects applications when they start playing audio. Start sound playback in the app (e.g. play a song on Spotify or video on YouTube) and it will appear within 2 seconds.
- **Volume slider doesn't change sound?** Ensure MySound has been granted Microphone/Audio Recording permissions under **System Settings > Privacy & Security > Microphone**.
- **Audio distortion or lag?** MySound automatically matches your default audio output sample rate. Try restarting MySound or toggling your output device from the header menu.

---

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Developed with ❤️ by Xuanmn*
