import CoreAudio
import Foundation

class AudioTapManager: ObservableObject {
    @Published var activeTaps: [pid_t: AudioObjectID] = [:]

    func createTap(for pid: pid_t) {
        // Avoid creating duplicate taps
        if activeTaps[pid] != nil { return }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(pid)])
        // Optional: mute the original process so we can control it ourselves
        // tapDescription.muteBehavior = .muted

        var tapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        if status == noErr {
            print("Successfully created tap \(tapID) for PID \(pid)")
            DispatchQueue.main.async {
                self.activeTaps[pid] = tapID
            }
        } else {
            print("Failed to create tap for PID \(pid): \(status)")
        }
    }

    func removeTap(for pid: pid_t) {
        guard let tapID = activeTaps[pid] else { return }

        let status = AudioHardwareDestroyProcessTap(tapID)
        if status == noErr {
            print("Successfully destroyed tap \(tapID)")
            DispatchQueue.main.async {
                self.activeTaps.removeValue(forKey: pid)
            }
        } else {
            print("Failed to destroy tap \(tapID): \(status)")
        }
    }
}
