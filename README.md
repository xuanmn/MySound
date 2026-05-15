# 🎧 MySound

**The ultimate per-app volume controller for macOS.**

MySound gives you total control over your Mac's audio. Adjust the volume of individual applications like Chrome, Spotify, or Zoom independently of your system volume—all from a beautiful, minimalist menu bar interface.



<img width="346" height="294" alt="ishare-1778743731-terminal" src="https://github.com/user-attachments/assets/9e9d70a5-27a6-4a52-b99e-41a46d2e98eb"/>

## ✨ Features

- **Per-App Volume Control**: Fine-tune the volume for every running application.
- **Direct-Zero Architecture**: Zero-latency audio routing for perfect sync and crystal-clear sound.
- **Smart App Grouping**: Automatically bundles sub-processes (like Chrome helpers) into a single control.
- **Native Experience**: Built with Swift and SwiftUI to feel right at home on macOS.
- **Dynamic Interface**: A sleek, translucent UI that adapts to your active apps.
- **Launch at Login**: Ready to go the moment you start your Mac.
- **Auto-Updates**: Built-in update manager to keep you on the latest version.

## 🚀 Getting Started

### Prerequisites
- macOS 14.2 or later (Sonoma or Sequoia)
- Apple Silicon (M1/M2/M3) recommended

### Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/xuanmn/MySound.git
   cd MySound
   ```

2. **Build the app**:
   ```bash
   ./build.sh
   ```

3. **Run MySound**:
   ```bash
   open build/MySound.app
   ```

### Permissions
On first launch, macOS will ask for **Microphone Access**.
> [!NOTE]
> MySound **does not record your microphone**. It requires this permission to utilize the Core Audio "Tap" system for per-app volume routing.

## 🛠 Troubleshooting

- **No sound?** Ensure that the app you want to control is actually playing audio.
- **Distorted audio?** Try restarting the app or your output device. MySound automatically syncs with your hardware sample rate for the best quality.

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Developed with ❤️ by Xuanmn*
