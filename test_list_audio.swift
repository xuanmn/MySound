import Foundation
import CoreAudio
import AppKit

func test() {
    var processListSize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize)
    guard status == noErr else { return }
    
    let count = Int(processListSize) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: count)
    
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &processListSize, &processIDs)
    
    for processID in processIDs {
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processPID: pid_t = 0
        AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID)
        
        if let app = NSRunningApplication(processIdentifier: processPID) {
            print("Found Audio Process: \(app.localizedName ?? "Unknown") (PID \(processPID)), AudioObjectID: \(processID)")
        }
    }
}
test()
