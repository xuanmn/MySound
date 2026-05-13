import Foundation
import CoreAudio

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
        
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(pid)])
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
            
            for i in 0..<min(inputs.count, outputs.count) {
                if let src = inputs[i].mData, let dst = outputs[i].mData {
                    let frameCount = Int(inputs[i].mDataByteSize) / MemoryLayout<Float>.size
                    let srcFloat = src.assumingMemoryBound(to: Float.self)
                    let dstFloat = dst.assumingMemoryBound(to: Float.self)
                    
                    for f in 0..<frameCount {
                        dstFloat[f] = srcFloat[f] * volume
                    }
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
            var uid: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            
            status = AudioObjectGetPropertyData(
                defaultOutputDeviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                &uid)
            
            if status == noErr, let uidString = uid {
                return uidString as String
            }
        }
        return nil
    }
}
