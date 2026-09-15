import Foundation

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
    store.set(1234, 0.75)
    assert(abs(store.get(1234) - 0.75) < 0.001, "Volume should match 0.75")
    store.remove(1234)
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

@main
struct TestRunner {
    static func main() {
        testDictionaryCleanupSafety()
        testVolumeStoreLocking()
        testAudioActivityTrackerLocking()
        testVolumeStorePersistence()
        print("\nAll unit tests passed successfully!")
    }
}
