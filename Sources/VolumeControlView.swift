import SwiftUI
import AppKit
import ServiceManagement
import CoreAudio

// =============================================================================
// MARK: - Notifications
// =============================================================================

extension Notification.Name {
    /// Posted when CoreAudio HAL property listeners detect a change in system master volume or mute status.
    static let mySoundSystemVolumeChanged = Notification.Name("mySoundSystemVolumeChanged")
}

// =============================================================================
// MARK: - App Volume Model
// =============================================================================

/// `AppVolume` represents an individual running application row displayed in the MySound mixer.
struct AppVolume: Identifiable {
    /// Use the application's Process Identifier (PID) as its unique SwiftUI identity.
    var id: Int32 { pid }
    /// Operating system Process Identifier.
    let pid: pid_t
    /// Localized display name (e.g. "Spotify", "Google Chrome").
    let name: String
    /// Cached application icon image.
    let icon: NSImage
    /// Current volume scalar for this application (0.0...1.0).
    var volume: Double
}

// =============================================================================
// MARK: - App Manager
// =============================================================================

/// `AppManager` observes running macOS applications, determines which ones are actively producing audio,
/// and maintains the list of active application volume controls.
@MainActor
class AppManager: ObservableObject {
    /// Shared singleton instance.
    static let shared = AppManager()
    
    /// Published list of apps currently playing audio, bound to the SwiftUI view.
    @Published var apps: [AppVolume] = []
    
    /// Polling timer to detect when apps start or stop playing audio.
    private var timer: Timer?

    init() {
        // Defer initial app discovery to an async task on the main actor to avoid
        // blocking UI rendering during initial application launch.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apps = Self.getRunningApps(existingApps: [])
        }

        // Listen for application lifecycle events from NSWorkspace
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(updateApps),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(updateApps),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        
        // Periodically refresh (every 1.5 seconds) to catch audio playback start/stop events.
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateApps()
            }
        }
    }

    deinit {
        // Invalidate timer to prevent execution after deallocation
        timer?.invalidate()
    }

    // Debounce work item to prevent overlapping background queries
    private var pendingUpdate: DispatchWorkItem?

    /// Refreshes the list of active audio-producing applications on a background queue.
    @objc func updateApps(notification: Notification? = nil) {
        pendingUpdate?.cancel()
        let existingApps = self.apps
        
        let workItem = DispatchWorkItem { [weak self] in
            let newApps = Self.getRunningApps(existingApps: existingApps)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let currentPIDs = self.apps.map { $0.pid }
                let newPIDs = newApps.map { $0.pid }
                
                // Only trigger SwiftUI view updates if the list of active PIDs changed
                if currentPIDs != newPIDs {
                    self.apps = newApps
                }
                
                // Ensure taps exist for all active apps
                for app in newApps {
                    AudioTapManager.shared.ensureTapCreated(for: app.pid)
                }
            }
        }
        pendingUpdate = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    // -------------------------------------------------------------------------
    // MARK: - Icon Cache
    // Reading .icns files from disk on every poll cycle is expensive.
    // We cache NSImages by bundleIdentifier for fast memory lookup.
    // -------------------------------------------------------------------------
    nonisolated(unsafe) static var iconCache: [String: NSImage] = [:]
    private nonisolated static let iconCacheLock = NSLock()

    /// Retrieves an application's icon from memory cache or loads it from the application bundle.
    nonisolated private static func cachedIcon(for app: NSRunningApplication) -> NSImage? {
        guard let bundleID = app.bundleIdentifier else { return app.icon }
        iconCacheLock.lock()
        defer { iconCacheLock.unlock() }
        if let cached = iconCache[bundleID] {
            return cached
        }
        guard let icon = app.icon else { return nil }
        iconCache[bundleID] = icon
        return icon
    }

    /// Queries running GUI applications and cross-references them against active CoreAudio audio streams.
    /// - Parameter existingApps: Currently tracked apps (used to preserve user-adjusted volume sliders).
    /// - Returns: Sorted list of `AppVolume` instances representing audio-playing applications.
    nonisolated static func getRunningApps(existingApps: [AppVolume]) -> [AppVolume] {
        // Step 1: Query CoreAudio for all PIDs actively outputting audio
        let activeAudioPIDs = AudioTapManager.getAudioActivePIDs(onlyPlayingAudio: true)
        
        // Step 2: Query NSWorkspace for regular GUI applications (ignoring background daemons)
        let allRunning = NSWorkspace.shared.runningApplications
        let runningApps = allRunning.filter { app in
            let isRegular = app.activationPolicy == .regular
            let isActive = activeAudioPIDs.contains(app.processIdentifier)
            return isRegular && isActive
        }

        // Step 3: Construct AppVolume models preserving prior volume adjustments
        var newApps: [AppVolume] = []
        for app in runningApps {
            guard let name = app.localizedName,
                  let icon = cachedIcon(for: app) else { continue }

            let existingVolume = existingApps.first(where: { $0.pid == app.processIdentifier })?.volume ?? 1.0
            newApps.append(AppVolume(pid: app.processIdentifier, name: name, icon: icon, volume: existingVolume))
        }

        // Return alphabetically sorted list
        return newApps.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}

// =============================================================================
// MARK: - Main Volume Control View
// =============================================================================

/// `VolumeControlView` is the primary popover interface for MySound.
///
/// Sections:
/// - In-App Update Banner: Live progress when updating or prompt when a new version is found.
/// - Header: Output device picker, "Mute All" toggle, and Master System Volume slider.
/// - Permission Guidance Banner: Shown if System Audio Recording permission is not granted.
/// - Application Mixer List: Individual volume controls for each sound-producing app.
/// - Footer: Quit shortcut, version indicator, and Settings gear menu.
struct VolumeControlView: View {
    @State private var masterVolume: Double = 0.5
    @State private var previousMasterVolume: Double = 0.5
    @State private var isLaunchAtLogin: Bool = false
    @State private var savedAppVolumes: [Int32: Double] = [:]
    @State private var isQuitHovered: Bool = false
    @State private var isGearHovered: Bool = false
    @State private var hasPermission: Bool = true
    @State private var permissionCheckTimer: Timer?
    
    // CoreAudio property listener blocks for real-time master volume sync
    @State private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    @State private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    @EnvironmentObject private var appManager: AppManager
    @EnvironmentObject private var tapManager: AudioTapManager
    @EnvironmentObject private var updateManager: UpdateManager

    /// Returns `true` if all active applications are currently muted.
    private var isAllMuted: Bool {
        !appManager.apps.isEmpty && appManager.apps.allSatisfy { $0.volume <= 0.001 }
    }

    /// Toggles all applications between muted (0%) and their previously saved volumes.
    private func toggleMuteAll() {
        if isAllMuted {
            // Unmute: Restore previous volume or default to 100%
            for i in 0..<appManager.apps.count {
                let pid = appManager.apps[i].pid
                let restored = savedAppVolumes[pid] ?? 1.0
                appManager.apps[i].volume = restored > 0.001 ? restored : 1.0
                tapManager.setVolume(for: pid, volume: Float(appManager.apps[i].volume))
            }
        } else {
            // Mute All: Save current volumes and set all to 0
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
            // -----------------------------------------------------------------
            // MARK: Update Banner
            // -----------------------------------------------------------------
            if updateManager.isDownloading {
                // Active download progress
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
                // Update ready prompt button
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

            // -----------------------------------------------------------------
            // MARK: Header & Master Volume
            // -----------------------------------------------------------------
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Output device selection dropdown
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
                    
                    // Batch Mute / Unmute Button
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
                }

                // Master Volume Slider Row: [Device Icon] [Speaker Mute Button] [Slider] [Percentage]
                HStack(spacing: 6) {
                    // Device Icon
                    Image(systemName: deviceIconName(for: tapManager.currentOutputDevice?.name))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)

                    // Master Speaker Mute Button
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
                            .font(.system(size: 11))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(masterVolume <= 0.001 ? "Unmute system master volume" : "Mute system master volume")
                    
                    // Custom Master Volume Slider
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
                        // Double-click to set master volume to 100%
                        .onTapGesture(count: 2) {
                            masterVolume = 1.0
                            tapManager.setSystemVolume(1.0)
                        }
                    
                    // Percentage readout
                    Text("\(Int(masterVolume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(masterVolume <= 0.001 ? .secondary.opacity(0.5) : .secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .onAppear {
                masterVolume = Double(tapManager.getSystemVolume())
                if masterVolume > 0.001 {
                    previousMasterVolume = masterVolume
                }
                checkLaunchAtLoginStatus()
                hasPermission = AudioTapManager.hasAudioCapturePermission()
                
                // Set up event-driven CoreAudio property listeners for master volume
                setupVolumeListeners()
            }
            .onDisappear {
                // Remove listeners when the popover closes to conserve system resources
                removeVolumeListeners()
            }

            Divider()

            // -----------------------------------------------------------------
            // MARK: Permission Guidance Banner
            // -----------------------------------------------------------------
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

            // -----------------------------------------------------------------
            // MARK: App Volume Mixer List
            // -----------------------------------------------------------------
            VStack(spacing: 0) {
                if appManager.apps.isEmpty {
                    // Empty state when no app is playing sound
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
                    // List of apps currently producing sound
                    VStack(spacing: 4) {
                        ForEach($appManager.apps) { $app in
                            AppVolumeRow(app: $app) { newVolume in
                                tapManager.setVolume(for: app.pid, volume: newVolume)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .transition(.opacity)
                }
            }
            .frame(width: 300)
            .animation(.easeInOut(duration: 0.2), value: appManager.apps.map { $0.pid })
            .onAppear {
                hasPermission = AudioTapManager.hasAudioCapturePermission()
                let newApps = AppManager.getRunningApps(existingApps: appManager.apps)
                appManager.apps = newApps
                
                // Re-check permissions every 3 seconds so banner vanishes when user approves in Settings
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
                // Remove taps for terminated applications
                for pid in oldPids where !newPids.contains(pid) {
                    tapManager.removeTap(for: pid)
                }
            }

            Divider()

            // -----------------------------------------------------------------
            // MARK: Footer (Quit & Settings)
            // -----------------------------------------------------------------
            HStack(spacing: 8) {
                // Quit Button with Power Icon, ⌘Q Shortcut & Hover Effect
                Button(action: {
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

                // Settings Gear Menu
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
        // Observe system volume change notifications posted from CoreAudio property listeners
        .onReceive(NotificationCenter.default.publisher(for: .mySoundSystemVolumeChanged)) { notification in
            if let volume = notification.userInfo?["volume"] as? Double {
                if (volume <= 0.001) != (masterVolume <= 0.001) || abs(volume - masterVolume) > 0.005 {
                    masterVolume = volume
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: - Helper Methods
    // -------------------------------------------------------------------------

    /// Registers or unregisters the app with macOS ServiceManagement for Launch at Login.
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

    /// Queries the current Launch at Login registration status.
    private func checkLaunchAtLoginStatus() {
        isLaunchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Resolves an appropriate SF Symbol icon name based on the audio device name.
    private func deviceIconName(for name: String?) -> String {
        guard let name = name?.lowercased() else { return "laptopcomputer" }
        if name.contains("airpod") {
            return "airpodspro"
        } else if name.contains("headphone") || name.contains("headset") || name.contains("earphone") {
            return "headphones"
        } else if name.contains("hdmi") || name.contains("tv") || name.contains("displayport") || name.contains("monitor") {
            return "tv"
        } else if name.contains("homepod") {
            return "homepod.fill"
        } else if name.contains("studio") || name.contains("pro display") {
            return "display"
        } else if name.contains("imac") || name.contains("mac pro") || name.contains("mac mini") || name.contains("desktop") {
            return "desktopcomputer"
        } else {
            // Default built-in / MacBook Air / MacBook Pro speakers
            return "laptopcomputer"
        }
    }

    // MARK: - CoreAudio Volume/Mute Property Listeners
    // Event-driven callbacks replace polling timers, using zero CPU when idle.

    /// Registers CoreAudio HAL property listeners on the default output device for volume and mute state.
    private func setupVolumeListeners() {
        removeVolumeListeners() // Clean up any stale listeners

        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress, 0, nil, &propertySize, &defaultOutputDeviceID
        ) == noErr else { return }

        // Volume property listener
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(defaultOutputDeviceID, &volAddr) {
            volAddr.mElement = 1
        }
        let volBlock: AudioObjectPropertyListenerBlock = { [weak tapManager] _, _ in
            guard let tapManager = tapManager else { return }
            Task { @MainActor in
                let current = Double(tapManager.getSystemVolume())
                NotificationCenter.default.post(name: .mySoundSystemVolumeChanged, object: nil, userInfo: ["volume": current])
            }
        }
        AudioObjectAddPropertyListenerBlock(defaultOutputDeviceID, &volAddr, DispatchQueue.main, volBlock)
        volumeListenerBlock = volBlock

        // Mute property listener
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(defaultOutputDeviceID, &muteAddr) {
            muteAddr.mElement = 1
        }
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak tapManager] _, _ in
            guard let tapManager = tapManager else { return }
            Task { @MainActor in
                let current = Double(tapManager.getSystemVolume())
                NotificationCenter.default.post(name: .mySoundSystemVolumeChanged, object: nil, userInfo: ["volume": current])
            }
        }
        AudioObjectAddPropertyListenerBlock(defaultOutputDeviceID, &muteAddr, DispatchQueue.main, muteBlock)
        muteListenerBlock = muteBlock
    }

    /// Unregisters CoreAudio volume and mute property listeners.
    private func removeVolumeListeners() {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress, 0, nil, &propertySize, &defaultOutputDeviceID
        ) == noErr else { return }

        if let block = volumeListenerBlock {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(defaultOutputDeviceID, &volAddr, DispatchQueue.main, block)
            volAddr.mElement = 1
            AudioObjectRemovePropertyListenerBlock(defaultOutputDeviceID, &volAddr, DispatchQueue.main, block)
            volumeListenerBlock = nil
        }
        if let block = muteListenerBlock {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(defaultOutputDeviceID, &muteAddr, DispatchQueue.main, block)
            muteAddr.mElement = 1
            AudioObjectRemovePropertyListenerBlock(defaultOutputDeviceID, &muteAddr, DispatchQueue.main, block)
            muteListenerBlock = nil
        }
    }
}

// =============================================================================
// MARK: - App Volume Row
// =============================================================================

/// `AppVolumeRow` renders a minimal single-line application row with its icon on the side,
/// custom slider in the center, and percentage readout on the right.
struct AppVolumeRow: View {
    @Binding var app: AppVolume
    var onVolumeChange: (Float) -> Void
    @State private var previousVolume: Double = 0.5
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // Application Icon with Native Tooltip
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .opacity(app.volume <= 0.001 ? 0.4 : 1.0)
                .help(app.name)

            // Per-app Speaker Mute Button
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
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(app.volume <= 0.001 ? "Unmute \(app.name)" : "Mute \(app.name)")

            // Custom Application Volume Slider
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
                }
                .onChange(of: app.volume) { _, newValue in
                    if newValue > 0.001 {
                        previousVolume = newValue
                    }
                    onVolumeChange(Float(newValue))
                }
                // Double-click to set application volume to 100%
                .onTapGesture(count: 2) {
                    app.volume = 1.0
                    onVolumeChange(1.0)
                }

            // Percentage readout
            Text("\(Int(app.volume * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundColor(app.volume <= 0.001 ? .secondary.opacity(0.5) : .secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .help(app.name)
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

// =============================================================================
// MARK: - Custom macOS Boxy Slider Component
// =============================================================================

/// `BoxySlider` is a custom SwiftUI slider styled to match modern macOS system sliders:
/// - Ultra-thin horizontal track.
/// - Rounded capsule thumb handle with subtle drop shadow and hover outline.
/// - Smooth drag gesture with snap-to-edge boundaries.
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
                // Background Track (Inactive Bar)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: trackHeight)

                // Filled Track (Active Color Bar)
                Rectangle()
                    .fill(tint)
                    .frame(width: fillWidth, height: trackHeight)

                // Horizontal Pill / Capsule Thumb Handle
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
                        // Snap to clean 0% or 100% near edges
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

// =============================================================================
// MARK: - Native Frosted Glass Visual Effect
// =============================================================================

/// `VisualEffectView` bridges AppKit's `NSVisualEffectView` to SwiftUI, providing native macOS
/// frosted-glass popover materials and translucency behind the window.
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

