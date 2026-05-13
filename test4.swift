import Foundation
import CoreAudio

@_silgen_name("AudioDeviceCreateIOProcIDWithBlock")
func AudioDeviceCreateIOProcIDWithBlock(_ inDevice: AudioObjectID, _ inClientPID: pid_t?, _ outProcID: UnsafeMutablePointer<AudioDeviceIOProcID?>, _ inBlock: @escaping AudioDeviceIOBlock) -> OSStatus

func test() {
    var procID: AudioDeviceIOProcID?
    var tapID: AudioObjectID = 0
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, tapID, nil) { (now, inputData, inputTime, outputData, outputTime) in
    }
}
