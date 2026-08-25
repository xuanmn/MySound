import Foundation
import CoreAudio

// =============================================================================
// MARK: - Audio Device Transport Type
// =============================================================================

/// Hardware transport mechanism used to connect the audio output device.
enum AudioDeviceTransportType: String, Equatable, CaseIterable, Sendable {
    case builtIn = "Built-in"
    case bluetooth = "Bluetooth"
    case usb = "USB"
    case hdmi = "HDMI"
    case displayPort = "DisplayPort"
    case airPlay = "AirPlay"
    case thunderbolt = "Thunderbolt"
    case pci = "PCI"
    case fireWire = "FireWire"
    case virtual = "Virtual"
    case unknown = "Audio Device"

    /// Maps CoreAudio 4-character transport codes (`kAudioDevicePropertyTransportType`) to typed enum.
    static func from(fourCC: UInt32) -> AudioDeviceTransportType {
        switch fourCC {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeHDMI:
            return .hdmi
        case kAudioDeviceTransportTypeDisplayPort:
            return .displayPort
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeThunderbolt:
            return .thunderbolt
        case kAudioDeviceTransportTypePCI:
            return .pci
        case kAudioDeviceTransportTypeFireWire:
            return .fireWire
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return .virtual
        default:
            return .unknown
        }
    }
}

// =============================================================================
// MARK: - Audio Output Device Model
// =============================================================================

/// Encapsulates a hardware audio output device (e.g. MacBook Speakers, AirPods, External DAC).
struct AudioOutputDevice: Identifiable, Hashable, Equatable, Sendable {
    /// CoreAudio AudioDeviceID (HAL integer identifier).
    let id: AudioDeviceID
    /// User-friendly name (e.g. "MacBook Pro Speakers", "AirPods Pro").
    let name: String
    /// Unique persistent string identifier (e.g. "BuiltInSpeakerDevice", Bluetooth MAC address).
    let uid: String
    /// Hardware transport bus type.
    let transportType: AudioDeviceTransportType

    init(id: AudioDeviceID, name: String, uid: String, transportType: AudioDeviceTransportType = .unknown) {
        self.id = id
        self.name = name
        self.uid = uid
        self.transportType = transportType
    }

    /// Resolves an appropriate SF Symbol icon name based on transport type and device name.
    var iconName: String {
        let lower = name.lowercased()
        if lower.contains("airpod max") {
            return "headphones"
        } else if lower.contains("airpod") {
            return "airpodspro"
        } else if lower.contains("beats") || lower.contains("headphone") || lower.contains("headset") || lower.contains("earphone") {
            return "headphones"
        } else if lower.contains("homepod") {
            return "homepod.fill"
        } else if lower.contains("hdmi") || lower.contains("tv") || lower.contains("television") {
            return "tv"
        } else if lower.contains("studio display") || lower.contains("pro display") || lower.contains("displayport") || lower.contains("monitor") {
            return "display"
        } else if transportType == .bluetooth {
            return "beats.headphones"
        } else if transportType == .usb {
            return "hifispeaker.fill"
        } else if transportType == .builtIn {
            if lower.contains("imac") || lower.contains("mac pro") || lower.contains("mac mini") || lower.contains("desktop") {
                return "desktopcomputer"
            }
            return "laptopcomputer"
        } else if transportType == .airPlay {
            return "airplayaudio"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    static func == (lhs: AudioOutputDevice, rhs: AudioOutputDevice) -> Bool {
        lhs.id == rhs.id && lhs.uid == rhs.uid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(uid)
    }
}
