import SwiftUI
import AppKit
import CoreAudio

struct AppVolume: Identifiable {
    var id: Int32 { pid } // Use PID as unique ID
    let bundleId: String
    let pid: pid_t
    let name: String
    let icon: NSImage
    var volume: Double
}

class AppManager: ObservableObject {
    @Published var apps: [AppVolume] = []

    init() {
        self.apps = Self.getRunningApps(existingApps: [])

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc func updateApps(notification: Notification) {
        let newApps = Self.getRunningApps(existingApps: self.apps)
        DispatchQueue.main.async {
            self.apps = newApps
        }
    }

    static func getRunningApps(existingApps: [AppVolume]) -> [AppVolume] {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var newApps: [AppVolume] = []
        for app in runningApps {
            guard let bundleIdentifier = app.bundleIdentifier,
                  let name = app.localizedName,
                  let icon = app.icon else { continue }

            let existingVolume = existingApps.first(where: { $0.pid == app.processIdentifier })?.volume ?? 1.0
            newApps.append(AppVolume(bundleId: bundleIdentifier, pid: app.processIdentifier, name: name, icon: icon, volume: existingVolume))
        }

        return newApps.sorted(by: { $0.name < $1.name })
    }
}

struct VolumeControlView: View {
    @State private var masterVolume: Double = 0.75

    // Use our new AppManager to supply live data
    @StateObject private var appManager = AppManager()
    @StateObject private var tapManager = AudioTapManager()

    var body: some View {
        VStack(spacing: 0) {
            // Header / Master Volume
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Output Device")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "headphones")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: masterVolume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Slider(value: $masterVolume, in: 0...1)
                        .tint(.blue)
                        .onChange(of: masterVolume) { newValue in
                            tapManager.setMasterVolume(Float(newValue))
                        }

                    Text("\(Int(masterVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // App Volumes
            VStack(spacing: 0) {
                if appManager.apps.isEmpty {
                    Text("No apps running")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach($appManager.apps) { $app in
                                AppVolumeRow(app: $app) { newVolume in
                                    tapManager.setVolume(for: app.pid, volume: newVolume)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(width: 320, height: 400)
            .onAppear {
                let newApps = AppManager.getRunningApps(existingApps: appManager.apps)
                appManager.apps = newApps
            }
            .onChange(of: appManager.apps.map { $0.pid }) { oldPids, newPids in
                // Handle terminated apps
                for pid in oldPids where !newPids.contains(pid) {
                    tapManager.removeTap(for: pid)
                }
            }

            Divider()

            // Footer
            HStack {
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit MySound")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Spacer()

                Button(action: {
                    // Settings action
                }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
    }
}

struct AppVolumeRow: View {
    @Binding var app: AppVolume
    var onVolumeChange: (Float) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                // App Icon
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)


                Text(app.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(Int(app.volume * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                Slider(value: $app.volume, in: 0...1)
                    .tint(.gray)
                    .onChange(of: app.volume) { _, newValue in
                        onVolumeChange(Float(newValue))
                    }
            }
        }
    }
}

// Helper to use NSVisualEffectView in SwiftUI for glassmorphism
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
