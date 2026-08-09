import Foundation
import CoreAudio
import AppKit
import os
import CoreGraphics

// Declare private Core Audio functions (macOS 14.2+)
#if canImport(CoreAudio)
@_silgen_name("AudioHardwareCreateProcessTap")
func AudioHardwareCreateProcessTap(_ description: CATapDescription, _ tapID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus

@_silgen_name("AudioHardwareDestroyProcessTap")
func AudioHardwareDestroyProcessTap(_ tapID: AudioObjectID) -> OSStatus

@_silgen_name("AudioHardwareCreateAggregateDevice")
func AudioHardwareCreateAggregateDevice(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus

@_silgen_name("AudioHardwareDestroyAggregateDevice")
func AudioHardwareDestroyAggregateDevice(_ inDeviceID: AudioObjectID) -> OSStatus
#endif

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private let logFileURL: URL?

    init() {
        let fileManager = FileManager.default
        if let libraryLogs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Logs") {
            try? fileManager.createDirectory(at: libraryLogs, withIntermediateDirectories: true)
            logFileURL = libraryLogs.appendingPathComponent("MySound.log")
        } else {
            logFileURL = nil
        }
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)\n"
        NSLog("MySound: %@", message)
        guard let url = logFileURL else { return }
        if let data = logLine.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// Bug #3 fix: Shared volume store — Sendable, not actor-isolated,
// safe for the real-time audio thread to read from.
final class VolumeStore: @unchecked Sendable {
    private var _lock = os_unfair_lock_s()
    private var volumes: [pid_t: Float] = [:]

    func get(_ pid: pid_t) -> Float {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return volumes[pid] ?? 1.0
    }

    func set(_ pid: pid_t, _ volume: Float) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        volumes[pid] = volume
    }

    func remove(_ pid: pid_t) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        volumes.removeValue(forKey: pid)
    }
}

final class AudioActivityTracker: @unchecked Sendable {
    private var _lock = os_unfair_lock_s()
    private var lastActivity: [pid_t: CFAbsoluteTime] = [:]

    func recordActivity(for pid: pid_t) {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&_lock)
        lastActivity[pid] = now
        os_unfair_lock_unlock(&_lock)
    }

    func isAudioActive(for pid: pid_t, window: TimeInterval = 1.0) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard let last = lastActivity[pid] else { return false }
        return (now - last) <= window
    }

    func remove(pid: pid_t) {
        os_unfair_lock_lock(&_lock)
        lastActivity.removeValue(forKey: pid)
        os_unfair_lock_unlock(&_lock)
    }
}

struct AudioOutputDevice: Identifiable, Hashable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static func == (lhs: AudioOutputDevice, rhs: AudioOutputDevice) -> Bool {
        lhs.id == rhs.id && lhs.uid == rhs.uid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
    }
}

@MainActor
class AudioTapManager: NSObject, ObservableObject {
    static let shared = AudioTapManager()

    struct TapState {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        let objectIDs: [AudioObjectID]
        let createdAt: CFAbsoluteTime
    }

    @Published var activeTaps: [pid_t: TapState] = [:]
    @Published var currentOutputDevice: AudioOutputDevice?
    @Published var availableOutputDevices: [AudioOutputDevice] = []

    // Cache dlsym lookup once globally — avoids redundant symbol resolution on every call
    private nonisolated static let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    let volumeStore = VolumeStore()
    nonisolated static let activityTracker = AudioActivityTracker()

    /// Check if we actually have the System Audio Recording permission.
    /// CGPreflightScreenCaptureAccess() checks Screen Capture TCC, NOT
    /// System Audio Recording TCC — they are different permission categories.
    /// The only reliable way is to attempt a lightweight tap creation.
    nonisolated static func hasAudioCapturePermission() -> Bool {
        // If we already have active taps, permission is clearly granted
        // (avoids redundant tap-creation tests while the app is working)
        if !activityTracker.isAudioActive(for: 0, window: 0) {
            // Fallback: actually no-op, just check if we can query the process list
            // which requires the entitlement to be present
        }
        // Try the lightweight check first: if process objects are visible
        // then we have the necessary TCC permission
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
            // If we can see at least 1 audio process, TCC is granted
            return count > 0
        }
        return false
    }

    nonisolated static func openSystemAudioPermissionSettings() {
        // On macOS 15+ the System Audio Recording pane is separate
        if #available(macOS 15.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SystemAudioRecording") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        // Fallback: Screen & System Audio Recording is under Screen Recording on macOS 14
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

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

    private func setupCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupInactiveTaps()
            }
        }
    }

    func cleanupInactiveTaps() {
        let now = CFAbsoluteTimeGetCurrent()
        // Deduplicate: collect unique TapStates by tapID to avoid double-cleanup
        var seenTapIDs = Set<AudioObjectID>()
        let currentActivePIDs = Array(activeTaps.keys)
        for pid in currentActivePIDs {
            guard let state = activeTaps[pid] else { continue }
            // Skip if we already processed this tap (shared between targetPID and mainPID)
            guard seenTapIDs.insert(state.tapID).inserted else { continue }
            // Give new taps a 5-second grace period before cleanup can touch them.
            // On Intel Macs, the aggregate device IO proc can take 1-3 seconds to start
            // receiving audio buffers after creation.
            let age = now - state.createdAt
            if age < 5.0 { continue }
            let isRunning = NSRunningApplication(processIdentifier: pid) != nil
            let isActive = Self.activityTracker.isAudioActive(for: pid, window: 3.0)
            if !isRunning || !isActive {
                removeTap(for: pid)
            }
        }
    }

    func getMainAppPID(for targetPID: pid_t) -> pid_t {
        if let app = NSRunningApplication(processIdentifier: targetPID), app.activationPolicy == .regular {
            return targetPID
        }
        if let respPID = Self.getResponsiblePID?(targetPID), let app = NSRunningApplication(processIdentifier: respPID), app.activationPolicy == .regular {
            return respPID
        }
        if let procPath = Self.getPath(for: targetPID) {
            for app in NSWorkspace.shared.runningApplications {
                if app.activationPolicy == .regular, let bundlePath = app.bundleURL?.path, procPath.hasPrefix(bundlePath) {
                    return app.processIdentifier
                }
            }
        }
        return targetPID
    }

    private func setupProcessListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Bug #7 fix: store the block object itself so deinit can pass the exact
        // same pointer back to AudioObjectRemovePropertyListenerBlock.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshActiveTaps()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        processListListenerAddress = address
        processListListenerBlock = block
    }

    private func setupHardwareListeners() {
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshOutputDevices()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevAddr, DispatchQueue.main, outputBlock)
        outputDeviceListenerAddress = defaultDevAddr
        outputDeviceListenerBlock = outputBlock

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshOutputDevices()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devicesBlock)
        hardwareDevicesListenerAddress = devicesAddr
        hardwareDevicesListenerBlock = devicesBlock
    }

    func refreshOutputDevices() {
        let devices = getAvailableOutputDevices()
        let current = getDefaultOutputDevice()
        let deviceChanged = self.currentOutputDevice?.uid != current?.uid
        self.availableOutputDevices = devices
        self.currentOutputDevice = current
        if deviceChanged && current != nil {
            recreateAllTaps()
        }
    }

    func recreateAllTaps() {
        let currentPIDs = Array(activeTaps.keys)
        removeAllTaps()
        for pid in currentPIDs {
            createTap(for: pid)
        }
    }

    private func refreshActiveTaps() {
        for (pid, state) in activeTaps {
            let currentObjectIDs = getAudioObjectIDs(for: pid)
            if Set(currentObjectIDs) != Set(state.objectIDs) && !currentObjectIDs.isEmpty {
                // Re-create tap with updated AudioObjectIDs
                removeTap(for: pid)
                createTap(for: pid)
            }
        }
    }


    func ensureTapCreated(for targetPID: pid_t) {
        let pid = getMainAppPID(for: targetPID)
        if activeTaps[pid] == nil && activeTaps[targetPID] == nil {
            createTap(for: targetPID)
        }
    }

    func setVolume(for targetPID: pid_t, volume: Float) {
        let mainPID = getMainAppPID(for: targetPID)
        volumeStore.set(mainPID, volume)
        volumeStore.set(targetPID, volume)

        if activeTaps[mainPID] == nil && activeTaps[targetPID] == nil {
            createTap(for: targetPID)
        }
    }

    private func createTap(for targetPID: pid_t) {
        // Fix 5: guard against running on unsupported macOS versions
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

        // Check if any of these objectIDs are already tapped by another activeTap
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

        // Stage 1: .muted + isPrivate (best quality — silences original, routes through IO proc)
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true
        status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        if status != noErr {
            AppLogger.shared.log("Tap creation failed (status \(status)) with muted+private")
            // Stage 2: .muted + !isPrivate
            tapDescription.isPrivate = false
            status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        }
        if status != noErr {
            AppLogger.shared.log("Tap creation failed (status \(status)) with muted+public")
            // Stage 3: .unmuted + isPrivate
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        }
        if status != noErr {
            AppLogger.shared.log("Tap creation failed (status \(status)) with unmuted+private")
            // Stage 4: .unmuted + !isPrivate
            tapDescription.isPrivate = false
            status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        }

        guard status == noErr else {
            AppLogger.shared.log("All AudioHardwareCreateProcessTap attempts failed for PID \(targetPID) (final status: \(status))")
            return
        }
        AppLogger.shared.log("AudioHardwareCreateProcessTap succeeded for PID \(targetPID) (mute=\(tapDescription.muteBehavior.rawValue), private=\(tapDescription.isPrivate))")

        // Build aggregate description with cascading fallbacks for Intel/macOS 14/15
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

        let volumeStore = self.volumeStore
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { (now, inputData, inputTime, outputData, outputTime) in
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
                if vol == 0 {
                    for i in 0..<count {
                        if abs(src[i]) > 0.0005 {
                            hasActiveAudio = true
                        }
                    }
                    memset(dst, 0, Int(outputBuf.mDataByteSize))
                } else {
                    for i in 0..<count {
                        let sample = src[i]
                        dst[i] = sample * vol
                        if abs(sample) > 0.0005 {
                            hasActiveAudio = true
                        }
                    }
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

        if status == noErr, let proc = procID {
            let tapState = TapState(tapID: tapID, aggregateID: aggID, procID: proc, objectIDs: objectIDs, createdAt: CFAbsoluteTimeGetCurrent())
            activeTaps[pid] = tapState
            activeTaps[targetPID] = tapState
            // Record activity immediately so the cleanup timer doesn't destroy
            // the tap before the IO proc has a chance to start on Intel Macs
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

    func removeTap(for pid: pid_t) {
        guard let state = activeTaps[pid] else { return }
        _ = AudioDeviceStop(state.aggregateID, state.procID)
        _ = AudioDeviceDestroyIOProcID(state.aggregateID, state.procID)
        _ = AudioHardwareDestroyAggregateDevice(state.aggregateID)
        _ = AudioHardwareDestroyProcessTap(state.tapID)
        // Remove ALL entries sharing this same tap (targetPID + mainPID both point to same TapState)
        let tapID = state.tapID
        for (key, value) in activeTaps where value.tapID == tapID {
            Self.activityTracker.remove(pid: key)
            volumeStore.remove(key)
            activeTaps.removeValue(forKey: key)
        }
    }

    // Bug #5 fix: Explicit cleanup of all active taps.
    // Call before deallocation or on app termination.
    func removeAllTaps() {
        for pid in Array(activeTaps.keys) {
            removeTap(for: pid)
        }
    }

    // Bug #5/#7 fix: Clean up property listeners when deallocated.
    // Note: activeTaps cleanup should be done via removeAllTaps() before
    // this point, since deinit is nonisolated and can't access @MainActor state.
    deinit {
        // Remove property listeners using the stored block objects.
        // AudioObjectRemovePropertyListenerBlock requires the exact same block
        // pointer that was passed to AudioObjectAddPropertyListenerBlock.
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

            // Filter out MySound tap aggregate devices
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
            // Note: Do NOT call refreshOutputDevices() here — the HAL listener for
            // kAudioHardwarePropertyDefaultOutputDevice fires automatically and calls
            // refreshOutputDevices(), which calls recreateAllTaps(). Calling it again
            // here would cause double tap recreation.
        } else {
            print("MySound: Failed to set default output device \(device.name) (status: \(status))")
        }
    }

    // MARK: - System Volume Helpers
    func setSystemVolume(_ volume: Float) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr {
            var vol = volume
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
                if AudioObjectHasProperty(defaultOutputDeviceID, &volAddr) {
                    _ = AudioObjectSetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                }
            }
            
            var isMuted: UInt32 = (volume == 0) ? 1 : 0
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(element))
                if AudioObjectHasProperty(defaultOutputDeviceID, &muteAddr) {
                    _ = AudioObjectSetPropertyData(defaultOutputDeviceID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &isMuted)
                }
            }
        }
    }

    func getSystemVolume() -> Float {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr {
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

    private func getChildPIDs(parentPID: pid_t) -> Set<pid_t> {
        var pids = Set<pid_t>()
        let bufferSize = proc_listchildpids(parentPID, nil, 0)
        if bufferSize > 0 {
            let count = Int(bufferSize) / MemoryLayout<pid_t>.size
            var childPIDs = [pid_t](repeating: 0, count: count)
            let actualSize = proc_listchildpids(parentPID, &childPIDs, bufferSize)
            if actualSize > 0 {
                let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
                for i in 0..<actualCount {
                    let child = childPIDs[i]
                    pids.insert(child)
                    pids.formUnion(getChildPIDs(parentPID: child))
                }
            }
        }
        return pids
    }

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

    private nonisolated static func getPath(for pid: pid_t) -> String? {
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
        if pathLength > 0 {
            return String(cString: pathBuffer)
        }
        return nil
    }

    nonisolated static func isProcessRunningOutput(_ processID: AudioObjectID) -> Bool {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        // 'piro' = kAudioProcessPropertyIsRunningOutput
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7069726f),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &isRunning) == noErr {
            return isRunning != 0
        }
        return false
    }

    nonisolated static func getAudioActivePIDs(onlyPlayingAudio: Bool = true) -> Set<pid_t> {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }

        var activePIDs = Set<pid_t>()
        let runningApps = NSWorkspace.shared.runningApplications

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
                        for app in runningApps {
                            if let bundlePath = app.bundleURL?.path, procPath.hasPrefix(bundlePath) {
                                if isHardwarePlaying {
                                    activityTracker.recordActivity(for: app.processIdentifier)
                                }
                                activePIDs.insert(app.processIdentifier)
                            }
                        }
                    }
                }
            }
        }
        return activePIDs
    }
}
