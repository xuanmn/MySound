import Foundation
import CoreAudio
import AppKit

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

    /// Launches the Background Music daemon app bundled in our resources.
    static func launchDaemonIfNeeded() {
        let runningApps = NSWorkspace.shared.runningApplications
        if runningApps.contains(where: { $0.bundleIdentifier == "com.bearisdriving.BGM.App" }) {
            print("Daemon is already running.")
            return
        }

        guard let daemonURL = Bundle.main.url(forResource: "Background Music", withExtension: "app") else {
            print("Failed to find Background Music daemon in bundle.")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.addsToRecentItems = false
        config.hides = true

        NSWorkspace.shared.openApplication(at: daemonURL, configuration: config) { app, error in
            if let error = error {
                print("Failed to launch daemon: \(error)")
            } else {
                print("Successfully launched background audio daemon!")
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

    /// Sets "Background Music" as the default system output device so it can intercept audio.
    static func setAsDefaultOutputDevice() {
        guard let bgmDeviceID = getBackgroundMusicDeviceID() else {
            print("Background Music device not found. Cannot set as default.")
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = bgmDeviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &deviceID
        )

        if status == noErr {
            print("Successfully set Background Music as default output device.")
        } else {
            print("Failed to set default output device. Error: \(status)")
        }
    }

    // Expose the C function from libproc to get child processes
    @_silgen_name("proc_listchildpids")
    private static func proc_listchildpids(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

    private static func getChildPIDs(of pid: pid_t) -> [pid_t] {
        let maxPIDs = 1024
        var pids = [pid_t](repeating: 0, count: maxPIDs)
        let bytes = proc_listchildpids(pid, &pids, Int32(maxPIDs * MemoryLayout<pid_t>.stride))
        let count = Int(bytes) / MemoryLayout<pid_t>.stride
        if count > 0 {
            return Array(pids[0..<count])
        }
        return []
    }

    private static func getAllDescendantPIDs(of pid: pid_t) -> [pid_t] {
        var descendants = [pid_t]()
        let children = getChildPIDs(of: pid)
        descendants.append(contentsOf: children)
        for child in children {
            descendants.append(contentsOf: getAllDescendantPIDs(of: child))
        }
        return descendants
    }

    /// Changes the volume of a specific running application using its Process ID (PID), including all child helper processes.
    static func setVolume(forAppPID pid: pid_t, volume: Float) {
        guard let bgmDeviceID = getBackgroundMusicDeviceID() else {
            print("Background Music device not found. Make sure it is installed and running.")
            return
        }

        // 'vApp' is the secret custom property defined by the BackgroundMusic C++ driver
        let bgmAppVolumePropertySelector: AudioObjectPropertySelector = 1986097264

        var address = AudioObjectPropertyAddress(
            mSelector: bgmAppVolumePropertySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let allPIDs = [pid] + getAllDescendantPIDs(of: pid)

        for targetPID in allPIDs {
            var tempPID = targetPID
            let qualifierDataSize = UInt32(MemoryLayout<pid_t>.size)

            var targetVolume = Float32(volume)
            let dataSize = UInt32(MemoryLayout<Float32>.size)

            AudioObjectSetPropertyData(
                bgmDeviceID,
                &address,
                qualifierDataSize,
                &tempPID,
                dataSize,
                &targetVolume
            )
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
