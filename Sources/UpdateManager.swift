import Foundation
import SwiftUI
import AppKit

struct UpdateInfo: Codable {
    let version: String
    let downloadUrl: String
    let releaseNotes: String?
}

@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    @Published var isUpdateAvailable = false
    @Published var latestVersion: String?
    @Published var updateURL: URL?
    @Published var isChecking = false
    @Published var errorMessage: String?
    
    // Replace this with your actual version.json URL (e.g. GitHub raw content)
    private let versionURL = URL(string: "https://raw.githubusercontent.com/YOUR_USERNAME/MySound/main/version.json")!
    
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking else { return }
        
        isChecking = true
        errorMessage = nil
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: versionURL)
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw NSError(domain: "UpdateManager", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch version info"])
                }
                
                let updateInfo = try JSONDecoder().decode(UpdateInfo.self, from: data)
                
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                
                if self.isVersionNewer(newVersion: updateInfo.version, currentVersion: currentVersion) {
                    self.isUpdateAvailable = true
                    self.latestVersion = updateInfo.version
                    self.updateURL = URL(string: updateInfo.downloadUrl)
                    
                    if manual {
                        self.showUpdateAlert(version: updateInfo.version, url: updateInfo.downloadUrl)
                    }
                } else if manual {
                    self.showNoUpdateAlert()
                }
                
                self.isChecking = false
            } catch {
                print("Failed to check for updates: \(error)")
                self.isChecking = false
                if manual {
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert(error: error.localizedDescription)
                }
            }
        }
    }
    
    private func isVersionNewer(newVersion: String, currentVersion: String) -> Bool {
        return newVersion.compare(currentVersion, options: .numeric) == .orderedDescending
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
        alert.informativeText = "There was an error checking for updates: \(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
