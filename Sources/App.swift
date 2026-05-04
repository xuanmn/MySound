import SwiftUI

@main
struct MySoundApp: App {
    var body: some Scene {
        MenuBarExtra("MySound", systemImage: "speaker.wave.2.fill") {
            VolumeControlView()
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}
