import SwiftUI
import AppKit

struct AppVolume: Identifiable {
    let id: String // We'll use the app's bundle identifier or PID
    let name: String
    let icon: NSImage
    var volume: Double
}

class AppManager: ObservableObject {
    @Published var apps: [AppVolume] = []
    
    init() {
        fetchRunningApps()
        
        // Listen for apps opening and closing so the list updates live!
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }
    
    @objc func updateApps(notification: Notification) {
        fetchRunningApps()
    }
    
    func fetchRunningApps() {
        // Find all running apps that are "regular" (they have a dock icon/user interface)
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        
        var newApps: [AppVolume] = []
        for app in runningApps {
            // Ensure the app has a name, bundle ID, and an icon
            guard let bundleIdentifier = app.bundleIdentifier,
                  let name = app.localizedName,
                  let icon = app.icon else { continue }
            
            // If the app is already in our list, keep its current volume. Otherwise, default to 1.0 (100%)
            let existingVolume = self.apps.first(where: { $0.id == bundleIdentifier })?.volume ?? 1.0
            
            newApps.append(AppVolume(id: bundleIdentifier, name: name, icon: icon, volume: existingVolume))
        }
        
        // Update the UI on the main thread and sort them alphabetically
        DispatchQueue.main.async {
            self.apps = newApps.sorted(by: { $0.name < $1.name })
        }
    }
}

struct VolumeControlView: View {
    @State private var masterVolume: Double = 0.75
    
    // Use our new AppManager to supply live data
    @StateObject private var appManager = AppManager()
    
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
            ScrollView {
                VStack(spacing: 20) {
                    if appManager.apps.isEmpty {
                        Text("No apps running")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        // Iterate through our live list of apps
                        ForEach($appManager.apps) { $app in
                            AppVolumeRow(app: $app)
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: 400)
            
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
    
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                // Use the actual app icon instead of a generic SF Symbol
                Image(nsImage: app.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                
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
