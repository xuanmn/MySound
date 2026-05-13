# MySound 🔊

**MySound** is a lightweight, high-performance macOS utility that gives you individual volume control for every application running on your Mac. No virtual drivers, no complex setup—just simple, per-app audio management.

![MySound Screenshot](https://raw.githubusercontent.com/user/repo/main/screenshot.png) *(Replace with your actual screenshot)*

## ✨ Features

- **Individual App Sliders**: Adjust the volume of Chrome, Spotify, Zoom, or any other app independently.
- **Dynamic App List**: Only shows apps that are currently playing audio to keep the interface clean.
- **System Volume Sync**: The master slider controls your hardware volume and stays in sync with your keyboard volume keys.
- **Launch at Login**: Optional setting to have MySound start automatically when you log in.
- **High Performance**: Uses a thread-safe ring buffer and `AVAudioEngine` for zero-latency, crash-free audio processing.

## 🚀 Installation

1. Download the latest `MySound.zip` from the [Releases](https://github.com/YOUR_USERNAME/MySound/releases) page.
2. Unzip the file.
3. Move `MySound.app` to your `/Applications` folder.

### ⚠️ Important: First Launch Instructions
Because MySound is an open-source project and not signed with an Apple Developer certificate, macOS Gatekeeper will show a warning on the first launch.

1. **Right-click** (or Control-click) `MySound.app` in your Applications folder.
2. Select **Open** from the menu.
3. Click **Open** again in the dialog box.
4. You will only need to do this once.

## 🛡️ Permissions

MySound requires two permissions to function:
- **System Audio Recording**: Required to "tap" into the audio streams of other applications.
- **Accessibility**: Required to manage application processes.

## 🛠️ Building from Source

If you want to build the app yourself, you'll need a Mac with Xcode installed.

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/MySound.git
   cd MySound
   ```
2. Build the app:
   ```bash
   ./build.sh
   ```
3. The app will be available at `build/MySound.app`.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
