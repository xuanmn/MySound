import CoreAudio
import Foundation

var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

var deviceID: AudioDeviceID = 0
var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)

var nameAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceNameCFString,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var name: Unmanaged<CFString>?
var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
if let devName = name?.takeRetainedValue() as String? {
    print("Current output device: \(devName)")
} else {
    print("Unknown output device")
}
