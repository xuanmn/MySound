import SwiftUI
import AppKit
import ServiceManagement
import CoreAudio
import Combine

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
            Task { @MainActor [weak self] in
                self?.updateApps()
            }
        }
    }

    deinit {
        // Invalidate timer to prevent execution after deallocation
        timer?.invalidate()
        // Remove NSWorkspace notification observers
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
    // We cache NSImages by bundleIdentifier for fast memory lookup using NSCache.
    // -------------------------------------------------------------------------
    private nonisolated static let iconCache: SendableCache<NSString, NSImage> = {
        let cache = SendableCache<NSString, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    /// Retrieves an application's icon from memory cache or loads it from the application bundle.
    nonisolated private static func cachedIcon(for app: NSRunningApplication) -> NSImage? {
        guard let bundleID = app.bundleIdentifier else { return app.icon }
        let key = bundleID as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        guard let icon = app.icon else { return nil }
        iconCache.setObject(icon, forKey: key)
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
    @State private var isSettingsPresented: Bool = false
    @State private var isMasterMuteHovered: Bool = false
    @State private var hasPermission: Bool = true
    @State private var permissionCheckTimer: Timer?
    
    // CoreAudio property listener blocks for real-time master volume sync
    @State private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    @State private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    /// Tracks the device ID on which volume/mute listeners were registered,
    /// so removal targets the correct device even after an output switch.
    @State private var listenedDeviceID: AudioDeviceID = 0

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

    /// Resets all tracked applications to 100% volume.
    private func resetAllAppVolumes() {
        withAnimation(.easeInOut(duration: 0.15)) {
            for i in 0..<appManager.apps.count {
                appManager.apps[i].volume = 1.0
                tapManager.setVolume(for: appManager.apps[i].pid, volume: 1.0)
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
            // MARK: Header & Master Volume (Wrapping Flow Capsules)
            // -----------------------------------------------------------------
            VStack(alignment: .leading, spacing: 8) {
                // Top Row: Dynamic 1-Click Selectable Wrapping Device Capsules & Mute All
                HStack(alignment: .top, spacing: 6) {
                    WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
                        if tapManager.availableOutputDevices.isEmpty {
                            OutputDeviceChip(
                                device: tapManager.currentOutputDevice ?? AudioOutputDevice(id: 0, name: "Output Device", uid: "default"),
                                isSelected: true,
                                onSelect: {}
                            )
                        } else {
                            ForEach(tapManager.availableOutputDevices) { device in
                                OutputDeviceChip(
                                    device: device,
                                    isSelected: tapManager.currentOutputDevice?.id == device.id,
                                    onSelect: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            tapManager.setDefaultOutputDevice(device)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !appManager.apps.isEmpty {
                        Button(action: toggleMuteAll) {
                            Text(isAllMuted ? "Unmute All" : "Mute All")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isAllMuted ? "Unmute all running applications" : "Mute all running applications")
                    }
                }
                .padding(.horizontal, 4)

                // Master Volume Slider Row: [Speaker Mute Button] [Slider] [Percentage]
                HStack(spacing: 8) {
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
                            .foregroundColor(masterVolume <= 0.001 ? .red : (isMasterMuteHovered ? .primary : .secondary))
                            .font(.system(size: 12))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isMasterMuteHovered = hovering
                        }
                    }
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

                    // Editable percentage readout (click-to-type & hover scroll)
                    EditableVolumeText(
                        volume: $masterVolume,
                        onVolumeChange: { newVol in
                            if newVol > 0.001 {
                                previousMasterVolume = newVol
                            }
                            tapManager.setSystemVolume(Float(newVol))
                        },
                        isMuted: masterVolume <= 0.001
                    )
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
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
                    if appManager.apps.count <= 6 {
                        VStack(spacing: 3) {
                            ForEach($appManager.apps) { $app in
                                AppVolumeRow(app: $app) { newVolume in
                                    tapManager.setVolume(for: app.pid, volume: newVolume)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 3) {
                                ForEach($appManager.apps) { $app in
                                    AppVolumeRow(app: $app) { newVolume in
                                        tapManager.setVolume(for: app.pid, volume: newVolume)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 280)
                        .transition(.opacity)
                    }
                }
            }
            .frame(width: 330)
            .animation(.easeInOut(duration: 0.2), value: appManager.apps.map { $0.pid })
            .onAppear {
                hasPermission = AudioTapManager.hasAudioCapturePermission()
                let newApps = AppManager.getRunningApps(existingApps: appManager.apps)
                appManager.apps = newApps
                
                // Re-check permissions every 3 seconds only if permission is missing
                permissionCheckTimer?.invalidate()
                if !hasPermission {
                    permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { timer in
                        Task { @MainActor in
                            let granted = AudioTapManager.hasAudioCapturePermission()
                            hasPermission = granted
                            if granted {
                                timer.invalidate()
                            }
                        }
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

                // Version Badge (reads dynamically from Info.plist stamped from version.json)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))
                }

                // Settings Gear Button with Popover
                Button(action: {
                    isSettingsPresented.toggle()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isGearHovered || isSettingsPresented ? .primary : .secondary)
                        .padding(6)
                        .background(isGearHovered || isSettingsPresented ? Color.primary.opacity(0.12) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isGearHovered = hovering
                    }
                }
                .popover(isPresented: $isSettingsPresented, arrowEdge: .top) {
                    QuickSettingsPopoverView(
                        isLaunchAtLogin: $isLaunchAtLogin,
                        onToggleLaunchAtLogin: { newValue in
                            toggleLaunchAtLogin(newValue)
                        },
                        hasPermission: hasPermission,
                        onResetVolumes: {
                            resetAllAppVolumes()
                        }
                    )
                    .environmentObject(updateManager)
                    .preferredColorScheme(.dark)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .frame(width: 330)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .preferredColorScheme(.dark)
        // Observe system volume change notifications posted from CoreAudio property listeners
        .onReceive(NotificationCenter.default.publisher(for: .mySoundSystemVolumeChanged)) { notification in
            if let volume = notification.userInfo?["volume"] as? Double {
                if (volume <= 0.001) != (masterVolume <= 0.001) || abs(volume - masterVolume) > 0.005 {
                    masterVolume = volume
                }
            }
        }
        // Re-register volume listeners when the default output device changes
        .onChange(of: tapManager.currentOutputDevice?.id) { _, _ in
            setupVolumeListeners()
            masterVolume = Double(tapManager.getSystemVolume())
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

    // MARK: - CoreAudio Volume/Mute Property Listeners
    // Event-driven callbacks replace polling timers, using zero CPU when idle.

    /// Registers CoreAudio HAL property listeners on the default output device for volume and mute state.
    private func setupVolumeListeners() {
        removeVolumeListeners() // Clean up any stale listeners on the previously tracked device

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

        // Store the device ID so removeVolumeListeners() targets the correct device
        listenedDeviceID = defaultOutputDeviceID

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

    /// Unregisters CoreAudio volume and mute property listeners from the device they were registered on.
    private func removeVolumeListeners() {
        let deviceID = listenedDeviceID
        guard deviceID != 0 else { return }

        if let block = volumeListenerBlock {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            // Remove from Main element; if the device exposes channel 1 instead, remove there too
            AudioObjectRemovePropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main, block)
            volAddr.mElement = 1
            if AudioObjectHasProperty(deviceID, &volAddr) {
                AudioObjectRemovePropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main, block)
            }
            volumeListenerBlock = nil
        }
        if let block = muteListenerBlock {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, block)
            muteAddr.mElement = 1
            if AudioObjectHasProperty(deviceID, &muteAddr) {
                AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, block)
            }
            muteListenerBlock = nil
        }
        listenedDeviceID = 0
    }
}

// =============================================================================
// MARK: - Wrapping HStack Layout
// =============================================================================

/// A custom SwiftUI `Layout` that arranges subviews horizontally and wraps to subsequent lines
/// when available horizontal width is exceeded.
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 330
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if currentX + itemWidth > width && currentX > 0 {
                maxRowWidth = max(maxRowWidth, currentX - horizontalSpacing)
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            currentX += itemWidth + horizontalSpacing
        }
        maxRowWidth = max(maxRowWidth, currentX > 0 ? currentX - horizontalSpacing : 0)

        return CGSize(width: min(width, maxRowWidth), height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, bounds.width)
            if currentX + itemWidth > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(width: itemWidth, height: size.height))
            lineHeight = max(lineHeight, size.height)
            currentX += itemWidth + horizontalSpacing
        }
    }
}

// =============================================================================
// MARK: - Output Device Chip
// =============================================================================

/// `OutputDeviceChip` renders an individual interactive output device capsule button
/// with device-specific SF Symbol, localized device name, active state indicator,
/// and smooth hover brightening.
struct OutputDeviceChip: View {
    let device: AudioOutputDevice
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(systemName: device.iconName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .primary : (isHovered ? .primary : .secondary))

                Text(device.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.14) : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(device.name)\(isSelected ? ", currently active" : ", click to select")")
    }
}

// =============================================================================
// MARK: - App Volume Row
// =============================================================================

/// `AppVolumeRow` renders a polished 1-line application row with its icon, localized app name,
/// real-time audio activity wave indicator, per-app speaker mute button, custom slider, and percentage readout.
struct AppVolumeRow: View {
    @Binding var app: AppVolume
    var onVolumeChange: (Float) -> Void
    @State private var previousVolume: Double = 0.5
    @State private var isHovered: Bool = false
    @State private var isPlayingAudio: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            // Application Icon with Native Tooltip
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .cornerRadius(3)
                .opacity(app.volume <= 0.001 ? 0.4 : 1.0)
                .help(app.name)

            // Localized Application Name (fixed width ensures uniform slider alignment)
            Text(app.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(app.volume <= 0.001 ? .secondary.opacity(0.6) : .primary)
                .frame(width: 74, alignment: .leading)
                .help(app.name)

            // Live Audio Activity Waveform (shows when process produces audible sound)
            Image(systemName: "waveform")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(app.volume <= 0.001 ? .secondary.opacity(0.3) : .blue)
                .opacity(isPlayingAudio && app.volume > 0.001 ? 0.9 : 0.0)
                .frame(width: 12)
                .help(isPlayingAudio ? "\(app.name) is currently playing audio" : "")

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

            // Editable percentage readout (click-to-type & hover scroll)
            EditableVolumeText(
                volume: $app.volume,
                onVolumeChange: { newVol in
                    if newVol > 0.001 {
                        previousVolume = newVol
                    }
                    onVolumeChange(Float(newVol))
                },
                isMuted: app.volume <= 0.001
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
            checkAudioActivity()
        }
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            checkAudioActivity()
        }
    }

    private func checkAudioActivity() {
        let active = AudioTapManager.activityTracker.isAudioActive(for: app.pid, window: 1.2)
        if active != isPlayingAudio {
            withAnimation(.easeInOut(duration: 0.2)) {
                isPlayingAudio = active
            }
        }
    }
}

// =============================================================================
// MARK: - Editable Volume Text & Scroll Wheel Component
// =============================================================================

/// `ScrollWheelReceiverView` is an AppKit NSView that captures scroll wheel deltas and clicks,
/// and automatically sets a pointing hand cursor on hover.
final class ScrollWheelReceiverView: NSView {
    var onScroll: ((Double) -> Void)?
    var onClick: (() -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.02 {
            let change: Double
            if event.hasPreciseScrollingDeltas {
                change = Double(delta) * 0.003
            } else {
                change = delta > 0 ? 0.02 : -0.02
            }
            onScroll?(change)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Bridges `ScrollWheelReceiverView` into SwiftUI.
struct ScrollWheelListener: NSViewRepresentable {
    var onScroll: (Double) -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> ScrollWheelReceiverView {
        let view = ScrollWheelReceiverView()
        view.onScroll = onScroll
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ScrollWheelReceiverView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onClick = onClick
    }
}

/// `EditableVolumeText` displays the volume percentage readout and allows users to:
/// 1. Hover to reveal a subtle interactive badge with pointing hand cursor.
/// 2. Scroll with trackpad or mouse wheel to scrub volume smoothly.
/// 3. Click to open an inline numeric text field and type any exact percentage (0-100).
struct EditableVolumeText: View {
    @Binding var volume: Double
    var onVolumeChange: (Double) -> Void
    var isMuted: Bool = false

    @State private var isHovered: Bool = false
    @State private var isEditing: Bool = false
    @State private var textInput: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            if isEditing {
                // Inline Numeric Input Field
                HStack(spacing: 0) {
                    TextField("", text: $textInput)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .frame(width: 24)
                        .focused($isFocused)
                        .onChange(of: textInput) { _, newValue in
                            let digits = newValue.filter { $0.isNumber }
                            if digits != newValue {
                                textInput = String(digits.prefix(3))
                            }
                        }
                        .onSubmit {
                            commitEdit()
                        }
                        .onExitCommand {
                            cancelEdit()
                        }
                    Text("%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.blue, lineWidth: 1.2)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
            } else {
                // Formatted Percentage Readout with Scroll & Click Interceptor
                HStack(spacing: 0) {
                    Text("\(Int(round(volume * 100)))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(isMuted || volume <= 0.001 ? .secondary.opacity(0.5) : (isHovered ? .primary : .secondary))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.white.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isHovered ? Color.white.opacity(0.18) : Color.clear, lineWidth: 0.5)
                )
                .overlay(
                    ScrollWheelListener(
                        onScroll: { change in
                            let newVol = min(1.0, max(0.0, volume + change))
                            volume = newVol
                            onVolumeChange(newVol)
                        },
                        onClick: {
                            startEditing()
                        }
                    )
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
                .help("Click to type (0–100%) or scroll to adjust")
            }
        }
        .frame(width: 36, height: 20, alignment: .trailing)
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditing {
                commitEdit()
            }
        }
    }

    private func startEditing() {
        textInput = "\(Int(round(volume * 100)))"
        isEditing = true
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func commitEdit() {
        let sanitized = textInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        if let intVal = Int(sanitized) {
            let clamped = min(100, max(0, intVal))
            let newVol = Double(clamped) / 100.0
            volume = newVol
            onVolumeChange(newVol)
        }
        isEditing = false
        isFocused = false
    }

    private func cancelEdit() {
        isEditing = false
        isFocused = false
    }
}

// =============================================================================
// MARK: - Custom macOS Boxy Slider Component
// =============================================================================

/// `BoxySlider` is a custom SwiftUI slider styled to match modern macOS system sliders:
/// - 4px continuous capsule horizontal track.
/// - Circular adaptive macOS knob handle with subtle drop shadow, hover brightening, and scale-on-drag physics.
/// - Smooth drag gesture with snap-to-edge boundaries.
struct BoxySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .blue
    var trackHeight: CGFloat = 4
    var thumbSize: CGFloat = 13

    @State private var isHovered: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let usableWidth = max(totalWidth - thumbSize, 1)
            let percent = max(0, min(1, CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))))
            let thumbX = percent * usableWidth
            let fillWidth = max(trackHeight, percent * usableWidth + (thumbSize / 2))

            ZStack(alignment: .leading) {
                // Background Track (Inactive Bar)
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)

                // Filled Track (Active Color Bar)
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: fillWidth, height: trackHeight)

                // Circular Dark Mode Knob Handle
                Circle()
                    .fill(Color(white: 0.92))
                    .overlay(
                        Circle()
                            .stroke(isDragging || isHovered ? tint : Color.black.opacity(0.2), lineWidth: isDragging ? 1.5 : 1)
                    )
                    .shadow(color: Color.black.opacity(isDragging ? 0.35 : 0.2), radius: isDragging ? 2.5 : 1.5, x: 0, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .scaleEffect(isDragging ? 1.15 : (isHovered ? 1.08 : 1.0))
                    .animation(.easeInOut(duration: 0.12), value: isDragging)
                    .animation(.easeInOut(duration: 0.12), value: isHovered)
                    .offset(x: thumbX)
            }
            .frame(height: max(thumbSize + 4, 18), alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let locationX = gesture.location.x - (thumbSize / 2)
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
        .frame(height: max(thumbSize + 4, 18))
    }
}

// =============================================================================
// MARK: - Quick Settings Floating Popover View
// =============================================================================

/// `QuickSettingsPopoverView` renders a floating macOS settings card anchored above the gear button.
struct QuickSettingsPopoverView: View {
    @Binding var isLaunchAtLogin: Bool
    var onToggleLaunchAtLogin: (Bool) -> Void
    var hasPermission: Bool
    var onResetVolumes: () -> Void

    @EnvironmentObject private var updateManager: UpdateManager
    @State private var didReset: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Settings")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.bottom, 2)

            Divider()

            // General Preferences
            Toggle(isOn: $isLaunchAtLogin) {
                Text("Launch at Login")
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: isLaunchAtLogin) { _, newValue in
                onToggleLaunchAtLogin(newValue)
            }

            Divider()

            // Quick Actions & Permissions
            VStack(spacing: 6) {
                // Reset App Volumes Button
                Button(action: {
                    onResetVolumes()
                    withAnimation { didReset = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { didReset = false }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: didReset ? "checkmark" : "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(didReset ? .green : .secondary)
                            .frame(width: 14)
                        Text(didReset ? "Volumes Reset to 100%" : "Reset App Volumes to 100%")
                            .font(.system(size: 11))
                            .foregroundColor(didReset ? .green : .primary)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Permissions Status & Link
                Button(action: {
                    AudioTapManager.openSystemAudioPermissionSettings()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: hasPermission ? "checkmark.shield.fill" : "lock.shield.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(hasPermission ? .green : .orange)
                            .frame(width: 14)
                        Text("System Audio Permission")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Updates & GitHub
            VStack(spacing: 6) {
                Button(action: {
                    updateManager.checkForUpdates(manual: true)
                }) {
                    HStack(spacing: 6) {
                        if updateManager.isChecking {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                        }
                        Text(updateManager.isChecking ? "Checking for Updates..." : "Check for Updates...")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(updateManager.isChecking || updateManager.isDownloading)

                if let url = URL(string: "https://github.com/xuanmn/MySound") {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                            Text("GitHub Repository")
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 220)
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
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}

// =============================================================================
// MARK: - Thread-Safe Sendable Cache Wrapper
// =============================================================================

/// `SendableCache` wraps `NSCache` to satisfy `Sendable` in Swift 6 strict concurrency mode.
/// `NSCache` is internally thread-safe (documented by Apple), so `@unchecked Sendable` is correct.
final class SendableCache<KeyType: AnyObject, ObjectType: AnyObject>: @unchecked Sendable {
    private let cache = NSCache<KeyType, ObjectType>()

    /// Maximum number of objects the cache should hold.
    var countLimit: Int {
        get { cache.countLimit }
        set { cache.countLimit = newValue }
    }

    func object(forKey key: KeyType) -> ObjectType? {
        cache.object(forKey: key)
    }

    func setObject(_ obj: ObjectType, forKey key: KeyType) {
        cache.setObject(obj, forKey: key)
    }
}
