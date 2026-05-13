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

typealias AudioDeviceIOBlock = (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

@MainActor
class AudioTapManager: NSObject, ObservableObject {
    struct TapState {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
    }

    @Published var activeTaps: [pid_t: TapState] = [:]

    // Store volumes in a thread-safe way for the audio callback
    private var volumes: [pid_t: Float] = [:]
    private let volumeLock = NSLock()

    func setVolume(for pid: pid_t, volume: Float) {
        volumeLock.lock()
        volumes[pid] = volume
        volumeLock.unlock()

        // Update the engine's volume for this PID
        engineManager.setVolume(for: pid, volume: volume)

        if activeTaps[pid] == nil {
            Task { @MainActor in
                createTap(for: pid)
            }
        }
    }

    func setMasterVolume(_ volume: Float) {
        engineManager.setMasterVolume(volume)
    }

    private func getVolume(for pid: pid_t) -> Float {
        volumeLock.lock()
        let vol = volumes[pid] ?? 1.0
        volumeLock.unlock()
        return vol
    }

    // Reference to the engine manager
    private let engineManager = AudioEngineManager.shared

    func createTap(for pid: pid_t) {
        if activeTaps[pid] != nil { return }

        guard let outputDeviceUID = getDefaultOutputDeviceUID() else {
            print("ERROR: Could not get default output device UID")
            return
        }

        let objectIDs = getAudioObjectIDs(for: pid)
        guard !objectIDs.isEmpty else {
            print("ERROR: Could not find AudioObjectID for PID \(pid)")
            return
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        var tapID: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard status == noErr else {
            print("ERROR: Failed to create process tap for PID \(pid): \(status)")
            return
        }

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MySound-Tap-\(pid)" as NSString,
            kAudioAggregateDeviceUIDKey: UUID().uuidString as NSString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID as NSString,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID as NSString,
            kAudioAggregateDeviceIsPrivateKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceIsStackedKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceTapAutoStartKey: kCFBooleanTrue as Any,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID as NSString,
                    kAudioSubDeviceDriftCompensationKey: kCFBooleanFalse as Any
                ]
            ] as NSArray,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString as NSString,
                    kAudioSubTapDriftCompensationKey: kCFBooleanTrue as Any
                ]
            ] as NSArray
        ]

        var aggID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)

        if status == noErr {
            // Force the aggregate device to use the same sample rate as the output device
            // to avoid crashes in the system resampler/converter.
            var sampleRate: Float64 = 48000.0 // Default to 48k
            var propSize = UInt32(MemoryLayout<Float64>.size)
            var propAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)

            // Get the rate from the output device
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &propSize, &sampleRate)
            // Set it on the aggregate device
            AudioObjectSetPropertyData(aggID, &propAddr, 0, nil, propSize, &sampleRate)
        }

        guard status == noErr else {
            print("ERROR: Failed to create aggregate device for PID \(pid): \(status)")
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] (now, inputData, inputTime, outputData, outputTime) in
            guard let self = self else { return }

            // Pass the tap's input data to the AudioEngineManager for processing/playback
            self.engineManager.processBuffer(pid: pid, bufferList: inputData)

            // We don't write to outputData here because AVAudioEngine handles the playback
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            for outBuffer in outputs {
                if let dst = outBuffer.mData {
                    memset(dst, 0, Int(outBuffer.mDataByteSize))
                }
            }
        }

        if status == noErr, let proc = procID {
            // Update state BEFORE starting the device to ensure the callback has a valid state
            activeTaps[pid] = TapState(tapID: tapID, aggregateID: aggID, procID: proc)

            let startStatus = AudioDeviceStart(aggID, proc)
            if startStatus == noErr {
                print("SUCCESS: Started Aggregate IO Proc for PID \(pid)")
            } else {
                print("ERROR: Failed to start audio device for PID \(pid): \(startStatus)")
                activeTaps.removeValue(forKey: pid)
                _ = AudioHardwareDestroyAggregateDevice(aggID)
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
        } else {
            print("ERROR: Failed to create IO Proc for PID \(pid): \(status)")
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

        volumeLock.lock()
        volumes.removeValue(forKey: pid)
        volumeLock.unlock()

        print("SUCCESS: Destroyed Tap for PID \(pid)")
    }

    func setSystemVolume(_ volume: Float) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID)
        
        if status == noErr {
            var vol = volume
            let volSize = UInt32(MemoryLayout<Float32>.size)
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            
            // Check if volume is settable
            var isSettable: DarwinBoolean = false
            AudioObjectIsPropertySettable(defaultOutputDeviceID, &volAddr, &isSettable)
            
            if isSettable.boolValue {
                AudioObjectSetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, volSize, &vol)
            } else {
                // If scalar volume isn't settable, try setting it on channels (1 and 2 for stereo)
                for channel in 1...2 {
                    volAddr.mElement = UInt32(channel)
                    AudioObjectSetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, volSize, &vol)
                }
            }
        }
    }

    func getSystemVolume() -> Float {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID)
        
        if status == noErr {
            var vol: Float32 = 0
            var volSize = UInt32(MemoryLayout<Float32>.size)
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            
            status = AudioObjectGetPropertyData(defaultOutputDeviceID, &volAddr, 0, nil, &volSize, &vol)
            if status != noErr {
                // Try channel 1 if master fails
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
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID)

        if status == noErr {
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)

            status = withUnsafeMutablePointer(to: &uid) { uidPtr in
                AudioObjectGetPropertyData(
                    defaultOutputDeviceID,
                    &uidAddress,
                    0,
                    nil,
                    &uidSize,
                    uidPtr)
            }

            if status == noErr, let uidString = uid?.takeRetainedValue() {
                return uidString as String
            }
        }
        return nil
    }

    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    private func getAudioObjectIDs(for targetPID: pid_t) -> [AudioObjectID] {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize)
        guard status == noErr else { return [] }

        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)

        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs)
        guard status == noErr else { return [] }

        let targetApp = NSRunningApplication(processIdentifier: targetPID)
        let targetBundleID = targetApp?.bundleIdentifier

        let respSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        let getResponsiblePID: ((pid_t) -> pid_t)? = respSymbol != nil ? unsafeBitCast(respSymbol, to: ResponsibilityFunc.self) : nil

        var matchingIDs: [AudioObjectID] = []
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var processPID: pid_t = 0
            let pidStatus = AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID)

            guard pidStatus == noErr else { continue }

            if processPID == targetPID {
                matchingIDs.append(processID)
                continue
            }

            if let respPID = getResponsiblePID?(processPID), respPID == targetPID {
                matchingIDs.append(processID)
                continue
            }

            if let targetBundleID = targetBundleID {
                let processApp = NSRunningApplication(processIdentifier: processPID)
                if let processBundleID = processApp?.bundleIdentifier, processBundleID.hasPrefix(targetBundleID) {
                    matchingIDs.append(processID)
                    continue
                }
            }
        }
        return matchingIDs
    }

    static func getAudioActivePIDs() -> Set<pid_t> {
        var processListSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize)
        guard status == noErr else { return [] }

        let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)

        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs)
        guard status == noErr else { return [] }

        var activePIDs = Set<pid_t>()
        for processID in processIDs {
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var processPID: pid_t = 0
            let pidStatus = AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID)
            if pidStatus == noErr {
                activePIDs.insert(processPID)
            }
        }
        return activePIDs
    }
}
