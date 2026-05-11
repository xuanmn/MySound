import Foundation
import AVFoundation
import CoreAudio

// Declare private Core Audio functions
@_silgen_name("AudioHardwareCreateProcessTap")
func AudioHardwareCreateProcessTap(_ description: CATapDescription, _ tapID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus

@_silgen_name("AudioHardwareDestroyProcessTap")
func AudioHardwareDestroyProcessTap(_ tapID: AudioObjectID) -> OSStatus

@_silgen_name("AudioDeviceCreateIOProcIDWithBlock")
func AudioDeviceCreateIOProcIDWithBlock(_ inDevice: AudioObjectID, _ inClientPID: pid_t?, _ outProcID: UnsafeMutablePointer<AudioDeviceIOProcID?>, _ inBlock: @escaping AudioDeviceIOBlock) -> OSStatus

@_silgen_name("AudioDeviceStart")
func AudioDeviceStart(_ inDevice: AudioObjectID, _ inProcID: AudioDeviceIOProcID?) -> OSStatus

@_silgen_name("AudioDeviceStop")
func AudioDeviceStop(_ inDevice: AudioObjectID, _ inProcID: AudioDeviceIOProcID?) -> OSStatus

typealias AudioDeviceIOBlock = (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

@MainActor
class AudioTapManager: NSObject, ObservableObject {
    @Published var activeTaps: [pid_t: AudioObjectID] = [:]
    private var ioProcs: [pid_t: AudioDeviceIOProcID] = [:]
    
    // Callback for when we receive audio data - called from real-time audio thread
    nonisolated(unsafe) var onAudioBuffer: ((pid_t, UnsafePointer<AudioBufferList>) -> Void)?
    
    func createTap(for pid: pid_t) {
        if activeTaps[pid] != nil { return }
        
        let description = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(pid)])
        description.uuid = UUID()
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        description.isPrivate = true
        
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        
        if status == noErr {
            activeTaps[pid] = tapID
            print("SUCCESS: Created Process Tap for PID \(pid), TapID: \(tapID)")
            
            setupIOProc(for: pid, tapID: tapID)
        } else {
            print("ERROR: Failed to create process tap for PID \(pid): \(status)")
        }
    }
    
    private func setupIOProc(for pid: pid_t, tapID: AudioObjectID) {
        var procID: AudioDeviceIOProcID?
        
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, tapID, nil) { [weak self] (now, inputData, inputTime, outputData, outputTime) in
            // This is called on a real-time thread
            self?.onAudioBuffer?(pid, inputData)
        }
        
        if status == noErr, let proc = procID {
            ioProcs[pid] = proc
            _ = AudioDeviceStart(tapID, proc)
            print("SUCCESS: Started IO Proc for PID \(pid)")
        } else {
            print("ERROR: Failed to create IO Proc for PID \(pid): \(status)")
        }
    }
    
    func removeTap(for pid: pid_t) {
        guard let tapID = activeTaps[pid] else { return }
        
        if let proc = ioProcs[pid] {
            _ = AudioDeviceStop(tapID, proc)
            ioProcs.removeValue(forKey: pid)
        }
        
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status == noErr {
            activeTaps.removeValue(forKey: pid)
            print("SUCCESS: Destroyed Process Tap for PID \(pid)")
        } else {
            print("ERROR: Failed to destroy process tap for PID \(pid): \(status)")
        }
    }
}


