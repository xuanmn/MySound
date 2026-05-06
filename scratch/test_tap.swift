import CoreAudio
import Foundation

print("Checking Core Audio Tap API availability...")

let tapDescription = CATapDescription(stereoMixdownOfProcesses: [123])
var tapID: AudioObjectID = 0
let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
print("Status: \(status), TapID: \(tapID)")
