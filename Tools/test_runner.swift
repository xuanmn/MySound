import Foundation
import CoreAudio

// Test harness for MySound bug fixes and safety checks

func testDictionaryCleanupSafety() {
    print("[TEST] testDictionaryCleanupSafety...")
    var activeTaps: [pid_t: UInt32] = [
        1001: 42,
        1002: 42, // Helper process sharing same tapID 42
        1003: 99
    ]

    let targetTapID: UInt32 = 42

    // Demonstrate safe snapshotting pattern that avoids mutating collection during iteration
    let keysToRemove = activeTaps.filter { $0.value == targetTapID }.map(\.key)
    for key in keysToRemove {
        activeTaps.removeValue(forKey: key)
    }

    assert(activeTaps[1001] == nil, "PID 1001 should be removed")
    assert(activeTaps[1002] == nil, "PID 1002 should be removed")
    assert(activeTaps[1003] == 99, "PID 1003 should remain untouched")
    assert(activeTaps.count == 1, "Only 1 item should remain")
    print("  ✅ Passed testDictionaryCleanupSafety")
}

func testVolumeStoreLocking() {
    print("[TEST] testVolumeStoreLocking...")
    let store = VolumeStore()
    assert(store.getExplicit(1234) == nil, "Explicit volume should be nil before setting")
    store.set(1234, 0.75)
    assert(abs((store.getExplicit(1234) ?? 0) - 0.75) < 0.001, "Explicit volume should match 0.75")
    assert(abs(store.get(1234) - 0.75) < 0.001, "Volume should match 0.75")

    // Verify pre-mute volume tracking and ignore of 0.0
    assert(store.getPreMuteVolume(1234) == nil, "Pre-mute volume should be nil initially")
    store.setPreMuteVolume(1234, 0.8)
    store.setPreMuteVolume(1234, 0.0) // Muting should not overwrite pre-mute volume
    assert(abs((store.getPreMuteVolume(1234) ?? 0) - 0.8) < 0.001, "Pre-mute volume should remain 0.8")

    store.remove(1234)
    assert(store.getExplicit(1234) == nil, "Explicit volume should be nil after removal")
    assert(store.getPreMuteVolume(1234) == nil, "Pre-mute volume should be nil after removal")
    assert(abs(store.get(1234) - 1.0) < 0.001, "Default volume should be 1.0 after removal")
    print("  ✅ Passed testVolumeStoreLocking")
}

func testAudioActivityTrackerLocking() {
    print("[TEST] testAudioActivityTrackerLocking...")
    let tracker = AudioActivityTracker()
    assert(!tracker.isAudioActive(for: 5678), "Should not be active before recording")
    tracker.recordActivity(for: 5678)
    assert(tracker.isAudioActive(for: 5678), "Should be active after recording")
    tracker.remove(pid: 5678)
    assert(!tracker.isAudioActive(for: 5678), "Should not be active after removal")
    print("  ✅ Passed testAudioActivityTrackerLocking")
}

func testAudioActivityTrackerPrune() {
    print("[TEST] testAudioActivityTrackerPrune...")
    let tracker = AudioActivityTracker()
    tracker.recordActivity(for: 111)
    usleep(20_000)
    tracker.recordActivity(for: 222)
    tracker.prune(olderThan: 0.01)
    assert(!tracker.isAudioActive(for: 111, window: 1000), "Stale entry should be pruned")
    assert(tracker.isAudioActive(for: 222, window: 1000), "Fresh entry should survive pruning")
    print("  ✅ Passed testAudioActivityTrackerPrune")
}

func testVolumeStorePersistence() {
    print("[TEST] testVolumeStorePersistence...")
    let testSuite = "com.xuanmn.mysound.test.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: testSuite)!
    let store1 = VolumeStore(userDefaults: testDefaults)

    assert(store1.getPersistentVolume(for: "com.spotify.client") == nil, "Initial persistent volume should be nil")

    store1.setPersistentVolume(for: "com.spotify.client", volume: 0.65)
    assert(abs((store1.getPersistentVolume(for: "com.spotify.client") ?? 0) - 0.65) < 0.001, "Stored persistent volume should be 0.65")

    // Create a new store instance with same defaults to verify cross-instance persistence
    let store2 = VolumeStore(userDefaults: testDefaults)
    assert(abs((store2.getPersistentVolume(for: "com.spotify.client") ?? 0) - 0.65) < 0.001, "Separate store instance should read persisted 0.65")
    testDefaults.removePersistentDomain(forName: testSuite)
    print("  ✅ Passed testVolumeStorePersistence")
}

func testTapControl() {
    print("[TEST] testTapControl...")
    let control = TapControl(gain: 0.42)
    assert(abs(control.gain - 0.42) < 0.001, "Initial gain should match 0.42")
    control.gain = 0.85
    assert(abs(control.gain - 0.85) < 0.001, "Updated gain should match 0.85")

    assert(!control.isAudioActive(window: 1.0), "Should not be active before recording")
    control.recordActivity()
    assert(control.isAudioActive(window: 1.0), "Should be active immediately after recording")
    print("  ✅ Passed testTapControl")
}

func testAudioOutputDeviceIconsAndTransport() {
    print("[TEST] testAudioOutputDeviceIconsAndTransport...")
    assert(AudioDeviceTransportType.from(fourCC: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
    assert(AudioDeviceTransportType.from(fourCC: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
    assert(AudioDeviceTransportType.from(fourCC: kAudioDeviceTransportTypeUSB) == .usb)
    assert(AudioDeviceTransportType.from(fourCC: kAudioDeviceTransportTypeVirtual) == .virtual)
    assert(AudioDeviceTransportType.from(fourCC: 0) == .unknown)

    let airpods = AudioOutputDevice(id: 1, name: "User's AirPods Pro", uid: "bt-1", transportType: .bluetooth)
    assert(airpods.iconName == "airpodspro", "AirPods Pro should resolve to airpodspro icon")

    let airpodsMax = AudioOutputDevice(id: 2, name: "AirPod Max", uid: "bt-2", transportType: .bluetooth)
    assert(airpodsMax.iconName == "headphones", "AirPod Max should resolve to headphones icon")

    let macbookSpeakers = AudioOutputDevice(id: 3, name: "MacBook Pro Speakers", uid: "builtin-1", transportType: .builtIn)
    assert(macbookSpeakers.iconName == "laptopcomputer", "MacBook speakers should resolve to laptopcomputer icon")

    let macMiniSpeakers = AudioOutputDevice(id: 4, name: "Mac mini Speakers", uid: "builtin-2", transportType: .builtIn)
    assert(macMiniSpeakers.iconName == "desktopcomputer", "Mac mini speakers should resolve to desktopcomputer icon")
    print("  ✅ Passed testAudioOutputDeviceIconsAndTransport")
}

func testUpdateVersionComparison() {
    print("[TEST] testUpdateVersionComparison...")
    assert(UpdateManager.isVersionNewer(newVersion: "2.0.0", currentVersion: "1.8.0"), "2.0.0 > 1.8.0")
    assert(UpdateManager.isVersionNewer(newVersion: "v2.0.1", currentVersion: "2.0"), "v2.0.1 > 2.0")
    assert(!UpdateManager.isVersionNewer(newVersion: "2.0", currentVersion: "2.0.0"), "2.0 == 2.0.0")
    assert(!UpdateManager.isVersionNewer(newVersion: "1.8.0", currentVersion: "2.0.0"), "1.8.0 < 2.0.0")
    print("  ✅ Passed testUpdateVersionComparison")
}

@main
struct TestRunner {
    static func main() {
        testDictionaryCleanupSafety()
        testVolumeStoreLocking()
        testAudioActivityTrackerLocking()
        testAudioActivityTrackerPrune()
        testVolumeStorePersistence()
        testTapControl()
        testAudioOutputDeviceIconsAndTransport()
        testUpdateVersionComparison()
        print("\nAll unit tests passed successfully!")
    }
}

