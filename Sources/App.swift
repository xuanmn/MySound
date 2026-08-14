import SwiftUI

/// `MySoundApp` is the main entry point for the MySound macOS menu bar utility.
///
/// Architecture Overview:
/// - MySound runs as an `LSUIElement` (an agent/menu bar app without a Dock icon).
/// - It uses macOS 14.2+ CoreAudio Process Taps to capture and scale per-application audio.
/// - The UI is rendered as a popover window attached to the macOS system menu bar using SwiftUI's `MenuBarExtra`.
@main
struct MySoundApp: App {
    
    /// Initializes core managers upon startup.
    init() {
        print("MySound Starting Up...")
        
        // 1. Initialize AudioTapManager:
        //    Sets up CoreAudio HAL listeners for process audio events and hardware output device changes.
        _ = AudioTapManager.shared
        
        // 2. Initialize AppManager:
        //    Begins tracking active running applications that are currently producing audio.
        _ = AppManager.shared
        
        // 3. Check for app updates:
        //    Silently checks GitHub Releases or version.json in the background for newer releases.
        UpdateManager.shared.checkForUpdates()
    }
    
    var body: some Scene {
        // MenuBarExtra creates an icon in the macOS menu bar.
        // - "MySound": Accessibility title
        // - systemImage: SF Symbol icon displayed in the menu bar tray
        MenuBarExtra("MySound", systemImage: "speaker.wave.2.fill") {
            // Main popover view presenting master volume and per-app sliders
            VolumeControlView()
                // Inject shared singleton state into the SwiftUI environment
                .environmentObject(UpdateManager.shared)
                .environmentObject(AudioTapManager.shared)
                .environmentObject(AppManager.shared)
        }
        // Use .window style so the popup behaves like a rich interactive flyout (not a plain text menu)
        .menuBarExtraStyle(.window)
    }
}


