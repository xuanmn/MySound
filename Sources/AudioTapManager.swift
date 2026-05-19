import Foundation
import CoreAudio
import AppKit

// Declare private Core Audio functions
@_silgen_name("AudioHardwareCreateProcessTap")
func AudioHardwareCreateProcessTap(_ description: CATapDescription, _ tapID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus


@_silgen_name("AudioHardwareDestroyProcessTap")
func AudioHardwareDestroyProcessTap(_ tapID: AudioObjectID) -> OSStatus

@_silgen_name("AudioHardwareCreateAggregateDevice")
func AudioHardwareCreateAggregateDevice(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus

@_silgen_name("AudioHardwareDestroyAggregateDevice")
func AudioHardwareDestroyAggregateDevice(_ inDeviceID: AudioObjectID) -> OSStatus

@MainActor
class AudioTapManager: NSObject, ObservableObject {
    struct TapState {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
    }

    @Published var activeTaps: [pid_t: TapState] = [:]

    private var volumes: [pid_t: Float] = [:]
    private let volumeLock = NSLock()

    func setVolume(for pid: pid_t, volume: Float) {
        volumeLock.lock()
        volumes[pid] = volume
        volumeLock.unlock()

        if activeTaps[pid] == nil {
            Task { @MainActor in
                createTap(for: pid)
            }
        }
    }

    func startMonitoring() {}

    private func createTap(for pid: pid_t) {
        if activeTaps[pid] != nil { return }

        guard let outputDeviceUID = getDefaultOutputDeviceUID() else { return }

        let objectIDs = getAudioObjectIDs(for: pid)
        guard !objectIDs.isEmpty else { return }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .muted
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

            self.volumeLock.lock()
            let vol = self.volumes[pid] ?? 1.0
            self.volumeLock.unlock()

            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            guard !inputs.isEmpty && !outputs.isEmpty else { return }

            // Direct Zero-Latency Mix
            // We handle both interleaved and non-interleaved taps
            let inputBuf = inputs[0]
            let outputBuf = outputs[0]

            if inputBuf.mNumberChannels == outputBuf.mNumberChannels && inputBuf.mDataByteSize == outputBuf.mDataByteSize {
                guard let src = inputBuf.mData?.assumingMemoryBound(to: Float.self),
                      let dst = outputBuf.mData?.assumingMemoryBound(to: Float.self) else { return }

                let count = inputBuf.mDataByteSize / 4
                for i in 0..<Int(count) {
                    dst[i] += src[i] * vol
                }
            } else {
                guard let src = inputBuf.mData?.assumingMemoryBound(to: Float.self),
                      let dst = outputBuf.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = min(inputBuf.mDataByteSize, outputBuf.mDataByteSize) / 4
                for i in 0..<Int(frames) {
                    dst[i] += src[i] * vol
                }
            }
        }

        if status == noErr, let proc = procID {
            activeTaps[pid] = TapState(tapID: tapID, aggregateID: aggID, procID: proc)
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

    // ... (System volume helpers)
    func setSystemVolume(_ volume: Float) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &defaultOutputDeviceID) == noErr {
            var vol = volume
            var volAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
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

    private func getAudioObjectIDs(for targetPID: pid_t) -> [AudioObjectID] {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }
        let targetApp = NSRunningApplication(processIdentifier: targetPID)
        let targetBundleID = targetApp?.bundleIdentifier
        let respSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)? = respSymbol != nil ? unsafeBitCast(respSymbol, to: (@convention(c) (pid_t) -> pid_t).self) : nil
        var matchingIDs: [AudioObjectID] = []
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                if processPID == targetPID || getResponsiblePID?(processPID) == targetPID {
                    matchingIDs.append(processID)
                } else if let targetBundleID = targetBundleID, let processBundleID = NSRunningApplication(processIdentifier: processPID)?.bundleIdentifier, processBundleID.hasPrefix(targetBundleID) {
                    matchingIDs.append(processID)
                }
            }
        }
        return matchingIDs
    }

    static func getAudioActivePIDs() -> Set<pid_t> {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize) != noErr { return [] }
        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs) != noErr { return [] }
        let respSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        let getResponsiblePID: (@convention(c) (pid_t) -> pid_t)? = respSymbol != nil ? unsafeBitCast(respSymbol, to: (@convention(c) (pid_t) -> pid_t).self) : nil
        var activePIDs = Set<pid_t>()
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var processPID: pid_t = 0
            if AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID) == noErr {
                activePIDs.insert(getResponsiblePID?(processPID) ?? processPID)
                activePIDs.insert(processPID)
            }
        }
        return activePIDs
    }
}
