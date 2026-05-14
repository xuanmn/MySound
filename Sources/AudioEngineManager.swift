import AVFoundation
import CoreAudio

class AudioEngineManager: ObservableObject {
    static let shared = AudioEngineManager()

    private var lastActivity: [pid_t: Date] = [:]
    private let lock = NSLock()

    init() {}

    func updateActivity(for pid: pid_t) {
        lock.lock()
        lastActivity[pid] = Date()
        lock.unlock()
    }

    func isPIDActive(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastActivity[pid] else { return false }
        return Date().timeIntervalSince(last) < 2.5 // Active if heard in last 2.5 seconds
    }

    func setMasterVolume(_ volume: Float) {
        // Master volume is handled by system volume in AudioTapManager
    }
}
