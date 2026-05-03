import SwiftUI

struct AppVolume: Identifiable {
    let id = UUID()
    let name: String
    let iconName: String
    var volume: Double
}

struct VolumeControlView: View {
    @State private var masterVolume: Double = 0.75

    @State private var apps: [AppVolume] = [
        AppVolume(name: "Spotify", iconName: "music.note", volume: 0.8),
        AppVolume(name: "Google Chrome", iconName: "safari", volume: 0.4),
        AppVolume(name: "Discord", iconName: "bubble.left.and.bubble.right.fill", volume: 0.6),
        AppVolume(name: "System Sounds", iconName: "bell.fill", volume: 0.5)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header / Master Volume
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Output Device")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "headphones")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: masterVolume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Slider(value: $masterVolume, in: 0...1)
                        .tint(.blue)

                    Text("\(Int(masterVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // App Volumes
            ScrollView {
                VStack(spacing: 20) {
                    ForEach($apps) { $app in
                        AppVolumeRow(app: $app)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer
            HStack {
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Text("Quit MySound")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Spacer()

                Button(action: {
                    // Settings action
                }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
    }
}

struct AppVolumeRow: View {
    @Binding var app: AppVolume

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: app.iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(.primary)

                Text(app.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(Int(app.volume * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                Slider(value: $app.volume, in: 0...1)
                    .tint(.gray)
            }
        }
    }
}

// Helper to use NSVisualEffectView in SwiftUI for glassmorphism
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
