import Foundation

public struct CoreAudioRegistry: Sendable {
    public static let allEntities: [AudioApiEntity] = [
        // =========================================================================
        // MARK: - Process Tap Private SPIs (macOS 14.2+)
        // =========================================================================
        AudioApiEntity(
            symbol: "CATapDescription",
            kind: .spiClass,
            framework: "CoreAudio",
            header: "Private CoreAudio SPI (macOS 14.2+ Sonoma / macOS 15+ Sequoia)",
            availability: "macOS 14.2+ (Sonoma)",
            isPrivateSPI: true,
            signature: "@objc(CATapDescription) public class CATapDescription : NSObject",
            summary: "Describes an audio process tap used to intercept per-application audio streams directly from the CoreAudio HAL.",
            parameters: [
                ParameterDoc(name: "processes", type: "[NSRunningApplication] / [pid_t]", description: "The target applications or process identifiers whose audio output will be tapped."),
                ParameterDoc(name: "mono", type: "Bool", description: "If true, downmixes intercepted multi-channel audio to mono."),
                ParameterDoc(name: "mixdown", type: "Bool", description: "If true, applies system mixdown to the tapped stream."),
                ParameterDoc(name: "privateTapDictionary", type: "[String: Any]", description: "Internal dictionary configuring process IDs, UUIDs, and tap isolation flags.")
            ],
            returnInfo: "Initializes a tap description instance to be passed to AudioHardwareCreateProcessTap.",
            requiredEntitlements: [
                "System Audio Recording TCC Permission",
                "com.apple.security.device.audio-input",
                "App Sandbox Disabled (or com.apple.security.temporary-exception.audio-device-access)"
            ],
            realTimeSafety: "Configuration object only. Allocate and configure on the Main/Coordinating thread. Never touch inside the real-time IO callback.",
            commonPitfalls: [
                "Instantiating CATapDescription without System Audio Recording permission returns an invalid description or causes AudioHardwareCreateProcessTap to return 0x6e6f7065 ('nope') or 560227702.",
                "If the target process terminates while a tap is active, the tap must be destroyed using AudioHardwareDestroyProcessTap to prevent memory and AudioObjectID leaks in coreaudiod.",
                "Intercepting an app's tap mutes its direct hardware output unless you route the audio to an aggregate device or loopback device."
            ],
            relatedSymbols: ["AudioHardwareCreateProcessTap", "AudioHardwareDestroyProcessTap", "AudioHardwareCreateAggregateDevice"]
        ),

        AudioApiEntity(
            symbol: "AudioHardwareCreateProcessTap",
            kind: .function,
            framework: "CoreAudio",
            header: "Private CoreAudio SPI (AudioHardware.h extension)",
            availability: "macOS 14.2+ (Sonoma)",
            isPrivateSPI: true,
            signature: "func AudioHardwareCreateProcessTap(_ description: CATapDescription, _ outTapID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus",
            summary: "Creates a CoreAudio process tap object (`AudioObjectID`) corresponding to the given CATapDescription.",
            parameters: [
                ParameterDoc(name: "description", type: "CATapDescription", description: "The tap configuration describing targeted process IDs and channel layout."),
                ParameterDoc(name: "outTapID", type: "UnsafeMutablePointer<AudioObjectID>", description: "Pointer to receive the created tap's AudioObjectID.")
            ],
            returnInfo: "Returns `noErr` (0) on success, or an OSStatus error code (e.g. 560227702, kAudioHardwareIllegalOperationError).",
            requiredEntitlements: [
                "System Audio Recording TCC Permission",
                "com.apple.security.device.audio-input"
            ],
            realTimeSafety: "Must be called on a setup/coordination thread. Blocking IPC call to coreaudiod.",
            commonPitfalls: [
                "Failing to destroy the tap when the tapped process dies leaks virtual tap objects in coreaudiod.",
                "Requires dynamic symbol resolution via dlsym or Objective-C runtime linkage if building with strict SDK header enforcement."
            ],
            relatedSymbols: ["CATapDescription", "AudioHardwareDestroyProcessTap"]
        ),

        AudioApiEntity(
            symbol: "AudioHardwareDestroyProcessTap",
            kind: .function,
            framework: "CoreAudio",
            header: "Private CoreAudio SPI (AudioHardware.h extension)",
            availability: "macOS 14.2+ (Sonoma)",
            isPrivateSPI: true,
            signature: "func AudioHardwareDestroyProcessTap(_ tapID: AudioObjectID) -> OSStatus",
            summary: "Destroys a previously created process tap and frees its allocated resources in the HAL.",
            parameters: [
                ParameterDoc(name: "tapID", type: "AudioObjectID", description: "The identifier of the tap returned by AudioHardwareCreateProcessTap.")
            ],
            returnInfo: "Returns `noErr` (0) on success, or an OSStatus error code.",
            requiredEntitlements: [],
            realTimeSafety: "Must be called on a background/management thread, never inside an audio IO proc.",
            commonPitfalls: [
                "Calling destroy while an IOProc or Aggregate Device is actively reading the tap can cause coreaudiod watchdog resets."
            ],
            relatedSymbols: ["AudioHardwareCreateProcessTap", "CATapDescription"]
        ),

        // =========================================================================
        // MARK: - Aggregate Devices
        // =========================================================================
        AudioApiEntity(
            symbol: "AudioHardwareCreateAggregateDevice",
            kind: .function,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func AudioHardwareCreateAggregateDevice(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioDeviceID>) -> OSStatus",
            summary: "Creates a virtual aggregate audio device combining multiple physical and/or tap subdevices into a unified audio endpoint.",
            parameters: [
                ParameterDoc(name: "inDescription", type: "CFDictionary", description: "Dictionary specifying aggregate device properties (UID, Name, SubDeviceList, MasterSubDevice)."),
                ParameterDoc(name: "outDeviceID", type: "UnsafeMutablePointer<AudioDeviceID>", description: "Pointer to receive the created aggregate AudioDeviceID.")
            ],
            returnInfo: "Returns `noErr` (0) on success.",
            requiredEntitlements: [],
            realTimeSafety: "High-overhead configuration call. Never call on real-time thread.",
            commonPitfalls: [
                "Subdevice list dictionary must contain the UID string of every member device, not raw AudioDeviceIDs.",
                "Must be destroyed with AudioHardwareDestroyAggregateDevice when no longer needed."
            ],
            relatedSymbols: ["AudioHardwareDestroyAggregateDevice", "kAudioHardwarePropertyDevices"]
        ),

        AudioApiEntity(
            symbol: "AudioHardwareDestroyAggregateDevice",
            kind: .function,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func AudioHardwareDestroyAggregateDevice(_ inDeviceID: AudioDeviceID) -> OSStatus",
            summary: "Tears down and destroys an aggregate device created via AudioHardwareCreateAggregateDevice.",
            parameters: [
                ParameterDoc(name: "inDeviceID", type: "AudioDeviceID", description: "The identifier of the aggregate device.")
            ],
            returnInfo: "Returns `noErr` (0) on success.",
            requiredEntitlements: [],
            realTimeSafety: "Must not be called on audio real-time thread.",
            commonPitfalls: [
                "Destroying an aggregate device while active audio IO is running can cause audio dropouts or driver crashes."
            ],
            relatedSymbols: ["AudioHardwareCreateAggregateDevice"]
        ),

        // =========================================================================
        // MARK: - Audio Object Properties (HAL)
        // =========================================================================
        AudioApiEntity(
            symbol: "AudioObjectGetPropertyData",
            kind: .function,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func AudioObjectGetPropertyData(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>, _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?, _ ioDataSize: UnsafeMutablePointer<UInt32>, _ outData: UnsafeMutableRawPointer) -> OSStatus",
            summary: "Queries property data from a CoreAudio HAL object (System Object, Device, Stream, or Tap).",
            parameters: [
                ParameterDoc(name: "inObjectID", type: "AudioObjectID", description: "Target object ID (e.g. AudioObjectID(kAudioObjectSystemObject))."),
                ParameterDoc(name: "inAddress", type: "UnsafePointer<AudioObjectPropertyAddress>", description: "Pointer to selector, scope, and element address."),
                ParameterDoc(name: "inQualifierDataSize", type: "UInt32", description: "Size of qualifier data in bytes (usually 0)."),
                ParameterDoc(name: "inQualifierData", type: "UnsafeRawPointer?", description: "Qualifier data buffer (usually nil)."),
                ParameterDoc(name: "ioDataSize", type: "UnsafeMutablePointer<UInt32>", description: "Size of output buffer in bytes; updated with actual size written."),
                ParameterDoc(name: "outData", type: "UnsafeMutableRawPointer", description: "Memory buffer to store the retrieved property value.")
            ],
            returnInfo: "Returns `noErr` (0) on success, or an OSStatus error code.",
            requiredEntitlements: [],
            realTimeSafety: "Most HAL properties acquire internal locks. Avoid calling in real-time audio threads.",
            commonPitfalls: [
                "Passing an uninitialized or smaller ioDataSize than the property requires causes kAudioHardwareBadPropertySizeError (561211770).",
                "Ensure correct AudioObjectPropertyScope (kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput, or kAudioDevicePropertyScopeInput)."
            ],
            relatedSymbols: ["AudioObjectSetPropertyData", "AudioObjectAddPropertyListener"]
        ),

        AudioApiEntity(
            symbol: "AudioObjectSetPropertyData",
            kind: .function,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func AudioObjectSetPropertyData(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>, _ inQualifierDataSize: UInt32, _ inQualifierData: UnsafeRawPointer?, _ inDataSize: UInt32, _ inData: UnsafeRawPointer) -> OSStatus",
            summary: "Sets property data on a CoreAudio HAL object (such as setting the default output device or device volume).",
            parameters: [
                ParameterDoc(name: "inObjectID", type: "AudioObjectID", description: "Target object ID."),
                ParameterDoc(name: "inAddress", type: "UnsafePointer<AudioObjectPropertyAddress>", description: "Property address specifying selector, scope, and element."),
                ParameterDoc(name: "inQualifierDataSize", type: "UInt32", description: "Qualifier size (usually 0)."),
                ParameterDoc(name: "inQualifierData", type: "UnsafeRawPointer?", description: "Qualifier data (usually nil)."),
                ParameterDoc(name: "inDataSize", type: "UInt32", description: "Size of property data buffer in bytes."),
                ParameterDoc(name: "inData", type: "UnsafeRawPointer", description: "Pointer to the new property value.")
            ],
            returnInfo: "Returns `noErr` (0) on success.",
            requiredEntitlements: [],
            realTimeSafety: "Never call on real-time thread.",
            commonPitfalls: [
                "Attempting to set read-only properties returns kAudioHardwareUnsupportedOperationError."
            ],
            relatedSymbols: ["AudioObjectGetPropertyData"]
        ),

        AudioApiEntity(
            symbol: "AudioObjectAddPropertyListener",
            kind: .function,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func AudioObjectAddPropertyListener(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>, _ inListener: AudioObjectPropertyListenerProc, _ inClientData: UnsafeMutableRawPointer?) -> OSStatus",
            summary: "Registers an asynchronous callback to be notified whenever a property of an AudioObject changes (e.g. default device switch, mute toggle).",
            parameters: [
                ParameterDoc(name: "inObjectID", type: "AudioObjectID", description: "Target AudioObjectID to observe."),
                ParameterDoc(name: "inAddress", type: "UnsafePointer<AudioObjectPropertyAddress>", description: "Property address to monitor."),
                ParameterDoc(name: "inListener", type: "AudioObjectPropertyListenerProc", description: "C-function pointer callback executed when the property changes."),
                ParameterDoc(name: "inClientData", type: "UnsafeMutableRawPointer?", description: "Arbitrary context pointer (e.g. Unmanaged.passUnretained(self).toOpaque()).")
            ],
            returnInfo: "Returns `noErr` (0) on success.",
            requiredEntitlements: [],
            realTimeSafety: "Safe to register during component setup. The listener callback executes on an internal HAL dispatch queue.",
            commonPitfalls: [
                "Must remove listener with AudioObjectRemovePropertyListener before the client context object is deallocated to avoid wild pointer crashes.",
                "Listener callbacks run on an arbitrary background queue; dispatch to MainActor if modifying UI state."
            ],
            relatedSymbols: ["AudioObjectRemovePropertyListener", "AudioObjectGetPropertyData"]
        ),

        AudioApiEntity(
            symbol: "AudioObjectRemovePropertyListener",
            kind: .function,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func AudioObjectRemovePropertyListener(_ inObjectID: AudioObjectID, _ inAddress: UnsafePointer<AudioObjectPropertyAddress>, _ inListener: AudioObjectPropertyListenerProc, _ inClientData: UnsafeMutableRawPointer?) -> OSStatus",
            summary: "Unregisters a property listener previously registered via AudioObjectAddPropertyListener.",
            parameters: [
                ParameterDoc(name: "inObjectID", type: "AudioObjectID", description: "AudioObjectID being observed."),
                ParameterDoc(name: "inAddress", type: "UnsafePointer<AudioObjectPropertyAddress>", description: "Monitored property address."),
                ParameterDoc(name: "inListener", type: "AudioObjectPropertyListenerProc", description: "Callback function pointer."),
                ParameterDoc(name: "inClientData", type: "UnsafeMutableRawPointer?", description: "Context pointer matching the registration call.")
            ],
            returnInfo: "Returns `noErr` (0) on success.",
            requiredEntitlements: [],
            realTimeSafety: "Safe to call in teardown/deinit.",
            commonPitfalls: [
                "Address selector, scope, and element MUST match the registration address exactly."
            ],
            relatedSymbols: ["AudioObjectAddPropertyListener"]
        ),

        // =========================================================================
        // MARK: - Well-Known HAL Property Selectors
        // =========================================================================
        AudioApiEntity(
            symbol: "kAudioHardwarePropertyDefaultOutputDevice",
            kind: .halProperty,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "var kAudioHardwarePropertyDefaultOutputDevice: AudioObjectPropertySelector { get } // 'dOut'",
            summary: "Property selector on kAudioObjectSystemObject representing the current default system audio output device ID.",
            parameters: [],
            returnInfo: "Property data is AudioDeviceID.",
            requiredEntitlements: [],
            realTimeSafety: "Read during device setup or property change notification.",
            commonPitfalls: [
                "Scope must be kAudioObjectPropertyScopeGlobal; Element must be kAudioObjectPropertyElementMain."
            ],
            relatedSymbols: ["AudioObjectGetPropertyData", "kAudioHardwarePropertyDevices"]
        ),

        AudioApiEntity(
            symbol: "kAudioHardwarePropertyDevices",
            kind: .halProperty,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "var kAudioHardwarePropertyDevices: AudioObjectPropertySelector { get } // 'dev#'",
            summary: "Property selector on kAudioObjectSystemObject listing all active audio device IDs available to the system.",
            parameters: [],
            returnInfo: "Property data is an array of AudioDeviceID values.",
            requiredEntitlements: [],
            realTimeSafety: "Query during hardware discovery.",
            commonPitfalls: [
                "Array length is dynamic: always call AudioObjectGetPropertyDataSize first to allocate sufficient buffer capacity."
            ],
            relatedSymbols: ["AudioObjectGetPropertyData", "kAudioHardwarePropertyDefaultOutputDevice"]
        ),

        AudioApiEntity(
            symbol: "kAudioDevicePropertyMute",
            kind: .halProperty,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "var kAudioDevicePropertyMute: AudioObjectPropertySelector { get } // 'mute'",
            summary: "Property selector on an AudioDeviceID indicating or setting mute state (0 = unmuted, 1 = muted).",
            parameters: [],
            returnInfo: "Property data is UInt32 (0 or 1).",
            requiredEntitlements: [],
            realTimeSafety: "Non-real-time control property.",
            commonPitfalls: [
                "Scope must be kAudioDevicePropertyScopeOutput."
            ],
            relatedSymbols: ["kAudioDevicePropertyVolumeScalar"]
        ),

        AudioApiEntity(
            symbol: "kAudioDevicePropertyVolumeScalar",
            kind: .halProperty,
            framework: "CoreAudio",
            header: "<CoreAudio/AudioHardware.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "var kAudioDevicePropertyVolumeScalar: AudioObjectPropertySelector { get } // 'vmuc'",
            summary: "Property selector on an AudioDeviceID representing linear hardware master volume as a float between 0.0 and 1.0.",
            parameters: [],
            returnInfo: "Property data is Float32.",
            requiredEntitlements: [],
            realTimeSafety: "Non-real-time control property.",
            commonPitfalls: [
                "Some external displays or digital optical outputs do not support hardware volume control and will return kAudioHardwareUnknownPropertyError."
            ],
            relatedSymbols: ["kAudioDevicePropertyMute"]
        ),

        // =========================================================================
        // MARK: - Audio Buffer Signal Math (Accelerate vDSP)
        // =========================================================================
        AudioApiEntity(
            symbol: "vDSP_vsmul",
            kind: .function,
            framework: "Accelerate (vDSP)",
            header: "<Accelerate/Accelerate.h>",
            availability: "macOS 10.0+",
            isPrivateSPI: false,
            signature: "func vDSP_vsmul(_ __A: UnsafePointer<Float>, _ __IA: vDSP_Stride, _ __B: UnsafePointer<Float>, _ __C: UnsafeMutablePointer<Float>, _ __IC: vDSP_Stride, _ __N: vDSP_Length)",
            summary: "Multiplies a single-precision floating-point vector by a scalar float using high-speed SIMD hardware instructions. Primary building block for real-time audio gain scaling.",
            parameters: [
                ParameterDoc(name: "__A", type: "UnsafePointer<Float>", description: "Input audio buffer sample array."),
                ParameterDoc(name: "__IA", type: "vDSP_Stride", description: "Stride for input vector (usually 1 for contiguous non-interleaved channels)."),
                ParameterDoc(name: "__B", type: "UnsafePointer<Float>", description: "Pointer to the scalar multiplier (gain factor 0.0...1.0)."),
                ParameterDoc(name: "__C", type: "UnsafeMutablePointer<Float>", description: "Output buffer sample array (can be identical to __A for in-place scaling)."),
                ParameterDoc(name: "__IC", type: "vDSP_Stride", description: "Stride for output vector (usually 1)."),
                ParameterDoc(name: "__N", type: "vDSP_Length", description: "Number of audio frames/samples to process.")
            ],
            returnInfo: "Processes vector in-place or into destination buffer with zero memory allocations.",
            requiredEntitlements: [],
            realTimeSafety: "Fully real-time safe. Deterministic execution time, SIMD hardware accelerated, zero allocation, non-blocking.",
            commonPitfalls: [
                "Ensure buffer pointers are properly aligned and not overlapping if __C != __A.",
                "Verify frame count matches mBuffers[channel].mDataByteSize / MemoryLayout<Float>.size."
            ],
            relatedSymbols: ["vDSP_maxv", "AudioBufferList"]
        )
    ]
}
