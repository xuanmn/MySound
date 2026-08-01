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
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)
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
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)
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
                let (asyncBytes, response) = try await URLSession.shared.bytes(from: zipURL)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw NSError(domain: "UpdateError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download update package (HTTP status \((response as? HTTPURLResponse)?.statusCode ?? 0))."])
                }
                
                let expectedLength = response.expectedContentLength
                let tempZipURL = FileManager.default.temporaryDirectory.appendingPathComponent("MySound_Update.zip")
                
                if FileManager.default.fileExists(atPath: tempZipURL.path) {
                    try? FileManager.default.removeItem(at: tempZipURL)
                }
                
                var data = Data()
                if expectedLength > 0 {
                    data.reserveCapacity(Int(expectedLength))
                }
                
                for try await byte in asyncBytes {
                    data.append(byte)
                    if expectedLength > 0 {
                        let progress = Double(data.count) / Double(expectedLength)
                        await MainActor.run {
                            self.downloadProgress = progress
                            self.updateStatus = "Downloading update (\(Int(progress * 100))%)..."
                        }
                    }
                }
                
                try data.write(to: tempZipURL)
                
                await MainActor.run {
                    self.updateStatus = "Extracting update..."
                }
                
                let tempExtractDir = FileManager.default.temporaryDirectory.appendingPathComponent("MySound_Update_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
                
                let dittoProcess = Process()
                dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                dittoProcess.arguments = ["-x", "-k", tempZipURL.path, tempExtractDir.path]
                try dittoProcess.run()
                dittoProcess.waitUntilExit()
                
                guard dittoProcess.terminationStatus == 0 else {
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

