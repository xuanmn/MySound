import SwiftUI

@main
struct MySoundApp: App {
    init() {
        print("MySound Starting Up...")
        UpdateManager.shared.checkForUpdates()
    }
    var body: some Scene {
        MenuBarExtra("MySound", systemImage: "speaker.wave.2.fill") {
            VolumeControlView()
        }
        .menuBarExtraStyle(.window)
    }
}
