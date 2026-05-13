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
        
        if activeTaps[pid] == nil {
            Task { @MainActor in
                createTap(for: pid)
            }
        }
    }
    
    private func getVolume(for pid: pid_t) -> Float {
        volumeLock.lock()
        let vol = volumes[pid] ?? 1.0
        volumeLock.unlock()
        return vol
    }
    
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
            kAudioAggregateDeviceNameKey: "MySound-Tap-\(pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        
        var aggID: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
        
        guard status == noErr else {
            print("ERROR: Failed to create aggregate device for PID \(pid): \(status)")
            _ = AudioHardwareDestroyProcessTap(tapID)
            return
        }
        
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] (now, inputData, inputTime, outputData, outputTime) in
            guard let self = self else { return }
            let volume = self.getVolume(for: pid)
            
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            
            let inputBufferCount = inputs.count
            let outputBufferCount = outputs.count
            
            for outputIndex in 0..<outputBufferCount {
                let outputBuffer = outputs[outputIndex]
                guard let dst = outputBuffer.mData else { continue }
                
                let inputIndex: Int
                if inputBufferCount > outputBufferCount {
                    inputIndex = inputBufferCount - outputBufferCount + outputIndex
                } else {
                    inputIndex = outputIndex
                }
                
                guard inputIndex < inputBufferCount, let src = inputs[inputIndex].mData else {
                    memset(dst, 0, Int(outputBuffer.mDataByteSize))
                    continue
                }
                
                let frameCount = Int(inputs[inputIndex].mDataByteSize) / MemoryLayout<Float>.size
                let srcFloat = src.assumingMemoryBound(to: Float.self)
                let dstFloat = dst.assumingMemoryBound(to: Float.self)
                
                for f in 0..<frameCount {
                    dstFloat[f] = srcFloat[f] * volume
                }
            }
        }
        
        if status == noErr, let proc = procID {
            _ = AudioDeviceStart(aggID, proc)
            activeTaps[pid] = TapState(tapID: tapID, aggregateID: aggID, procID: proc)
            print("SUCCESS: Started Aggregate IO Proc for PID \(pid)")
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
}
