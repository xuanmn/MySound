import Foundation
import CoreAudio

/// This class acts as the bridge between our Swift UI and the BackgroundMusic C++ Audio Driver.
class AudioEngine {

    /// Installs the virtual audio driver bundled with the app if it's missing from the system.
    static func installDriverIfNeeded() {
        let systemPluginPath = "/Library/Audio/Plug-Ins/HAL/Background Music Device.driver"
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: systemPluginPath) {
            print("Driver is already installed.")
            return
        }

        print("Driver not found. Preparing to install...")
        guard let bundleDriverPath = Bundle.main.url(forResource: "Background Music Device", withExtension: "driver")?.path else {
            print("Error: Could not find driver in app bundle!")
            return
        }

        let script = """
        do shell script "cp -R '\(bundleDriverPath)' '/Library/Audio/Plug-Ins/HAL/' && killall coreaudiod" with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("Failed to install driver: \(error)")
            } else {
                print("Successfully installed driver and restarted CoreAudio!")
            }
        }
    }

    /// Finds the "Background Music" virtual audio device installed by the driver.
    static func getBackgroundMusicDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return nil }

        // Look for the "Background Music" device
        for deviceID in deviceIDs {
            if getDeviceName(deviceID: deviceID) == "Background Music" {
                return deviceID
            }
        }

        return nil
    }

    /// Changes the volume of a specific running application using its Process ID (PID).
    static func setVolume(forAppPID pid: pid_t, volume: Float) {
        guard let bgmDeviceID = getBackgroundMusicDeviceID() else {
            print("Background Music device not found. Make sure it is installed and running.")
            return
        }

        // 'vApp' is the secret custom property defined by the BackgroundMusic C++ driver
        // to handle per-application volumes.
        // In CoreAudio, 'vApp' translates to the integer 1986097264
        let bgmAppVolumePropertySelector: AudioObjectPropertySelector = 1986097264

        var address = AudioObjectPropertyAddress(
            mSelector: bgmAppVolumePropertySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // We pass the application's PID as the "qualifier" to tell the driver WHICH app to change
        var targetPID = pid
        let qualifierDataSize = UInt32(MemoryLayout<pid_t>.size)

        // We pass the volume (0.0 to 1.0) as the "data"
        var targetVolume = Float32(volume)
        let dataSize = UInt32(MemoryLayout<Float32>.size)

        // Send the command directly into the macOS CoreAudio framework!
        let status = AudioObjectSetPropertyData(
            bgmDeviceID,
            &address,
            qualifierDataSize,
            &targetPID,
            dataSize,
            &targetVolume
        )

        if status != noErr {
            print("Failed to set volume for PID \(pid). CoreAudio Error: \(status)")
        } else {
            print("Successfully set PID \(pid) to volume \(volume)")
        }
    }

    // --- Helper Function ---
    private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        if status == noErr, let name = name {
            return name.takeRetainedValue() as String
        }
        return nil
    }
}
