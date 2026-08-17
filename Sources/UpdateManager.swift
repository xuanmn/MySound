import Foundation
import Combine
import AppKit

// MARK: - Data Models

/// `UpdateInfo` represents the lightweight JSON schema hosted at `version.json` on the main branch.
/// Used for quick and direct version discovery without hitting GitHub REST API rate limits.
struct UpdateInfo: Codable {
    /// The latest release version tag string (e.g. "1.3.0" or "v1.3.0").
    let version: String
    /// Direct HTTPS URL to download the new `.zip` archive.
    let downloadUrl: String
    /// Optional markdown release notes describing what changed.
    let releaseNotes: String?
}

/// `GitHubAsset` models an individual release artifact attached to a GitHub Release.
struct GitHubAsset: Codable {
    /// File name of the asset (e.g. "MySound.zip").
    let name: String
    /// Direct public download link for the asset.
    let browserDownloadUrl: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

/// `GitHubRelease` represents the JSON response returned by the GitHub Releases API:
/// `GET https://api.github.com/repos/xuanmn/MySound/releases/latest`
struct GitHubRelease: Codable {
    /// Git tag name of the latest release (e.g. "v1.3.0").
    let tagName: String
    /// Web page URL for the release on GitHub.
    let htmlUrl: String
    /// Body description or changelog text.
    let body: String?
    /// List of binary assets attached to this release.
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
        case assets
    }
}

// MARK: - Update Manager

/// `UpdateManager` manages automated update checking, downloading, extracting,
/// and seamless in-place application relaunching for MySound.
@MainActor
class UpdateManager: ObservableObject {
    /// Shared singleton instance accessible throughout the app.
    static let shared = UpdateManager()
    
    // Published UI state variables bound to SwiftUI views
    @Published var isUpdateAvailable = false
    @Published var latestVersion: String?
    @Published var updateURL: URL?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var updateStatus: String?
    @Published var errorMessage: String?
    
    /// Primary endpoint: raw static version file in GitHub repository.
    private let versionURL = URL(string: "https://raw.githubusercontent.com/xuanmn/MySound/main/version.json")!
    
    /// Secondary fallback endpoint: official GitHub REST API for latest release.
    private let githubApiURL = URL(string: "https://api.github.com/repos/xuanmn/MySound/releases/latest")!
    
    /// Single shared ephemeral URLSession.
    ///
    /// Why ephemeral?
    /// - Prevents local and remote HTTP caching so update checks always see the freshest metadata.
    /// - Reuses underlying TCP/TLS connection pool across checks instead of spinning up new sessions.
    private nonisolated static let ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()
    
    // MARK: - Update Checking
    
    /// Checks for newer releases asynchronously.
    /// - Parameter manual: If `true`, pops up user-facing alerts (used when triggered via Settings menu).
    ///                     If `false`, operates silently in the background (used on startup).
    func checkForUpdates(manual: Bool = false) {
        // Prevent concurrent checks or checking while already downloading
        guard !isChecking && !isDownloading else { return }
        
        isChecking = true
        errorMessage = nil
        
        Task {
            // Strategy 1: Attempt to fetch raw version.json (fastest, unmetered)
            if let updateInfo = await fetchVersionJson() {
                self.processUpdate(version: updateInfo.version, downloadUrl: updateInfo.downloadUrl, manual: manual)
                self.isChecking = false
                return
            }
            
            // Strategy 2: Fallback to GitHub Releases API if version.json is unavailable
            if let release = await fetchGitHubRelease() {
                let cleanVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                // Locate the .zip asset in the release, or fallback to the GitHub HTML URL
                let zipAssetUrl = release.assets?.first(where: { $0.name.lowercased().hasSuffix(".zip") })?.browserDownloadUrl ?? release.htmlUrl
                self.processUpdate(version: cleanVersion, downloadUrl: zipAssetUrl, manual: manual)
                self.isChecking = false
                return
            }
            
            // Neither endpoint succeeded
            self.isChecking = false
            if manual {
                self.showErrorAlert(error: "Could not fetch update info. Push version.json to your main branch or create a Release on GitHub.")
            } else {
                print("Update check: Remote version file not found on GitHub yet.")
            }
        }
    }
    
    /// Fetches and decodes the static `version.json` file from GitHub raw storage.
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
    
    /// Fetches and decodes the latest release object from GitHub's REST API.
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
    
    /// Compares the remote version with the local running app version and updates published properties.
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
    
    /// Compares two semver strings (e.g. "1.3.1" > "1.3.0" -> true).
    /// Handles differing segment lengths (e.g. "1.3" vs "1.3.0").
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
    
    // MARK: - In-App Update Pipeline
    
    /// Performs an in-place automatic update:
    /// 1. Downloads the update ZIP file with real-time progress reporting.
    /// 2. Extracts the ZIP using macOS `/usr/bin/ditto` (preserving code signatures and symlinks).
    /// 3. Locates the `.app` bundle within the extracted archive.
    /// 4. Executes a non-blocking bash script that waits for current process termination,
    ///    replaces the existing `.app` on disk, launches the new version, and exits.
    func performInAppUpdate() {
        guard let downloadURL = updateURL, !isDownloading else { return }
        
        // Resolve direct ZIP download link if updateURL is a release page link
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
                // Step 1: Stream download using URLSessionDownloadDelegate to track progress smoothly
                let delegate = DownloadProgressDelegate { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = progress
                        self?.updateStatus = "Downloading update (\(Int(progress * 100))%)..."
                    }
                }
                let downloadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                
                var (tempFileURL, response) = try await downloadSession.download(from: zipURL)
                
                // If GitHub release zip URL returns 404, fallback to repository raw build zip
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 404 {
                    if let rawFallbackURL = URL(string: "https://raw.githubusercontent.com/xuanmn/MySound/main/build/MySound.zip") {
                        (tempFileURL, response) = try await downloadSession.download(from: rawFallbackURL)
                    }
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw NSError(domain: "UpdateError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download update package (HTTP status \((response as? HTTPURLResponse)?.statusCode ?? 0)). Please ensure a release asset is published on GitHub."])
                }
                
                // Move downloaded temp file to a known temporary location
                let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent("MySound_Update.zip")
                if FileManager.default.fileExists(atPath: tempZipURL.path) {
                    try? FileManager.default.removeItem(at: tempZipURL)
                }
                try FileManager.default.moveItem(at: tempFileURL, to: tempZipURL)
                
                await MainActor.run {
                    self.downloadProgress = 1.0
                    self.updateStatus = "Extracting update..."
                }
                
                // Step 2: Create a unique staging directory for extraction
                let tempExtractDir = FileManager.default.temporaryDirectory.appendingPathComponent("MySound_Update_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
                
                // Extract using macOS `ditto -x -k`.
                // `ditto` is preferred over `unzip` because it properly handles macOS metadata,
                // extended attributes, and bundle symlinks required by signed .app bundles.
                let dittoProcess = Process()
                dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                dittoProcess.arguments = ["-x", "-k", tempZipURL.path, tempExtractDir.path]
                
                // Use CheckedContinuation for non-blocking async Process execution
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
                
                // Step 3: Find the .app bundle inside the extracted contents
                let fileManager = FileManager.default
                let contents = try fileManager.contentsOfDirectory(atPath: tempExtractDir.path)
                guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                    throw NSError(domain: "UpdateError", code: 3, userInfo: [NSLocalizedDescriptionKey: "No .app bundle found inside update package."])
                }
                
                let newAppPath = tempExtractDir.appendingPathComponent(appName).path
                var currentAppPath = Bundle.main.bundlePath
                // Guard against running from a mounted DMG volume
                if currentAppPath.hasPrefix("/Volumes/") {
                    currentAppPath = "/Applications/MySound.app"
                }
                
                let pid = ProcessInfo.processInfo.processIdentifier
                
                await MainActor.run {
                    self.updateStatus = "Installing & Relaunching..."
                }
                
                // Step 4: Self-replacement bash script.
                // - Loops with `kill -0 <pid>` until current MySound process completely terminates.
                // - Deletes existing bundle and moves new bundle into place.
                // - Launches updated app using `open`.
                // - Cleans up temporary extraction files.
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
                
                // Terminate current app to allow the relaunch script to finish replacement
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
                
            } catch {
                // If automatic update fails, alert user and offer browser download fallback
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
    
    // MARK: - User Dialogs
    
    /// Displays a standard macOS alert notifying that an update is ready to install.
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
    
    /// Displays an alert when the app is already on the newest version.
    private func showNoUpdateAlert() {
        let alert = NSAlert()
        alert.messageText = "Up to Date"
        alert.informativeText = "You are running the latest version of MySound."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    /// Displays an error alert with descriptive message.
    private func showErrorAlert(error: String) {
        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = error
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Download Progress Tracking

/// `DownloadProgressDelegate` tracks download bytes and converts them to a 0.0...1.0 fraction.
/// Used by `performInAppUpdate()` for efficient streaming without accumulating bytes in RAM.
class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    /// Invoked periodically as data packets arrive from the network.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(progress)
        }
    }

    /// Required by `URLSessionDownloadDelegate`.
    /// The async `URLSession.download(from:)` method handles file moving directly.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled directly by async download(from:) API
    }
}

