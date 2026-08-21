import Foundation
import CoreAudio
import AppKit
import CoreGraphics
import Accelerate

// =============================================================================
// MARK: - Private CoreAudio Process Tap C SPI (macOS 14.2+)
// =============================================================================
//
// In macOS Sonoma (14.2+), Apple introduced private CoreAudio APIs for Process Taps.
// A Process Tap allows an application with the "System Audio Recording" permission
// to intercept the audio output stream of specific processes (by AudioObjectID)
// and mute/redirect them into a custom CoreAudio Aggregate Device.
//
// Because these C functions are private SPIs (System Programming Interfaces),
// we declare them using Swift's `@_silgen_name` to link directly against CoreAudio.framework.

#if canImport(CoreAudio)
/// Creates an audio tap targeting one or more process audio object IDs.
/// - Parameters:
///   - description: Configuration including process object IDs, mute behavior, and private flags.
///   - tapID: Pointer to receive the allocated AudioObjectID for the tap.
@_silgen_name("AudioHardwareCreateProcessTap")
func AudioHardwareCreateProcessTap(_ description: CATapDescription, _ tapID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus

/// Destroys a previously created process tap.
/// - Parameter tapID: The AudioObjectID of the tap to destroy.
@_silgen_name("AudioHardwareDestroyProcessTap")
func AudioHardwareDestroyProcessTap(_ tapID: AudioObjectID) -> OSStatus

/// Creates a virtual Aggregate Device that binds the process tap input to the physical hardware output.
/// - Parameters:
///   - inDescription: CFDictionary containing keys for sub-devices, taps, clock sync, and drift compensation.
///   - outDeviceID: Pointer to receive the allocated AudioObjectID for the aggregate device.
@_silgen_name("AudioHardwareCreateAggregateDevice")
func AudioHardwareCreateAggregateDevice(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus

/// Destroys a previously created aggregate device.
/// - Parameter inDeviceID: The AudioObjectID of the aggregate device to destroy.
@_silgen_name("AudioHardwareDestroyAggregateDevice")
func AudioHardwareDestroyAggregateDevice(_ inDeviceID: AudioObjectID) -> OSStatus
#endif



// =============================================================================
// MARK: - Audio Tap Manager
// =============================================================================

/// `AudioTapManager` is the core audio engine of MySound.
///
/// Responsibilities:
/// 1. Intercepting per-app audio using private CoreAudio Process Taps (`CATapDescription`).
/// 2. Creating Aggregate Devices linking intercepted taps back to physical output devices.
/// 3. Applying real-time DSP gain scaling (`vDSP_vsmul`) per buffer in the audio IO callback.
/// 4. Listening for hardware changes (default device switches, audio process life cycles).
/// 5. Controlling global master volume and system mute states.
@MainActor
class AudioTapManager: NSObject, ObservableObject {
    /// Shared singleton instance.
    static let shared = AudioTapManager()

    /// Holds the active CoreAudio resources associated with an intercepted application.
    struct TapState {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        let objectIDs: [AudioObjectID]
        let createdAt: CFAbsoluteTime
    }

    /// Map of active process taps keyed by PID.
    @Published var activeTaps: [pid_t: TapState] = [:]
    /// Currently selected default output device.
    @Published var currentOutputDevice: AudioOutputDevice?
    /// List of all detected output-capable audio devices on the system.
    @Published var availableOutputDevices: [AudioOutputDevice] = []

    /// Dynamically resolved pointer to private `responsibility_get_pid_responsible_for_pid` symbol in libproc.
    /// This allows mapping sandboxed helper processes (like Chrome Helper or Safari WebContent) to their parent app.
    private nonisolated static let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Lock-protected volume lookup table shared with real-time audio threads.
    let volumeStore = VolumeStore()
    /// Lock-protected activity tracker for visual audio waveform indicators.
    nonisolated static let activityTracker = AudioActivityTracker()

    // MARK: - Permissions

    /// Determines whether MySound has been granted System Audio Recording / TCC permission.
    ///
    /// Why query `kAudioHardwarePropertyProcessObjectList`?
    /// - `CGPreflightScreenCaptureAccess()` only checks Screen Capture TCC, NOT System Audio Recording TCC.
    /// - On macOS 14.2+, querying the hardware process object list succeeds and returns entries only when TCC is authorized.
    nonisolated static func hasAudioCapturePermission() -> Bool {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &processListSize
        )
        if status == noErr && processListSize > 0 {
            let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
            return count > 0
        }
        return false
    }

    /// Opens the appropriate System Settings Privacy pane for granting System Audio Recording permissions.
    nonisolated static func openSystemAudioPermissionSettings() {
        // macOS 15+ has a dedicated "System Audio Recording Only" privacy pane
        if #available(macOS 15.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        // macOS 14 groups System Audio Recording under "Screen & System Audio Recording"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Listener Addresses & Blocks
    private var processListListenerAddress: AudioObjectPropertyAddress?
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputDeviceListenerAddress: AudioObjectPropertyAddress?
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var hardwareDevicesListenerAddress: AudioObjectPropertyAddress?
    private var hardwareDevicesListenerBlock: AudioObjectPropertyListenerBlock?

    private var cleanupTimer: Timer?

    override init() {
        super.init()
        setupProcessListListener()
        refreshOutputDevices()
        setupHardwareListeners()
        setupCleanupTimer()
    }

    // MARK: - Periodic Cleanup

    /// Periodically cleans up taps for applications that have exited or stopped playing audio.
    private func setupCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupInactiveTaps()
            }
        }
    }

    /// Evaluates active taps and tears down any whose apps are closed or inactive.
    func cleanupInactiveTaps() {
        let now = CFAbsoluteTimeGetCurrent()
        var seenTapIDs = Set<AudioObjectID>()
        let currentActivePIDs = Array(activeTaps.keys)
        for pid in currentActivePIDs {
            guard let state = activeTaps[pid] else { continue }
            // Skip if we already evaluated this tap (shared between helper PID and main app PID)
            guard seenTapIDs.insert(state.tapID).inserted else { continue }
            
            // Give newly created taps a 5-second grace period before cleanup can touch them.
            // On Intel Macs, the aggregate device IO proc can take 1-3 seconds to start receiving audio buffers.
            let age = now - state.createdAt
            if age < 5.0 { continue }
            
            let isRunning = NSRunningApplication(processIdentifier: pid) != nil
            let isActive = Self.activityTracker.isAudioActive(for: pid, window: 3.0)
            if !isRunning || !isActive {
                removeTap(for: pid)
            }
        }
    }

    // MARK: - Process Responsibility Resolution

    /// Maps a given PID (which might be a helper sub-process) to its main top-level GUI application PID.
    ///
    /// Multi-process apps like Google Chrome, Discord, or Spotify play sound from helper processes.
    /// This method traverses the responsibility tree and bundle paths so volume sliders map correctly.
    func getMainAppPID(for targetPID: pid_t) -> pid_t {
        // Direct regular application match
        if let app = NSRunningApplication(processIdentifier: targetPID), app.activationPolicy == .regular {
            return targetPID
        }
        // Check LaunchServices responsible PID via SPI
        if let respPID = Self.getResponsiblePID?(targetPID), let app = NSRunningApplication(processIdentifier: respPID), app.activationPolicy == .regular {
            return respPID
        }
        // Fallback: match binary path against running application bundle paths
        if let procPath = Self.getPath(for: targetPID) {
            for app in NSWorkspace.shared.runningApplications {
                if app.activationPolicy == .regular, let bundlePath = app.bundleURL?.path, procPath.hasPrefix(bundlePath) {
                    return app.processIdentifier
                }
            }
        }
        return targetPID
    }

    // MARK: - CoreAudio HAL Event Listeners

    /// Registers a listener for system-wide process list changes (`kAudioHardwarePropertyProcessObjectList`).
    private func setupProcessListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Store block reference so deinit can unregister the exact same pointer
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshActiveTaps()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        processListListenerAddress = address
        processListListenerBlock = block
    }

    /// Registers listeners for default output device changes and hardware device plug/unplug events.
    private func setupHardwareListeners() {
        // Default output device change listener
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshOutputDevices()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevAddr, DispatchQueue.main, outputBlock)
        outputDeviceListenerAddress = defaultDevAddr
        outputDeviceListenerBlock = outputBlock

        // Hardware device list change listener (e.g. connecting headphones or DAC)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshOutputDevices()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock)
        hardwareDevicesListenerAddress = devicesAddr
        hardwareDevicesListenerBlock = devicesBlock
    }

    /// Refreshes available output devices and recreates taps if the active output device changed.
    func refreshOutputDevices() {
        let devices = getAvailableOutputDevices()
        let current = getDefaultOutputDevice()
        let deviceChanged = self.currentOutputDevice?.uid != current?.uid
        self.availableOutputDevices = devices
        self.currentOutputDevice = current
        if deviceChanged && current != nil {
            // Re-bind all active taps to the new physical output device
            recreateAllTaps()
        }
    }

    /// Destroys and recreates all process taps (e.g. when switching from Speakers to Headphones).
    func recreateAllTaps() {
        let currentPIDs = Array(activeTaps.keys)
        removeAllTaps()
        for pid in currentPIDs {
            createTap(for: pid)
        }
    }

    /// Checks active taps to see if underlying AudioObjectIDs have changed (e.g. app reopened a stream).
    private func refreshActiveTaps() {
        for (pid, state) in activeTaps {
            let currentObjectIDs = getAudioObjectIDs(for: pid)
            if Set(currentObjectIDs) != Set(state.objectIDs) && !currentObjectIDs.isEmpty {
                removeTap(for: pid)
                createTap(for: pid)
            }
        }
    }

    // MARK: - Tap & Volume Management

    /// Ensures a tap is created for a given PID if not already established.
    func ensureTapCreated(for targetPID: pid_t) {
        let pid = getMainAppPID(for: targetPID)
        if activeTaps[pid] == nil && activeTaps[targetPID] == nil {
            createTap(for: targetPID)
        }
    }

    /// Updates the volume multiplier (0.0...1.0) for a target application PID.
    func setVolume(for targetPID: pid_t, volume: Float) {
        let mainPID = getMainAppPID(for: targetPID)
        volumeStore.set(mainPID, volume)
        volumeStore.set(targetPID, volume)

        if activeTaps[mainPID] == nil && activeTaps[targetPID] == nil {
            createTap(for: targetPID)
        }
    }

    // MARK: - Tap Creation Engine

    /// Creates and activates a Process Tap + Aggregate Device pipeline for the target PID.
    ///
    /// Pipeline Architecture:
    /// 1. `CATapDescription`: Identifies the target process's AudioObjectIDs and sets mute behavior.
    /// 2. `AudioHardwareCreateProcessTap`: Hooks into the CoreAudio HAL server.
    /// 3. `AudioHardwareCreateAggregateDevice`: Creates a virtual output device linking the tap input
    ///    to the physical output device with clock sync and drift compensation.
    /// 4. `AudioDeviceCreateIOProcIDWithBlock`: Attaches an IO callback where audio samples are received,
    ///    multiplied by the volume scalar using Accelerate SIMD (`vDSP_vsmul`), and sent to the speakers.
    /// 5. `AudioDeviceStart`: Starts the audio rendering clock on the aggregate device.
    private func createTap(for targetPID: pid_t) {
        guard #available(macOS 14.2, *) else {
            AppLogger.shared.log("Process taps require macOS 14.2 or later.")
            return
        }
        let pid = getMainAppPID(for: targetPID)
        if activeTaps[pid] != nil || activeTaps[targetPID] != nil { return }

        guard let outputDeviceUID = getDefaultOutputDeviceUID() else {
            AppLogger.shared.log("Could not get default output device UID for PID \(pid)")
            return
        }

        let objectIDs = getAudioObjectIDs(for: targetPID)
        AppLogger.shared.log("createTap for PID \(targetPID) (main PID \(pid)) -> found \(objectIDs.count) AudioObjectIDs")
        guard !objectIDs.isEmpty else {
            AppLogger.shared.log("No AudioObjectIDs found for PID \(targetPID) (main PID \(pid)). Tap creation skipped.")
            return
        }

        // Prevent duplicate tap creation on object IDs already being processed
        let allTappedObjectIDs = Set(activeTaps.values.flatMap { $0.objectIDs })
        if !Set(objectIDs).isDisjoint(with: allTappedObjectIDs) {
            AppLogger.shared.log("Skipping tap for PID \(targetPID) - objectIDs already tapped.")
            return
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.deviceUID = outputDeviceUID

        var tapID: AudioObjectID = 0
        var status: OSStatus = -1

        // ---------------------------------------------------------------------
        // Cascading Tap Creation Strategy:
        // Stage 1: .muted + isPrivate (Optimal — silences original audio at source, routes solely through IO proc)
        // Stage 2: .muted + !isPrivate (Fallback for systems where private taps are restricted)
        // Stage 3: .unmuted + isPrivate (Fallback for certain audio drivers)
        // Stage 4: .unmuted + !isPrivate (Permissive fallback)
        // ---------------------------------------------------------------------
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true
        status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        if status != noErr {
            AppLogger.shared.log("Tap creation failed (status \(status)) with muted+private")
            tapDescription.isPrivate = false
            status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        }
        if status != noErr {
            AppLogger.shared.log("Tap creation failed (status \(status)) with muted+public")
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        }
        if status != noErr {
            AppLogger.shared.log("Tap creation failed (status \(status)) with unmuted+private")
            tapDescription.isPrivate = false
            status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        }

        guard status == noErr else {
            AppLogger.shared.log("All AudioHardwareCreateProcessTap attempts failed for PID \(targetPID) (final status: \(status))")
            return
        }
        AppLogger.shared.log("AudioHardwareCreateProcessTap succeeded for PID \(targetPID) (mute=\(tapDescription.muteBehavior.rawValue), private=\(tapDescription.isPrivate))")

        // ---------------------------------------------------------------------
        // Aggregate Device Descriptor:
        // Combines the physical sub-device and the tap sub-tap into a single clock domain.
        // ---------------------------------------------------------------------
        let aggUID = UUID().uuidString
        var aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MySound-Tap-\(pid)" as NSString,
            kAudioAggregateDeviceUIDKey: aggUID as NSString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID as NSString,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID as NSString,
            kAudioAggregateDeviceIsPrivateKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceIsStackedKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceTapAutoStartKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID as NSString, kAudioSubDeviceDriftCompensationKey: kCFBooleanTrue as Any]
            ] as NSArray,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString as NSString]
            ] as NSArray
        ]

        var aggID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)

        // Cascading aggregate fallbacks for compatibility across Intel Macs & differing macOS versions
        if status != noErr {
            AppLogger.shared.log("Aggregate stage 1 failed (status \(status)), retrying without TapAutoStartKey...")
            aggregateDesc.removeValue(forKey: kAudioAggregateDeviceTapAutoStartKey)
            status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        }

        if status != noErr {
            AppLogger.shared.log("Aggregate stage 2 failed (status \(status)), retrying without DriftCompensation...")
            aggregateDesc[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputDeviceUID as NSString]
            ] as NSArray
            status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        }

        if status != noErr {
            AppLogger.shared.log("Aggregate stage 3 failed (status \(status)), retrying without IsStacked...")
            aggregateDesc.removeValue(forKey: kAudioAggregateDeviceIsStackedKey)
            status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        }

        if status != noErr {
            AppLogger.shared.log("Aggregate stage 4 failed (status \(status)), retrying without IsPrivate...")
            aggregateDesc.removeValue(forKey: kAudioAggregateDeviceIsPrivateKey)
            status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        }

        guard status == noErr else {
            AppLogger.shared.log("All aggregate device creation attempts failed for PID \(pid) with final status: \(status)")
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }
        AppLogger.shared.log("Aggregate device created successfully for PID \(pid) (aggID: \(aggID))")

        // Standardize aggregate input format to 32-bit Float Linear PCM
        var currentFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(aggID, &formatAddr, 0, nil, &formatSize, &currentFormat) == noErr {
            var float32Format = AudioStreamBasicDescription(
                mSampleRate: currentFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: currentFormat.mChannelsPerFrame > 0 ? currentFormat.mChannelsPerFrame : 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            let setStatus = AudioObjectSetPropertyData(aggID, &formatAddr, 0, nil, formatSize, &float32Format)
            if setStatus != noErr {
                AppLogger.shared.log("Warning — could not force Float32 format on aggregate input (status \(setStatus)).")
            }
        }

        // ---------------------------------------------------------------------
        // Real-Time Audio IO Callback:
        // Executed by CoreAudio on a dedicated real-time high-priority thread.
        // ---------------------------------------------------------------------
        let volumeStore = self.volumeStore
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { (now, inputData, inputTime, outputData, outputTime) in
            // Read volume multiplier safely from lock-protected store
            let vol = min(volumeStore.get(pid), volumeStore.get(targetPID))

            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            guard !inputs.isEmpty && !outputs.isEmpty else { return }

            let minBuffers = min(inputs.count, outputs.count)
            var hasActiveAudio = false
            for bufIdx in 0..<minBuffers {
                let inputBuf = inputs[bufIdx]
                let outputBuf = outputs[bufIdx]

                guard let src = inputBuf.mData?.assumingMemoryBound(to: Float.self),
                      let dst = outputBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }

                let count = Int(min(inputBuf.mDataByteSize, outputBuf.mDataByteSize) / 4)

                // Silence detection: inspect the first 32 samples with Accelerate max magnitude
                if !hasActiveAudio {
                    let checkCount = min(count, 32)
                    var maxVal: Float = 0
                    vDSP_maxmgv(src, 1, &maxVal, vDSP_Length(checkCount))
                    if maxVal > 0.0005 {
                        hasActiveAudio = true
                    }
                }

                // Volume application
                if vol == 0 {
                    // Muted: zero out destination buffer memory
                    memset(dst, 0, Int(outputBuf.mDataByteSize))
                } else {
                    // Accelerated SIMD vector-scalar multiplication: dst = src * gain
                    // ~4-8x faster than manual per-sample loops on Apple Silicon & Intel
                    var gain = vol
                    vDSP_vsmul(src, 1, &gain, dst, 1, vDSP_Length(count))
                    
                    // Zero any trailing channel bytes if output buffer exceeds input buffer size
                    if outputBuf.mDataByteSize > inputBuf.mDataByteSize {
                        let extraBytes = Int(outputBuf.mDataByteSize - inputBuf.mDataByteSize)
                        memset(dst.advanced(by: count), 0, extraBytes)
                    }
                }
            }
            if hasActiveAudio {
                AudioTapManager.activityTracker.recordActivity(for: pid)
                AudioTapManager.activityTracker.recordActivity(for: targetPID)
            }
        }

        // Start aggregate device audio playback
        if status == noErr, let proc = procID {
            let tapState = TapState(tapID: tapID, aggregateID: aggID, procID: proc, objectIDs: objectIDs, createdAt: CFAbsoluteTimeGetCurrent())
            activeTaps[pid] = tapState
            activeTaps[targetPID] = tapState
            
            // Record activity immediately so the cleanup timer does not prematurely destroy the tap
            Self.activityTracker.recordActivity(for: pid)
            Self.activityTracker.recordActivity(for: targetPID)
            
            let startStatus = AudioDeviceStart(aggID, proc)
            if startStatus != noErr {
                AppLogger.shared.log("AudioDeviceStart failed for PID \(pid) with status: \(startStatus)")
                activeTaps.removeValue(forKey: pid)
                activeTaps.removeValue(forKey: targetPID)
                _ = AudioDeviceDestroyIOProcID(aggID, proc)
                _ = AudioHardwareDestroyAggregateDevice(aggID)
                _ = AudioHardwareDestroyProcessTap(tapID)
            } else {
                AppLogger.shared.log("Successfully created and started process tap for PID \(targetPID) (main PID \(pid))")
            }
        } else {
            AppLogger.shared.log("AudioDeviceCreateIOProcIDWithBlock failed for PID \(pid) with status: \(status)")
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
    }

    // MARK: - Tap Teardown

    /// Stops audio, destroys IO procs, and removes the aggregate device and tap for a given PID.
    func removeTap(for pid: pid_t) {
        guard let state = activeTaps[pid] else { return }
        _ = AudioDeviceStop(state.aggregateID, state.procID)
        _ = AudioDeviceDestroyIOProcID(state.aggregateID, state.procID)
        _ = AudioHardwareDestroyAggregateDevice(state.aggregateID)
        _ = AudioHardwareDestroyProcessTap(state.tapID)
        
        // Remove all dictionary references pointing to this tap instance
        let tapID = state.tapID
        for (key, value) in activeTaps where value.tapID == tapID {
            Self.activityTracker.remove(pid: key)
            volumeStore.remove(key)
            activeTaps.removeValue(forKey: key)
        }
    }

    /// Tears down all active taps upon quit or output device reconfiguration.
    func removeAllTaps() {
        for pid in Array(activeTaps.keys) {
            removeTap(for: pid)
        }
    }

    deinit {
        cleanupTimer?.invalidate()
        // Unregister CoreAudio property listener blocks using stored block references
        if var addr = processListListenerAddress, let block = processListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
        }
        if var addr = outputDeviceListenerAddress, let block = outputDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
        }
        if var addr = hardwareDevicesListenerAddress, let block = hardwareDevicesListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
        }
    }

    // MARK: - Output Device Helpers

    /// Queries the CoreAudio HAL for all available output devices, filtering out MySound virtual tap devices.
    func getAvailableOutputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else {
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs) == noErr else {
            return []
        }

        var outputDevices: [AudioOutputDevice] = []

        for deviceID in deviceIDs {
            // Check if device has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) != noErr || streamSize == 0 {
                continue
            }

            // Get device name
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
            }
            guard nameStatus == noErr, let deviceName = name?.takeRetainedValue() as String? else {
                continue
            }

            // Filter out MySound tap aggregate devices from the user-facing device list
            if deviceName.hasPrefix("MySound-Tap-") {
                continue
            }

            // Get device UID
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var deviceUID = ""
            if withUnsafeMutablePointer(to: &uid, { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, ptr)
            }) == noErr, let uidStr = uid?.takeRetainedValue() as String? {
                deviceUID = uidStr
            }

            outputDevices.append(AudioOutputDevice(id: deviceID, name: deviceName, uid: deviceUID))
        }

        return outputDevices
    }

    /// Fetches the currently active default system audio output device.
    func getDefaultOutputDevice() -> AudioOutputDevice? {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr else {
            return nil
        }

        let available = getAvailableOutputDevices()
        return available.first(where: { $0.id == defaultOutputDeviceID })
    }

    /// Switches the system-wide default output device to the specified hardware device.
    func setDefaultOutputDevice(_ device: AudioOutputDevice) {
        var devID = device.id
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, propertySize, &devID)
        if status == noErr {
            self.currentOutputDevice = device
        } else {
            print("MySound: Failed to set default output device \(device.name) (status: \(status))")
        }
    }

    // MARK: - System Master Volume Helpers

    /// Adjusts the global macOS master output volume (0.0...1.0) and mute flag on the default output device.
    func setSystemVolume(_ volume: Float) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr {
            var vol = volume
            // Set volume on Main element, and channels 1 and 2
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
                if AudioObjectHasProperty(defaultOutputDeviceID, &volAddr) {
                    _ = AudioObjectSetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                }
            }
            
            // Set hardware mute flag when volume drops to zero
            var isMuted: UInt32 = (volume <= 0.001) ? 1 : 0
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
                if AudioObjectHasProperty(defaultOutputDeviceID, &muteAddr) {
                    _ = AudioObjectSetPropertyData(defaultOutputDeviceID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &isMuted)
                }
            }
        }
    }

    /// Reads the current global macOS master output volume (0.0...1.0).
    func getSystemVolume() -> Float {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr {
            // Check mute property first
            for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
                var isMuted: UInt32 = 0
                var muteSize = UInt32(MemoryLayout<UInt32>.size)
                var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                if AudioObjectGetPropertyData(defaultOutputDeviceID, &muteAddr, 0, nil, &muteSize, &isMuted) == noErr {
                    if isMuted == 1 {
                        return 0.0
                    }
                }
            }

            // Read scalar volume
            var vol: Float32 = 0
            var volSize = UInt32(MemoryLayout<Float32>.size)
            var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, &volSize, &vol) != noErr {
                volAddr.mElement = 1
                AudioObjectGetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, &volSize, &vol)
            }
            return Float(vol)
        }
        return 0.5
    }

    /// Retrieves the string UID of the active default output device.
    private func getDefaultOutputDeviceUID() -> String? {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr {
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if withUnsafeMutablePointer(to: &uid, { ptr in AudioObjectGetPropertyData(defaultOutputDeviceID, &uidAddress, 0, nil, &uidSize, ptr) }) == noErr,
               let uidString = uid?.takeRetainedValue() {
                return uidString as String
            }
        }
        return nil
    }

    // MARK: - Process Tree Helpers

    /// Iteratively lists all child process IDs spawned under a parent process (up to maxDepth levels).
    private func getChildPIDs(parentPID: pid_t, maxDepth: Int = 8) -> Set<pid_t> {
        var allPIDs = Set<pid_t>()
        var queue: [(pid: pid_t, depth: Int)] = [(parentPID, 0)]
        var visited: Set<pid_t> = [parentPID]

        while !queue.isEmpty {
            let (currentPID, depth) = queue.removeFirst()
            if depth >= maxDepth { continue }

            let bufferSize = proc_listchildpids(currentPID, nil, 0)
            guard bufferSize > 0 else { continue }
            let count = Int(bufferSize) / MemoryLayout<pid_t>.size
            var childPIDs = [pid_t](repeating: 0, count: count)
            let actualSize = proc_listchildpids(currentPID, &childPIDs, bufferSize)
            guard actualSize > 0 else { continue }
            let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
            for i in 0..<actualCount {
                let child = childPIDs[i]
                if visited.insert(child).inserted {
                    allPIDs.insert(child)
                    queue.append((child, depth + 1))
                }
            }
        }
        return allPIDs
    }

    /// Finds all CoreAudio AudioObjectIDs associated with a target process.
    ///
    /// Matches against:
    /// 1. Direct PID
    /// 2. Responsible parent PID
    /// 3. Child process tree
    /// 4. App Bundle Identifier prefix matching
    /// 5. Executable bundle directory containment
    private func getAudioObjectIDs(for targetPID: pid_t) -> [AudioObjectID] {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }
        
        let mainPID = getMainAppPID(for: targetPID)
        let pidsToMatch: Set<pid_t> = [
            targetPID,
            mainPID,
            Self.getResponsiblePID?(targetPID) ?? targetPID,
            Self.getResponsiblePID?(mainPID) ?? mainPID
        ]
        
        var childPIDs = getChildPIDs(parentPID: targetPID)
        childPIDs.formUnion(getChildPIDs(parentPID: mainPID))

        let targetApp = NSRunningApplication(processIdentifier: targetPID) ?? NSRunningApplication(processIdentifier: mainPID)
        let targetBundleID = targetApp?.bundleIdentifier?.lowercased()
        let targetLocalizedName = targetApp?.localizedName?.lowercased()
        let targetBundleName = targetApp?.bundleURL?.deletingPathExtension().lastPathComponent.lowercased()
        
        var matchingIDs: [AudioObjectID] = []
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                var matched = false
                let procRespPID = Self.getResponsiblePID?(processPID) ?? processPID
                
                if pidsToMatch.contains(processPID) || pidsToMatch.contains(procRespPID) || childPIDs.contains(processPID) {
                    matched = true
                } else if let processApp = NSRunningApplication(processIdentifier: processPID), let procBundleID = processApp.bundleIdentifier?.lowercased(), let targetBundleID = targetBundleID, (procBundleID.hasPrefix(targetBundleID) || targetBundleID.hasPrefix(procBundleID)) {
                    matched = true
                } else if let procPath = Self.getPath(for: processPID)?.lowercased() {
                    if let targetLocalizedName = targetLocalizedName, !targetLocalizedName.isEmpty, procPath.contains(targetLocalizedName) {
                        matched = true
                    } else if let targetBundleName = targetBundleName, !targetBundleName.isEmpty, procPath.contains(targetBundleName) {
                        matched = true
                    }
                }
                
                if matched {
                    matchingIDs.append(processID)
                }
            }
        }
        return matchingIDs
    }

    /// Resolves the filesystem executable path for a given process ID using `proc_pidpath`.
    private nonisolated static func getPath(for pid: pid_t) -> String? {
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
        if pathLength > 0 {
            return String(cString: pathBuffer)
        }
        return nil
    }

    /// Inspects whether an AudioObjectID is actively outputting sound to hardware.
    /// Uses CoreAudio FourCC selector `0x7069726f` ('piro' -> `kAudioProcessPropertyIsRunningOutput`).
    nonisolated static func isProcessRunningOutput(_ processID: AudioObjectID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7069726f), // 'piro'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &isRunning) == noErr {
            return isRunning != 0
        }
        return false
    }

    /// Discovers all process IDs that are currently playing sound.
    ///
    /// - Parameter onlyPlayingAudio: If true, filters for processes whose hardware output status or recent activity is active.
    /// - Returns: Set of active process IDs (including mapped main application PIDs).
    nonisolated static func getAudioActivePIDs(onlyPlayingAudio: Bool = true) -> Set<pid_t> {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }

        var activePIDs = Set<pid_t>()
        let runningApps = NSWorkspace.shared.runningApplications

        // Pre-index running applications by bundle path for efficient longest-prefix matching
        var bundlePathIndex: [(path: String, app: NSRunningApplication)] = []
        for app in runningApps {
            if let bundlePath = app.bundleURL?.path {
                bundlePathIndex.append((path: bundlePath, app: app))
            }
        }
        bundlePathIndex.sort { $0.path.count > $1.path.count }

        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                let respPID = Self.getResponsiblePID?(processPID) ?? processPID

                let isHardwarePlaying = isProcessRunningOutput(processID)
                if isHardwarePlaying {
                    activityTracker.recordActivity(for: processPID)
                    activityTracker.recordActivity(for: respPID)
                }

                let isRecentlyActive = !onlyPlayingAudio || activityTracker.isAudioActive(for: processPID, window: 1.0) || activityTracker.isAudioActive(for: respPID, window: 1.0)

                if isRecentlyActive {
                    activePIDs.insert(respPID)
                    activePIDs.insert(processPID)

                    if let procPath = getPath(for: processPID) {
                        for entry in bundlePathIndex {
                            if procPath.hasPrefix(entry.path) {
                                if isHardwarePlaying {
                                    activityTracker.recordActivity(for: entry.app.processIdentifier)
                                }
                                activePIDs.insert(entry.app.processIdentifier)
                                break
                            }
                        }
                    }
                }
            }
        }
        return activePIDs
    }
}

