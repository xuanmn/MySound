import SwiftUI
import AppKit
import ServiceManagement

struct AppVolume: Identifiable {
    var id: Int32 { pid } // Use PID as unique ID
    let pid: pid_t
    let name: String
    let icon: NSImage
    var volume: Double
}

@MainActor
class AppManager: ObservableObject {
    @Published var apps: [AppVolume] = []
    private var timer: Timer?

    init() {
        self.apps = Self.getRunningApps(existingApps: [])

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        
        // Periodically refresh to catch apps that start/stop playing audio
        self.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateApps()
            }
        }
    }

    // Fix 9: invalidate timer on deinit to prevent it firing after deallocation
    deinit {
        timer?.invalidate()
    }

    // Fix 8: run expensive work on a background task to avoid main-thread stalls
    @objc func updateApps(notification: Notification? = nil) {
        let existingApps = self.apps
        Task.detached(priority: .utility) {
            let newApps = Self.getRunningApps(existingApps: existingApps)
            await MainActor.run {
                let currentPIDs = self.apps.map { $0.pid }
                let newPIDs = newApps.map { $0.pid }
                if currentPIDs != newPIDs {
                    self.apps = newApps
                }
            }
        }
    }

    // Fix 11: removed extra blank line between allRunning and runningApps
    // nonisolated allows calling this from a background Task.detached (Fix 8)
    nonisolated static func getRunningApps(existingApps: [AppVolume]) -> [AppVolume] {
        let activeAudioPIDs = AudioTapManager.getAudioActivePIDs()
        let allRunning = NSWorkspace.shared.runningApplications
        let runningApps = allRunning.filter { app in
            let isRegular = app.activationPolicy == .regular
            let isActive = activeAudioPIDs.contains(app.processIdentifier)
            return isRegular && isActive
        }

        var newApps: [AppVolume] = []
        for app in runningApps {
            guard let name = app.localizedName,
                  let icon = app.icon else { continue }

            let existingVolume = existingApps.first(where: { $0.pid == app.processIdentifier })?.volume ?? 1.0
            newApps.append(AppVolume(pid: app.processIdentifier, name: name, icon: icon, volume: existingVolume))
        }

        return newApps.sorted(by: { $0.name < $1.name })
    }
}

struct VolumeControlView: View {
    @State private var masterVolume: Double = 0.5
    @State private var isLaunchAtLogin: Bool = false
    // Fix 7: store sync timer so it can be cancelled on disappear
    @State private var syncTimer: Timer?

    @StateObject private var appManager = AppManager()
    @StateObject private var tapManager = AudioTapManager()
    // Fix 10: consume UpdateManager via EnvironmentObject (injected from App.swift)
    @EnvironmentObject private var updateManager: UpdateManager

    var body: some View {
        VStack(spacing: 0) {
            // Update Banner
            if updateManager.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                        Text(updateManager.updateStatus ?? "Updating...")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    ProgressView(value: updateManager.downloadProgress)
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                Divider()
            } else if updateManager.isUpdateAvailable {
                Button(action: {
                    updateManager.performInAppUpdate()
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update Available (\(updateManager.latestVersion ?? ""))")
                        Spacer()
                        Text("Update Now")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                Divider()
            }

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
                        .onChange(of: masterVolume) { _, newValue in
                            tapManager.setSystemVolume(Float(newValue))
                        }
                    
                    Text("\(Int(masterVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .onAppear {
                masterVolume = Double(tapManager.getSystemVolume())
                checkLaunchAtLoginStatus()
                
                // Fix 7: store timer so it can be cancelled in onDisappear
                syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    Task { @MainActor in
                        let current = Double(tapManager.getSystemVolume())
                        if abs(current - masterVolume) > 0.01 {
                            masterVolume = current
                        }
                    }
                }
            }
            .onDisappear {
                // Fix 7: cancel timer when popup closes to prevent stacking
                syncTimer?.invalidate()
                syncTimer = nil
            }

            Divider()

            // App Volumes
            VStack(spacing: 0) {
                if appManager.apps.isEmpty {
                    Text("No apps playing audio")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
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
            .frame(width: 300)
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

                Menu {
                    Toggle("Launch at Login", isOn: $isLaunchAtLogin)
                        .onChange(of: isLaunchAtLogin) { _, newValue in
                            toggleLaunchAtLogin(newValue)
                        }
                    
                    Divider()
                    
                    Button("Check for Updates...") {
                        updateManager.checkForUpdates(manual: true)
                    }
                    .disabled(updateManager.isChecking || updateManager.isDownloading)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .padding(.horizontal)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("ERROR: Could not update launch at login status: \(error)")
        }
    }

    private func checkLaunchAtLoginStatus() {
        isLaunchAtLogin = SMAppService.mainApp.status == .enabled
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

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
