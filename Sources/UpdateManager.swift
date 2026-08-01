import Foundation
import Combine
import AppKit

struct UpdateInfo: Codable {
    let version: String
    let downloadUrl: String
    let releaseNotes: String?
}

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }
}

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var isUpdateAvailable = false
    @Published var latestVersion: String?
    @Published var updateURL: URL?
    @Published var isChecking = false
    @Published var errorMessage: String?
    
    private let versionURL = URL(string: "https://raw.githubusercontent.com/xuanmn/MySound/main/version.json")!
    private let githubApiURL = URL(string: "https://api.github.com/repos/xuanmn/MySound/releases/latest")!
    
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking else { return }
        
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
                self.processUpdate(version: cleanVersion, downloadUrl: release.htmlUrl, manual: manual)
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
                self.showUpdateAlert(version: version, url: downloadUrl)
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
    
    private func showUpdateAlert(version: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "A new version (\(version)) of MySound is available. Would you like to download it?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
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
        alert.messageText = "Update Check Failed"
        alert.informativeText = error
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
