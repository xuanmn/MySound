import Foundation

public struct RecipesRegistry: Sendable {
    public static let allRecipes: [CodeRecipe] = [
        CodeRecipe(
            id: "process_tap_setup",
            title: "CoreAudio Process Tap Interception (macOS 14.2+)",
            category: "Process Taps",
            summary: "Configures CATapDescription with target process IDs and acquires an AudioObjectID tap from the HAL.",
            code: #"""
import Foundation
import CoreAudio

// 1. Dynamic Class Lookup for Private CATapDescription SPI
guard let tapDescClass = NSClassFromString("CATapDescription") as? NSObject.Type else {
    fatalError("CATapDescription SPI is not available on this macOS version (requires macOS 14.2+).")
}

// 2. Initialize CATapDescription targeting specific PID
let tapDesc = tapDescClass.init()
let targetPID: pid_t = 12345 // Target application PID
tapDesc.setValue([targetPID], forKey: "processes")
tapDesc.setValue(false, forKey: "mono")
tapDesc.setValue(false, forKey: "mixdown")

// 3. Create Process Tap via HAL
var tapID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateProcessTap(tapDesc, &tapID)

guard status == noErr else {
    print("Failed to create process tap: \(status)")
    // Status 560227702 (0x21646576) indicates missing System Audio Recording TCC permission.
    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
}

print("Created Process Tap AudioObjectID: \(tapID)")

// 4. Teardown when finished
// AudioHardwareDestroyProcessTap(tapID)
"""#,
            keyTakeaways: [
                "Requires 'System Audio Recording' TCC permission and disabled App Sandbox in Entitlements.plist.",
                "Always destroy the tap with AudioHardwareDestroyProcessTap when the target app quits.",
                "Tapping an app's audio stream prevents it from reaching the hardware output directly; you must route it through an aggregate device or playback stream."
            ]
        ),

        CodeRecipe(
            id: "aggregate_device_routing",
            title: "Aggregate Audio Device Creation & Output Routing",
            category: "Device Routing",
            summary: "Combines a process tap subdevice with a physical output hardware device into an Aggregate Device.",
            code: #"""
import Foundation
import CoreAudio

func createAggregateDevice(tapUID: String, outputUID: String) throws -> AudioDeviceID {
    let aggregateUID = "com.mysound.aggregate.\(UUID().uuidString)"
    let aggregateName = "MySound Virtual Output"

    let subDevices: [[String: Any]] = [
        [kAudioSubDeviceUIDKey: outputUID],
        [kAudioSubDeviceUIDKey: tapUID]
    ]

    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: aggregateName,
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceSubDeviceListKey: subDevices,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false
    ]

    var aggregateDeviceID: AudioDeviceID = 0
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)

    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    return aggregateDeviceID
}
"""#,
            keyTakeaways: [
                "kAudioAggregateDeviceMainSubDeviceKey determines the master clock source for the aggregate device.",
                "Marking kAudioAggregateDeviceIsPrivateKey as true hides the virtual device from macOS System Settings UI.",
                "Always destroy the aggregate device with AudioHardwareDestroyAggregateDevice when closing."
            ]
        ),

        CodeRecipe(
            id: "vdsp_gain_scaling",
            title: "In-Place Vectorized Audio Gain Scaling with vDSP",
            category: "Signal Processing",
            summary: "Applies volume scaling directly to raw PCM audio sample buffers on the real-time audio thread without memory allocation.",
            code: #"""
import Foundation
import CoreAudio
import Accelerate

/// Scales audio buffers in-place using Accelerate's SIMD vDSP_vsmul.
/// Real-Time Safe: Zero heap allocations, zero locks, zero Obj-C calls.
func applyVolumeGain(
    bufferList: UnsafeMutablePointer<AudioBufferList>,
    volumeScalar: Float
) {
    var gain = max(0.0, min(1.0, volumeScalar))
    let bufferCount = Int(bufferList.pointee.mNumberBuffers)
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

    for i in 0..<bufferCount {
        guard let rawSamples = buffers[i].mData else { continue }
        let sampleCount = Int(buffers[i].mDataByteSize) / MemoryLayout<Float>.size
        let floatSamples = rawSamples.assumingMemoryBound(to: Float.self)

        // Multiply vector floatSamples by scalar gain in-place
        vDSP_vsmul(
            floatSamples, 1,
            &gain,
            floatSamples, 1,
            vDSP_Length(sampleCount)
        )
    }
}
"""#,
            keyTakeaways: [
                "vDSP_vsmul executes in constant time using Apple Silicon NEON SIMD instructions.",
                "Zero memory is allocated during execution, preventing audio dropouts and glitches.",
                "Works for both non-interleaved channels and interleaved buffers with appropriate stride adjustments."
            ]
        ),

        CodeRecipe(
            id: "lock_free_volume_store",
            title: "Microsecond Lock-Protected Real-Time Volume Lookup",
            category: "Threading & Safety",
            summary: "Thread-safe scalar lookup using os_unfair_lock designed to safely bridge UI state and real-time audio threads.",
            code: #"""
import Foundation
import os

final class VolumeStore: @unchecked Sendable {
    private var _lock = os_unfair_lock_s()
    private var volumes: [pid_t: Float] = [:]

    /// Called from real-time audio callback.
    /// Fast microsecond scalar lookup without thread hopping or allocations.
    func get(_ pid: pid_t) -> Float {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return volumes[pid] ?? 1.0
    }

    /// Called from UI thread.
    func set(_ pid: pid_t, _ volume: Float) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        volumes[pid] = volume
    }

    /// Clean up on process termination.
    func remove(_ pid: pid_t) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        volumes.removeValue(forKey: pid)
    }
}
"""#,
            keyTakeaways: [
                "Never use Swift actors or async/await inside real-time audio callbacks.",
                "os_unfair_lock is a low-overhead, non-reentrant lock with priority inversion avoidance.",
                "Lookup returns a default scalar (1.0) immediately if the PID has not been explicitly configured."
            ]
        )
    ]
}
