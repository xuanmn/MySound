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

// Fix 4: Lightweight lock wrapper safe for use on real-time audio threads
private struct UnfairLock {
    private var _lock = os_unfair_lock_s()
    mutating func lock() { os_unfair_lock_lock(&_lock) }
    mutating func unlock() { os_unfair_lock_unlock(&_lock) }
    mutating func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
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

    // Fix 2: Cache dlsym lookup once at init — avoids redundant symbol resolution on every call
    private let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)?

    // Fix 4: os_unfair_lock for audio-thread-safe volume reads
    private var volumeLock = UnfairLock()
    private var volumes: [pid_t: Float] = [:]

    override init() {
        // Fix 2: Resolve private SPI symbol once
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        self.getResponsiblePID = symbol.map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
        super.init()
        setupProcessListListener()
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

    func setVolume(for pid: pid_t, volume: Float) {
        // Fix 4: use UnfairLock wrapper
        volumeLock.withLock { volumes[pid] = volume }

        // Fix 3: already on @MainActor, call directly — no Task hop needed
        if activeTaps[pid] == nil {
            createTap(for: pid)
        }
    }

    private func createTap(for pid: pid_t) {
        // Fix 5: guard against running on unsupported macOS versions
        guard #available(macOS 14.2, *) else {
            print("MySound: Process taps require macOS 14.2 or later.")
            return
        }
        if activeTaps[pid] != nil { return }

        guard let outputDeviceUID = getDefaultOutputDeviceUID() else { return }

        let objectIDs = getAudioObjectIDs(for: pid)
        guard !objectIDs.isEmpty else { return }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .muted
        tapDescription.deviceUID = outputDeviceUID
        tapDescription.isPrivate = true

        var tapID: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else { return }

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MySound-Tap-\(pid)" as NSString,
            kAudioAggregateDeviceUIDKey: UUID().uuidString as NSString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID as NSString,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID as NSString,
            kAudioAggregateDeviceIsPrivateKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceIsStackedKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceTapAutoStartKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID as NSString, kAudioSubDeviceDriftCompensationKey: kCFBooleanTrue as Any]
            ] as NSArray,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString as NSString, kAudioSubTapDriftCompensationKey: kCFBooleanTrue as Any]
            ] as NSArray
        ]

        var aggID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        guard status == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] (now, inputData, inputTime, outputData, outputTime) in
            guard let self = self else { return }

            // Fix 4: os_unfair_lock is safe to use on the real-time audio thread
            let vol = self.volumeLock.withLock { self.volumes[pid] ?? 1.0 }

            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            guard !inputs.isEmpty && !outputs.isEmpty else { return }

            // Direct Zero-Latency Mix across all audio channel buffers
            let minBuffers = min(inputs.count, outputs.count)
            for bufIdx in 0..<minBuffers {
                let inputBuf = inputs[bufIdx]
                let outputBuf = outputs[bufIdx]

                guard let src = inputBuf.mData?.assumingMemoryBound(to: Float.self),
                      let dst = outputBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }

                let count = min(inputBuf.mDataByteSize, outputBuf.mDataByteSize) / 4
                if vol == 0 {
                    memset(dst, 0, Int(count * 4))
                } else {
                    for i in 0..<Int(count) {
                        dst[i] += src[i] * vol
                    }
                }
            }
        }

        if status == noErr, let proc = procID {
            activeTaps[pid] = TapState(tapID: tapID, aggregateID: aggID, procID: proc, objectIDs: objectIDs)
            _ = AudioDeviceStart(aggID, proc)
        } else {
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
    }

    func removeTap(for pid: pid_t) {
        guard let state = activeTaps[pid] else { return }
        _ = AudioDeviceStop(state.aggregateID, state.procID)
        _ = AudioHardwareDestroyAggregateDevice(state.aggregateID)
        _ = AudioHardwareDestroyProcessTap(state.tapID)
        activeTaps.removeValue(forKey: pid)
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

    nonisolated static func getAudioActivePIDs() -> Set<pid_t> {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }
        // Fix 2: Note — this is a static func so we resolve dlsym inline here;
        // instance method calls use the cached self.getResponsiblePID instead.
        let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)? = symbol.map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
        var activePIDs = Set<pid_t>()
        let runningApps = NSWorkspace.shared.runningApplications
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                let respPID = getResponsiblePID?(processPID) ?? processPID
                activePIDs.insert(respPID)
                activePIDs.insert(processPID)
                
                // Fix 1: use defer to guarantee deallocation even on early exit
                let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
                defer { pathBuffer.deallocate() }
                let pathLength = proc_pidpath(processPID, pathBuffer, UInt32(MAXPATHLEN))
                if pathLength > 0 {
                    let procPath = String(cString: pathBuffer)
                    for app in runningApps {
                        if let bundlePath = app.bundleURL?.path, procPath.hasPrefix(bundlePath) {
                            activePIDs.insert(app.processIdentifier)
                        }
                    }
                }
            }
        }
        return activePIDs
    }
}
