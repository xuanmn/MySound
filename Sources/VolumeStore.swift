import Foundation

// =============================================================================
// MARK: - Thread-Safe Volume Store
// =============================================================================

/// `VolumeStore` provides a thread-safe, lock-protected dictionary mapping process IDs (PIDs) to volume scalars (0.0...1.0).
///
/// Real-Time Audio Safety:
/// - The CoreAudio IO callback runs on a high-priority real-time audio thread.
/// - It must never perform Swift actor calls, dispatch queue syncs, or allocate memory.
/// - `os_unfair_lock` provides low-overhead, spin-free locking safe for quick scalar lookups in the audio thread.
final class VolumeStore: @unchecked Sendable {
    private var _lock = os_unfair_lock_s()
    private var volumes: [pid_t: Float] = [:]

    private static let userDefaultsKey = "MySound_SavedAppVolumes"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Retrieves the volume for a given PID. Defaults to 1.0 (100%) if not explicitly set.
    func get(_ pid: pid_t) -> Float {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return volumes[pid] ?? 1.0
    }

    /// Updates the volume scalar for a given PID.
    func set(_ pid: pid_t, _ volume: Float) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        volumes[pid] = volume
    }

    /// Cleans up stored volume entry when an application terminates.
    func remove(_ pid: pid_t) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        volumes.removeValue(forKey: pid)
    }

    // MARK: - Persistent App Volume Storage

    /// Retrieves the saved persistent volume scalar (0.0...1.0) for a given bundle identifier.
    /// Defaults to nil if no preference was previously saved.
    func getPersistentVolume(for bundleID: String) -> Double? {
        guard let dict = userDefaults.dictionary(forKey: Self.userDefaultsKey) else { return nil }
        if let val = dict[bundleID] as? Double {
            return val
        } else if let num = dict[bundleID] as? NSNumber {
            return num.doubleValue
        }
        return nil
    }

    /// Saves the persistent volume scalar (0.0...1.0) for a given bundle identifier in UserDefaults.
    func setPersistentVolume(for bundleID: String, volume: Double) {
        var dict = userDefaults.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        dict[bundleID] = volume
        userDefaults.set(dict, forKey: Self.userDefaultsKey)
    }
}

// =============================================================================
// MARK: - Audio Activity Tracker
// =============================================================================

/// `AudioActivityTracker` tracks the most recent timestamp at which a process produced audible sound.
/// Used to display live "waveform" badges in the UI and clean up taps for idle/terminated applications.
final class AudioActivityTracker: @unchecked Sendable {
    private var _lock = os_unfair_lock_s()
    private var lastActivity: [pid_t: CFAbsoluteTime] = [:]

    /// Records that the specified process produced non-silent audio right now.
    func recordActivity(for pid: pid_t) {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&_lock)
        lastActivity[pid] = now
        os_unfair_lock_unlock(&_lock)
    }

    /// Checks if a process produced audio within the specified time window (default 1.0s).
    func isAudioActive(for pid: pid_t, window: TimeInterval = 1.0) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard let last = lastActivity[pid] else { return false }
        return (now - last) <= window
    }

    /// Removes tracking for a terminated process.
    func remove(pid: pid_t) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        lastActivity.removeValue(forKey: pid)
    }
}
