import Foundation
import CoreAudio
import AppKit
import os

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

    func isAudioActive(for pid: pid_t, window: TimeInterval = 0.25) -> Bool {
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
    struct TapState {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        let objectIDs: [AudioObjectID]
    }

    @Published var activeTaps: [pid_t: TapState] = [:]
    @Published var currentOutputDevice: AudioOutputDevice?
    @Published var availableOutputDevices: [AudioOutputDevice] = []

    // Fix 2: Cache dlsym lookup once at init — avoids redundant symbol resolution on every call
    private let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)?

    // Bug #2/#3 fix: VolumeStore is a class with its own lock, safe for real-time audio threads
    let volumeStore = VolumeStore()
    nonisolated static let activityTracker = AudioActivityTracker()

    // Bug #7 fix: store the property listener addresses so we can remove them on deinit
    private var processListListenerAddress: AudioObjectPropertyAddress?
    private var outputDeviceListenerAddress: AudioObjectPropertyAddress?
    private var hardwareDevicesListenerAddress: AudioObjectPropertyAddress?

    override init() {
        // Fix 2: Resolve private SPI symbol once
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        self.getResponsiblePID = symbol.map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
        super.init()
        setupProcessListListener()
        refreshOutputDevices()
        setupHardwareListeners()
    }

    func getMainAppPID(for targetPID: pid_t) -> pid_t {
        if let app = NSRunningApplication(processIdentifier: targetPID), app.activationPolicy == .regular {
            return targetPID
        }
        if let respPID = getResponsiblePID?(targetPID), let app = NSRunningApplication(processIdentifier: respPID), app.activationPolicy == .regular {
            return respPID
        }
        if let procPath = getPath(for: targetPID) {
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
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshActiveTaps()
            }
        }
        // Bug #7 fix: save address so we can remove the listener in deinit
        processListListenerAddress = address
    }

    private func setupHardwareListeners() {
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevAddr, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshOutputDevices()
            }
        }
        outputDeviceListenerAddress = defaultDevAddr

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshOutputDevices()
            }
        }
        hardwareDevicesListenerAddress = devicesAddr
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

    func ensureTapsForAudioProcesses() {
        let rawPIDs = Self.getRawProcessPIDs()
        for pid in rawPIDs {
            let mainPID = getMainAppPID(for: pid)
            if activeTaps[mainPID] == nil {
                createTap(for: mainPID)
            }
        }
    }

    func setVolume(for targetPID: pid_t, volume: Float) {
        let mainPID = getMainAppPID(for: targetPID)
        volumeStore.set(mainPID, volume)

        if activeTaps[mainPID] == nil {
            createTap(for: mainPID)
        }
    }

    private func createTap(for targetPID: pid_t) {
        // Fix 5: guard against running on unsupported macOS versions
        guard #available(macOS 14.2, *) else {
            print("MySound: Process taps require macOS 14.2 or later.")
            return
        }
        let pid = getMainAppPID(for: targetPID)
        if activeTaps[pid] != nil { return }

        guard let outputDeviceUID = getDefaultOutputDeviceUID() else { return }

        let objectIDs = getAudioObjectIDs(for: pid)
        NSLog("MySound DEBUG: createTap for PID %d -> found %d AudioObjectIDs", pid, objectIDs.count)
        guard !objectIDs.isEmpty else { return }

        // Check if any of these objectIDs are already tapped by another activeTap
        let allTappedObjectIDs = Set(activeTaps.values.flatMap { $0.objectIDs })
        if !Set(objectIDs).isDisjoint(with: allTappedObjectIDs) {
            NSLog("MySound DEBUG: Skipping tap for PID %d - objectIDs already tapped.", pid)
            return
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .muted
        tapDescription.deviceUID = outputDeviceUID
        tapDescription.isPrivate = true

        var tapID: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        NSLog("MySound DEBUG: AudioHardwareCreateProcessTap for PID %d returned status %d, tapID %d", pid, status, tapID)
        guard status == noErr else {
            NSLog("MySound: AudioHardwareCreateProcessTap failed for PID %d with status: %d.", pid, status)
            return
        }

        // Bug #6 fix: Build aggregate description, try with TapAutoStartKey first,
        // then fall back without it for older macOS 14.2 Intel builds.
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

        // Bug #6 fix: If aggregate creation fails, retry without TapAutoStartKey
        // (not recognized on some Intel Macs running exactly macOS 14.2)
        if status != noErr {
            print("MySound: Aggregate device creation failed (status \(status)), retrying without TapAutoStartKey...")
            aggregateDesc.removeValue(forKey: kAudioAggregateDeviceTapAutoStartKey)
            status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        }

        guard status == noErr else {
            print("MySound: AudioHardwareCreateAggregateDevice failed for PID \(pid) with status: \(status)")
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }

        // Bug #1 fix: Force the aggregate device's input stream to Float32
        // so the IO proc callback always receives Float32 samples.
        // IMPORTANT: Only set on INPUT scope. Do NOT touch the output scope —
        // changing the output format breaks the output device's native format
        // and causes complete audio silence.
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
                print("MySound: Warning — could not force Float32 format on aggregate input (status \(setStatus)). Current format: \(currentFormat.mBitsPerChannel)-bit, flags=\(currentFormat.mFormatFlags)")
            }
        }

        // Bug #3 fix: Capture volumeStore (a Sendable class) instead of self
        // to avoid @MainActor isolation violation on the real-time audio thread.
        let volumeStore = self.volumeStore
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { (now, inputData, inputTime, outputData, outputTime) in
            let vol = volumeStore.get(pid)

            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            guard !inputs.isEmpty && !outputs.isEmpty else { return }

            // Direct Zero-Latency Mix across all audio channel buffers
            // Uses buffer-for-buffer copy to match the native HAL layout
            // (typically non-interleaved on macOS)
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
                    // Zero any extra bytes in output buffer tail
                    if outputBuf.mDataByteSize > inputBuf.mDataByteSize {
                        let extraBytes = Int(outputBuf.mDataByteSize - inputBuf.mDataByteSize)
                        memset(dst.advanced(by: count), 0, extraBytes)
                    }
                }
            }
            if hasActiveAudio {
                AudioTapManager.activityTracker.recordActivity(for: pid)
            }
        }

        if status == noErr, let proc = procID {
            activeTaps[pid] = TapState(tapID: tapID, aggregateID: aggID, procID: proc, objectIDs: objectIDs)
            let startStatus = AudioDeviceStart(aggID, proc)
            if startStatus != noErr {
                print("MySound: AudioDeviceStart failed for PID \(pid) with status: \(startStatus)")
                activeTaps.removeValue(forKey: pid)
                _ = AudioDeviceDestroyIOProcID(aggID, proc)
                _ = AudioHardwareDestroyAggregateDevice(aggID)
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
        } else {
            print("MySound: AudioDeviceCreateIOProcIDWithBlock failed for PID \(pid) with status: \(status)")
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
    }

    func removeTap(for pid: pid_t) {
        guard let state = activeTaps[pid] else { return }
        _ = AudioDeviceStop(state.aggregateID, state.procID)
        // Bug #4 fix: destroy the IO proc ID to prevent leaking it
        _ = AudioDeviceDestroyIOProcID(state.aggregateID, state.procID)
        _ = AudioHardwareDestroyAggregateDevice(state.aggregateID)
        _ = AudioHardwareDestroyProcessTap(state.tapID)
        Self.activityTracker.remove(pid: pid)
        activeTaps.removeValue(forKey: pid)
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
        // Remove property listeners (Bug #7)
        if var addr = processListListenerAddress {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                { _, _ in }
            )
        }
        if var addr = outputDeviceListenerAddress {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                { _, _ in }
            )
        }
        if var addr = hardwareDevicesListenerAddress {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                { _, _ in }
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
        return available.first(where: { $0.id == defaultOutputDeviceID }) ?? getDeviceInfo(id: defaultOutputDeviceID)
    }

    private func getDeviceInfo(id: AudioDeviceID) -> AudioOutputDevice? {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard nameStatus == noErr, let deviceName = name?.takeRetainedValue() as String? else {
            return nil
        }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var deviceUID = ""
        if withUnsafeMutablePointer(to: &uid, { ptr in
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, ptr)
        }) == noErr, let uidStr = uid?.takeRetainedValue() as String? {
            deviceUID = uidStr
        }

        return AudioOutputDevice(id: id, name: deviceName, uid: deviceUID)
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
            refreshOutputDevices()
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
        
        let targetApp = NSRunningApplication(processIdentifier: targetPID)
        let targetBundleID = targetApp?.bundleIdentifier
        let targetAppPath = targetApp?.bundleURL?.path
        let childPIDs = getChildPIDs(parentPID: targetPID)
        // Fix 2: use pre-cached getResponsiblePID from init
        
        var matchingIDs: [AudioObjectID] = []
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                var matched = false
                if processPID == targetPID || childPIDs.contains(processPID) || getResponsiblePID?(processPID) == targetPID {
                    matched = true
                } else if let targetBundleID = targetBundleID, let processBundleID = NSRunningApplication(processIdentifier: processPID)?.bundleIdentifier, processBundleID.hasPrefix(targetBundleID) {
                    matched = true
                } else if let targetAppPath = targetAppPath, let procPath = getPath(for: processPID), procPath.hasPrefix(targetAppPath) {
                    matched = true
                }
                if matched {
                    matchingIDs.append(processID)
                }
            }
        }
        return matchingIDs
    }

    private func getPath(for pid: pid_t) -> String? {
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
        if pathLength > 0 {
            return String(cString: pathBuffer)
        }
        return nil
    }

    nonisolated static func getRawProcessPIDs() -> Set<pid_t> {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }

        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)? = symbol.map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
        var rawPIDs = Set<pid_t>()
        let runningApps = NSWorkspace.shared.runningApplications
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                let respPID = getResponsiblePID?(processPID) ?? processPID
                rawPIDs.insert(respPID)
                rawPIDs.insert(processPID)

                let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
                defer { pathBuffer.deallocate() }
                let pathLength = proc_pidpath(processPID, pathBuffer, UInt32(MAXPATHLEN))
                if pathLength > 0 {
                    let procPath = String(cString: pathBuffer)
                    for app in runningApps {
                        if let bundlePath = app.bundleURL?.path, procPath.hasPrefix(bundlePath) {
                            rawPIDs.insert(app.processIdentifier)
                        }
                    }
                }
            }
        }
        return rawPIDs
    }

    nonisolated static func getAudioActivePIDs(onlyPlayingAudio: Bool = true) -> Set<pid_t> {
        let rawPIDs = getRawProcessPIDs()
        if !onlyPlayingAudio {
            return rawPIDs
        }
        var activePIDs = Set<pid_t>()
        for pid in rawPIDs {
            if activityTracker.isAudioActive(for: pid) {
                activePIDs.insert(pid)
            }
        }
        return activePIDs
    }
}
