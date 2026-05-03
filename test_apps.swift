import AppKit
let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
for app in apps {
    print("\(app.localizedName ?? "Unknown") - ID: \(app.bundleIdentifier ?? "nil") - Icon: \(app.icon != nil ? "Yes" : "No")")
}
