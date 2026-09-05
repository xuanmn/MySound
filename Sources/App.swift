import SwiftUI
import AppKit

// =============================================================================
// MARK: - Application Delegate
// =============================================================================

/// `MySoundAppDelegate` handles macOS application lifecycle events that SwiftUI does not expose,
/// ensuring clean teardown of CoreAudio resources (aggregate devices, process taps) when the
/// app is terminated by the system (e.g. logout, shutdown, force quit).
@MainActor
class MySoundAppDelegate: NSObject, NSApplicationDelegate {
    /// Called by macOS when the application is about to terminate (user quit, system shutdown, etc.).
    /// Ensures all CoreAudio process taps and aggregate devices are destroyed cleanly.
    func applicationWillTerminate(_ notification: Notification) {
        AudioTapManager.shared.removeAllTaps()
    }
}

// =============================================================================
// MARK: - App Entry Point
// =============================================================================

/// `MySoundApp` is the main entry point for the MySound macOS menu bar utility.
///
/// Architecture Overview:
/// - MySound runs as an `LSUIElement` (an agent/menu bar app without a Dock icon).
/// - It uses macOS 14.2+ CoreAudio Process Taps to capture and scale per-application audio.
/// - The UI is rendered as a popover window attached to the macOS system menu bar using SwiftUI's `MenuBarExtra`.
@main
struct MySoundApp: App {
    
    /// Bridges AppKit lifecycle events (e.g. applicationWillTerminate) into the SwiftUI app.
    @NSApplicationDelegateAdaptor(MySoundAppDelegate.self) var appDelegate
    
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
