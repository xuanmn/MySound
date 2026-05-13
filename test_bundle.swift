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
        var bundleAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(processID, &bundleAddress, 0, nil, &bundleSize)
        
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(processID, &bundleAddress, 0, nil, &size, &bundleID)
        
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processPID: pid_t = 0
        AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &processPID)
        
        print("PID \(processPID) -> Bundle: \(bundleID)")
    }
}
test()
