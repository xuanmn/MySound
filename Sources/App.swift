import SwiftUI

@main
struct MySoundApp: App {
    init() {
        print("MySound Starting Up...")
        _ = AudioTapManager.shared
        _ = AppManager.shared
        UpdateManager.shared.checkForUpdates()
    }
    var body: some Scene {
        MenuBarExtra("MySound", systemImage: "speaker.wave.2.fill") {
            VolumeControlView()
                .environmentObject(UpdateManager.shared)
                .environmentObject(AudioTapManager.shared)
                .environmentObject(AppManager.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

