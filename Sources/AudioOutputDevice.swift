import CoreAudio

// =============================================================================
// MARK: - Audio Output Device Model
// =============================================================================

/// Encapsulates a hardware audio output device (e.g. MacBook Speakers, AirPods, External DAC).
struct AudioOutputDevice: Identifiable, Hashable, Equatable {
    /// CoreAudio AudioDeviceID (HAL integer identifier).
    let id: AudioDeviceID
    /// User-friendly name (e.g. "MacBook Pro Speakers", "AirPods Pro").
    let name: String
    /// Unique persistent string identifier (e.g. "BuiltInSpeakerDevice", Bluetooth address).
    let uid: String

    static func == (lhs: AudioOutputDevice, rhs: AudioOutputDevice) -> Bool {
        lhs.id == rhs.id && lhs.uid == rhs.uid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
    }
}
