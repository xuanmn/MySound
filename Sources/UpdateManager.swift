import Foundation
import Combine
import AppKit

struct UpdateInfo: Codable {
    let version: String
    let downloadUrl: String
    let releaseNotes: String?
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let body: String?
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
        case assets
    }
}

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var isUpdateAvailable = false
    @Published var latestVersion: String?
    @Published var updateURL: URL?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var updateStatus: String?
    @Published var errorMessage: String?
    
    private let versionURL = URL(string: "https://raw.githubusercontent.com/xuanmn/MySound/main/version.json")!
    private let githubApiURL = URL(string: "https://api.github.com/repos/xuanmn/MySound/releases/latest")!
    
    // Single shared ephemeral session — avoids creating new TLS connections per check
    private nonisolated static let ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()
    
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking && !isDownloading else { return }
        
        isChecking = true
        errorMessage = nil
        
        Task {
            // First attempt: version.json
            if let updateInfo = await fetchVersionJson() {
                self.processUpdate(version: updateInfo.version, downloadUrl: updateInfo.downloadUrl, manual: manual)
                self.isChecking = false
                return
            }
            
            // Second attempt: GitHub Releases API fallback
            if let release = await fetchGitHubRelease() {
                let cleanVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let zipAssetUrl = release.assets?.first(where: { $0.name.lowercased().hasSuffix(".zip") })?.browserDownloadUrl ?? release.htmlUrl
                self.processUpdate(version: cleanVersion, downloadUrl: zipAssetUrl, manual: manual)
                self.isChecking = false
                return
            }
            
            self.isChecking = false
            if manual {
                self.showErrorAlert(error: "Could not fetch update info. Push version.json to your main branch or create a Release on GitHub.")
            } else {
                print("Update check: Remote version file not found on GitHub yet.")
            }
        }
    }
    
    private func fetchVersionJson() async -> UpdateInfo? {
        do {
            var request = URLRequest(url: versionURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await Self.ephemeralSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(UpdateInfo.self, from: data)
        } catch {
            return nil
        }
    }
    
    private func fetchGitHubRelease() async -> GitHubRelease? {
        do {
            var request = URLRequest(url: githubApiURL)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await Self.ephemeralSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            return nil
        }
    }
    
    private func processUpdate(version: String, downloadUrl: String, manual: Bool) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        
        if isVersionNewer(newVersion: version, currentVersion: currentVersion) {
            self.isUpdateAvailable = true
            self.latestVersion = version
            self.updateURL = URL(string: downloadUrl)
            
            if manual {
                self.showUpdateAlert(version: version)
            }
        } else if manual {
            self.showNoUpdateAlert()
        }
    }
    
    private func isVersionNewer(newVersion: String, currentVersion: String) -> Bool {
        let newComponents = newVersion.split(separator: ".").compactMap { Int($0) }
        let currentComponents = currentVersion.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(newComponents.count, currentComponents.count)
        for i in 0..<maxCount {
            let newComponent = i < newComponents.count ? newComponents[i] : 0
            let currentComponent = i < currentComponents.count ? currentComponents[i] : 0
            
            if newComponent > currentComponent { return true }
            if newComponent < currentComponent { return false }
        }
        return false
    }
    
    func performInAppUpdate() {
        guard let downloadURL = updateURL, !isDownloading else { return }
        
        let zipURL: URL
        if downloadURL.pathExtension.lowercased() == "zip" || downloadURL.absoluteString.contains("/releases/download/") {
            zipURL = downloadURL
        } else if downloadURL.absoluteString.contains("github.com/xuanmn/MySound/releases") {
            if let ver = latestVersion {
                zipURL = URL(string: "https://github.com/xuanmn/MySound/releases/download/v\(ver)/MySound.zip") ?? downloadURL
            } else {
                zipURL = URL(string: "https://github.com/xuanmn/MySound/releases/latest/download/MySound.zip") ?? downloadURL
            }
        } else {
            zipURL = downloadURL
        }

        isDownloading = true
        downloadProgress = 0.0
        updateStatus = "Downloading update..."

        Task {
            do {
                // Use URLSession.download for efficient streaming instead of
                // byte-by-byte append which caused ~5M Data.append() calls.
                let delegate = DownloadProgressDelegate { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                        self?.updateStatus = "Downloading update (\(Int(progress * 100))%)..."
                    }
                }
                let downloadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                
                var (tempFileURL, response) = try await downloadSession.download(from: zipURL)
                
                // If GitHub release zip URL returns 404, fallback to raw GitHub
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 404 {
                    if let rawFallbackURL = URL(string: "https://raw.githubusercontent.com/xuanmn/MySound/main/build/MySound.zip") {
                        (tempFileURL, response) = try await downloadSession.download(from: rawFallbackURL)
                    }
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw NSError(domain: "UpdateError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download update package (HTTP status \((response as? HTTPURLResponse)?.statusCode ?? 0)). Please ensure a release asset is published on GitHub."])
                }
                
                let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent("MySound_Update.zip")
                if FileManager.default.fileExists(atPath: tempZipURL.path) {
                    try? FileManager.default.removeItem(at: tempZipURL)
                }
                try FileManager.default.moveItem(at: tempFileURL, to: tempZipURL)
                
                await MainActor.run {
                    self.downloadProgress = 1.0
                    self.updateStatus = "Extracting update..."
                }
                
                let tempExtractDir = FileManager.default.temporaryDirectory.appendingPathComponent("MySound_Update_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
                
                // Use async-safe process execution instead of blocking waitUntilExit()
                let dittoProcess = Process()
                dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                dittoProcess.arguments = ["-x", "-k", tempZipURL.path, tempExtractDir.path]
                
                let dittoStatus = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    dittoProcess.terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        try dittoProcess.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                
                guard dittoStatus == 0 else {
                    throw NSError(domain: "UpdateError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to extract update package."])
                }
                
                let fileManager = FileManager.default
                let contents = try fileManager.contentsOfDirectory(atPath: tempExtractDir.path)
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw NSError(domain: "UpdateError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No .app bundle found inside update package."])
                }
                
                let newAppPath = tempExtractDir.appendingPathComponent(appName).path
                var currentAppPath = Bundle.main.bundlePath
                if currentAppPath.hasPrefix("/Volumes/") {
                    currentAppPath = "/Applications/MySound.app"
                }
                
                let pid = ProcessInfo.processInfo.processIdentifier
                
                await MainActor.run {
                    self.updateStatus = "Installing & Relaunching..."
                }
                
                let relaunchScript = """
                while kill -0 \(pid) 2>/dev/null; do
                    sleep 0.2
                done
                rm -rf "\(currentAppPath)"
                mv "\(newAppPath)" "\(currentAppPath)"
                open "\(currentAppPath)"
                rm -rf "\(tempExtractDir.path)"
                rm -f "\(tempZipURL.path)"
                """
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", relaunchScript]
                try process.run()
                
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.updateStatus = nil
                    self.showErrorAlert(error: "Automatic update failed: \(error.localizedDescription)\n\nOpening download link in browser instead.")
                    if let url = self.updateURL {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
    
    private func showUpdateAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "A new version (\(version)) of MySound is available. Would you like to update and restart now?"
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performInAppUpdate()
        }
    }
    
    private func showNoUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "Up to Date"
        alert.informativeText = "You are running the latest version of MySound."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func showErrorAlert(error: String) {
        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = error
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// URLSession delegate for download progress tracking.
// Used by performInAppUpdate() to report progress without byte-by-byte streaming.
class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The download(from:) async API handles the completion;
        // this delegate method is required by the protocol but unused.
    }
}
