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
    static let shared = AppManager()
    @Published var apps: [AppVolume] = []
    private var timer: Timer?

    init() {
        // Don't call expensive getRunningApps() synchronously on @MainActor init —
        // it blocks the main thread with CoreAudio/proc_pidpath calls.
        // Defer to an async task so the UI can appear immediately.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apps = Self.getRunningApps(existingApps: [])
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateApps), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        
        // Periodically refresh to catch apps that start/stop playing audio
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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
    // Bug #8 fix: debounce to prevent overlapping timer fires from racing
    private var pendingUpdate: DispatchWorkItem?

    @objc func updateApps(notification: Notification? = nil) {
        pendingUpdate?.cancel()
        let existingApps = self.apps
        let workItem = DispatchWorkItem { [weak self] in
            let newApps = Self.getRunningApps(existingApps: existingApps)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let currentPIDs = self.apps.map { $0.pid }
                let newPIDs = newApps.map { $0.pid }
                if currentPIDs != newPIDs {
                    self.apps = newApps
                }
                for app in newApps {
                    AudioTapManager.shared.ensureTapCreated(for: app.pid)
                }
            }
        }
        pendingUpdate = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    // Fix 11: removed extra blank line between allRunning and runningApps
    // nonisolated allows calling this from a background Task.detached (Fix 8)
    nonisolated static func getRunningApps(existingApps: [AppVolume]) -> [AppVolume] {
        let activeAudioPIDs = AudioTapManager.getAudioActivePIDs(onlyPlayingAudio: true)
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
    @State private var previousMasterVolume: Double = 0.5
    @State private var isLaunchAtLogin: Bool = false
    @State private var savedAppVolumes: [Int32: Double] = [:]
    @State private var isQuitHovered: Bool = false
    @State private var isGearHovered: Bool = false
    @State private var hasPermission: Bool = true
    @State private var permissionCheckTimer: Timer?
    // Fix 7: store sync timer so it can be cancelled on disappear
    @State private var syncTimer: Timer?

    @EnvironmentObject private var appManager: AppManager
    @EnvironmentObject private var tapManager: AudioTapManager
    // Fix 10: consume UpdateManager via EnvironmentObject (injected from App.swift)
    @EnvironmentObject private var updateManager: UpdateManager

    private var isAllMuted: Bool {
        !appManager.apps.isEmpty && appManager.apps.allSatisfy { $0.volume <= 0.001 }
    }

    private func toggleMuteAll() {
        if isAllMuted {
            for i in 0..<appManager.apps.count {
                let pid = appManager.apps[i].pid
                let restored = savedAppVolumes[pid] ?? 1.0
                appManager.apps[i].volume = restored > 0.001 ? restored : 1.0
                tapManager.setVolume(for: pid, volume: Float(appManager.apps[i].volume))
            }
        } else {
            for i in 0..<appManager.apps.count {
                let pid = appManager.apps[i].pid
                if appManager.apps[i].volume > 0.001 {
                    savedAppVolumes[pid] = appManager.apps[i].volume
                }
                appManager.apps[i].volume = 0
                tapManager.setVolume(for: pid, volume: 0)
            }
        }
    }

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
                        Image(systemName: "arrow.down.square.fill")
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if tapManager.availableOutputDevices.count > 1 {
                        Menu {
                            ForEach(tapManager.availableOutputDevices) { device in
                                Button(action: {
                                    tapManager.setDefaultOutputDevice(device)
                                }) {
                                    HStack {
                                        Text(device.name)
                                        if tapManager.currentOutputDevice?.id == device.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(tapManager.currentOutputDevice?.name ?? "Output Device")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("Select Output Device, currently \(tapManager.currentOutputDevice?.name ?? "Output Device")")
                    } else {
                        Text(tapManager.currentOutputDevice?.name ?? "Output Device")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer()
                    if !appManager.apps.isEmpty {
                        Button(action: toggleMuteAll) {
                            Text(isAllMuted ? "Unmute All" : "Mute All")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isAllMuted ? "Unmute all running applications" : "Mute all running applications")
                    }
                    Image(systemName: deviceIconName(for: tapManager.currentOutputDevice?.name))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button(action: {
                        if masterVolume > 0.001 {
                            masterVolume = 0
                        } else {
                            masterVolume = previousMasterVolume > 0.001 ? previousMasterVolume : 0.5
                        }
                        tapManager.setSystemVolume(Float(masterVolume))
                    }) {
                        Image(systemName: masterVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.3.fill")
                            .foregroundColor(masterVolume <= 0.001 ? .red : .secondary)
                            .font(.system(size: 12))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(masterVolume <= 0.001 ? "Unmute system master volume" : "Mute system master volume")
                    
                    BoxySlider(value: $masterVolume, range: 0...1, tint: .blue)
                        .accessibilityLabel("System Master Volume")
                        .accessibilityValue("\(Int(masterVolume * 100)) percent")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment:
                                masterVolume = min(masterVolume + 0.05, 1.0)
                            case .decrement:
                                masterVolume = max(masterVolume - 0.05, 0.0)
                            @unknown default:
                                break
                            }
                            tapManager.setSystemVolume(Float(masterVolume))
                        }
                        .onChange(of: masterVolume) { _, newValue in
                            if newValue > 0.001 {
                                previousMasterVolume = newValue
                            }
                            tapManager.setSystemVolume(Float(newValue))
                        }
                        .onTapGesture(count: 2) {
                            masterVolume = 1.0
                            tapManager.setSystemVolume(1.0)
                        }
                    
                    Text("\(Int(masterVolume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .onAppear {
                masterVolume = Double(tapManager.getSystemVolume())
                if masterVolume > 0.001 {
                    previousMasterVolume = masterVolume
                }
                checkLaunchAtLoginStatus()
                hasPermission = AudioTapManager.hasAudioCapturePermission()
                
                // Fix 7: store timer so it can be cancelled in onDisappear
                syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    Task { @MainActor in
                        let current = Double(tapManager.getSystemVolume())
                        if (current <= 0.001) != (masterVolume <= 0.001) || abs(current - masterVolume) > 0.005 {
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

            // In-App Permission Guidance Banner
            if !hasPermission {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("System Audio Access Required")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            Text("Grant Screen & System Audio Recording permission to adjust per-app volume.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(action: {
                        AudioTapManager.openSystemAudioPermissionSettings()
                    }) {
                        HStack(spacing: 4) {
                            Text("Open System Settings")
                                .font(.caption)
                                .fontWeight(.medium)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }

            // App Volumes
            VStack(spacing: 0) {
                if appManager.apps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.slash.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("No Audio Playing")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("Start sound in an app (e.g. Spotify, Chrome) to control its volume.")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        Button(action: {
                            AudioTapManager.openSystemAudioPermissionSettings()
                        }) {
                            Text("Check Permissions")
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 24)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        ForEach($appManager.apps) { $app in
                            AppVolumeRow(app: $app) { newVolume in
                                tapManager.setVolume(for: app.pid, volume: newVolume)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }
            }
            .frame(width: 300)
            .animation(.easeInOut(duration: 0.2), value: appManager.apps.map { $0.pid })
            .onAppear {
                hasPermission = AudioTapManager.hasAudioCapturePermission()
                let newApps = AppManager.getRunningApps(existingApps: appManager.apps)
                appManager.apps = newApps
                // Re-check permission every 3 seconds so the banner disappears
                // once the user grants access without needing to relaunch
                permissionCheckTimer?.invalidate()
                permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                    Task { @MainActor in
                        hasPermission = AudioTapManager.hasAudioCapturePermission()
                    }
                }
            }
            .onDisappear {
                permissionCheckTimer?.invalidate()
                permissionCheckTimer = nil
            }
            .onChange(of: appManager.apps.map { $0.pid }) { oldPids, newPids in
                // Handle terminated apps
                for pid in oldPids where !newPids.contains(pid) {
                    tapManager.removeTap(for: pid)
                }
            }

            Divider()

            // Footer
            HStack(spacing: 8) {
                // Quit Button with Power Icon, ⌘Q Shortcut & Hover Effect
                Button(action: {
                    // Bug #5 fix: clean up all taps before quitting
                    tapManager.removeAllTaps()
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Quit")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("⌘Q")
                            .font(.caption2)
                            .foregroundColor(isQuitHovered ? .red.opacity(0.8) : .secondary.opacity(0.6))
                    }
                    .foregroundColor(isQuitHovered ? .red : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isQuitHovered ? Color.red.opacity(0.1) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit MySound, Command Q")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isQuitHovered = hovering
                    }
                }

                Spacer()

                // Version Badge
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.0")")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))

                // Settings Gear Menu with Hover Pill & Icon
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isGearHovered ? .primary : .secondary)
                        .padding(6)
                        .background(isGearHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Settings")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isGearHovered = hovering
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

    private func deviceIconName(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "speaker.wave.2.fill" }
        if name.contains("airpod") {
            return "airpodspro"
        } else if name.contains("headphone") || name.contains("headset") {
            return "headphones"
        } else if name.contains("hdmi") || name.contains("tv") || name.contains("displayport") {
            return "tv"
        } else {
            return "speaker.wave.2.fill"
        }
    }
}

struct AppVolumeRow: View {
    @Binding var app: AppVolume
    var onVolumeChange: (Float) -> Void
    @State private var previousVolume: Double = 0.5
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                // App Icon
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .opacity(app.volume <= 0.001 ? 0.4 : 1.0)

                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(app.volume <= 0.001 ? .secondary : .primary)

                    if app.volume > 0.001 {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundColor(.blue.opacity(0.8))
                            .accessibilityLabel("Playing audio")
                    }
                }

                Spacer()

                Text("\(Int(app.volume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button(action: {
                    if app.volume > 0.001 {
                        previousVolume = app.volume
                        app.volume = 0
                    } else {
                        app.volume = previousVolume > 0.001 ? previousVolume : 0.5
                    }
                    onVolumeChange(Float(app.volume))
                }) {
                    Image(systemName: app.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(app.volume <= 0.001 ? .red : .secondary)
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.volume <= 0.001 ? "Unmute \(app.name)" : "Mute \(app.name)")

                BoxySlider(value: $app.volume, range: 0...1, tint: app.volume <= 0.001 ? .gray.opacity(0.4) : .blue)
                    .accessibilityLabel("\(app.name) volume")
                    .accessibilityValue("\(Int(app.volume * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            app.volume = min(app.volume + 0.05, 1.0)
                        case .decrement:
                            app.volume = max(app.volume - 0.05, 0.0)
                        @unknown default:
                            break
                        }
                        // Note: do NOT call onVolumeChange here —
                        // onChange(of: app.volume) fires automatically and handles it,
                        // preventing a double setVolume call per accessibility step.
                    }
                    .onChange(of: app.volume) { _, newValue in
                        if newValue > 0.001 {
                            previousVolume = newValue
                        }
                        onVolumeChange(Float(newValue))
                    }
                    .onTapGesture(count: 2) {
                        app.volume = 1.0
                        onVolumeChange(1.0)
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.15), value: app.volume <= 0.001)
        .onAppear {
            if app.volume > 0.001 {
                previousVolume = app.volume
            }
        }
    }
}

struct BoxySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .blue
    var trackHeight: CGFloat = 2
    var thumbWidth: CGFloat = 20
    var thumbHeight: CGFloat = 12

    @State private var isHovered: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let usableWidth = max(totalWidth - thumbWidth, 1)
            let percent = max(0, min(1, CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))))
            let thumbX = percent * usableWidth
            let fillWidth = percent * usableWidth + (thumbWidth / 2)

            ZStack(alignment: .leading) {
                // Background Track (Ultra-Skinny Bar)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: trackHeight)

                // Filled Track (Ultra-Skinny Bar)
                Rectangle()
                    .fill(tint)
                    .frame(width: fillWidth, height: trackHeight)

                // Horizontal Pill / Capsule Thumb Handle (matching screenshot)
                Capsule()
                    .fill(Color(white: 0.92))
                    .overlay(
                        Capsule()
                            .stroke(isDragging || isHovered ? tint : Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 1.5, x: 0, y: 1)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: thumbX)
            }
            .frame(height: max(thumbHeight + 4, 16), alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let locationX = gesture.location.x - (thumbWidth / 2)
                        let newPercent = max(0, min(1, locationX / usableWidth))
                        var newValue = range.lowerBound + Double(newPercent) * (range.upperBound - range.lowerBound)
                        if newValue < 0.005 {
                            newValue = 0.0
                        } else if newValue > 0.995 {
                            newValue = 1.0
                        }
                        value = newValue
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: max(thumbHeight + 4, 16))
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
