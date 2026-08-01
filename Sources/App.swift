import SwiftUI

@main
struct MySoundApp: App {
    init() {
        print("MySound Starting Up...")
        UpdateManager.shared.checkForUpdates()
    }
    var body: some Scene {
        MenuBarExtra("MySound", systemImage: "speaker.wave.2.fill") {
            // Fix 10: inject singleton UpdateManager as EnvironmentObject so
            // VolumeControlView uses @EnvironmentObject instead of @StateObject(singleton)
            VolumeControlView()
                .environmentObject(UpdateManager.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

