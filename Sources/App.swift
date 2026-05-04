import SwiftUI

@main
struct MySoundApp: App {
    init() {
        AudioEngine.installDriverIfNeeded()
        
        // Launch the hidden background daemon to handle audio routing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AudioEngine.launchDaemonIfNeeded()
        }
    }
    
    var body: some Scene {
        MenuBarExtra("MySound", systemImage: "speaker.wave.2.fill") {
            VolumeControlView()
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}
