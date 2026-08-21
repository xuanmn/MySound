import Foundation

// =============================================================================
// MARK: - File Logger
// =============================================================================

/// `AppLogger` provides lightweight diagnostic logging to `~/Library/Logs/MySound.log`.
/// Useful for debugging CoreAudio OSStatus errors in production and development.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private let logFileURL: URL?

    init() {
        let fileManager = FileManager.default
        if let libraryLogs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Logs") {
            try? fileManager.createDirectory(at: libraryLogs, withIntermediateDirectories: true)
            logFileURL = libraryLogs.appendingPathComponent("MySound.log")
        } else {
            logFileURL = nil
        }
    }

    /// Writes a timestamped log message to NSLog and the log file.
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)\n"
        NSLog("MySound: %@", message)
        guard let url = logFileURL else { return }
        // Rotate log file if it exceeds 5MB — preserve one backup instead of deleting
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 5_000_000 {
            let backupURL = url.deletingPathExtension().appendingPathExtension("log.1")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: url, to: backupURL)
        }
        if let data = logLine.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
