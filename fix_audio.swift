import CoreAudio
import Foundation

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var dataSize: UInt32 = 0
var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)

let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)

var builtInDevice: AudioDeviceID? = nil

for deviceID in deviceIDs {
    var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr {
        if let devName = name?.takeRetainedValue() as String? {
            if devName.contains("MacBook") || devName.contains("Built-in") || devName.contains("Speaker") {
                builtInDevice = deviceID
                break
            }
        }
    }
}

if let target = builtInDevice {
    var targetID = target
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &targetID)
    print("Fixed: Reverted back to Built-in speakers")
} else {
    // If not found, just grab the first device that isn't Background Music
    for deviceID in deviceIDs {
        var targetID = deviceID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &targetID)
        break // just set first and pray
    }
}
