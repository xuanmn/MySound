@preconcurrency import ScreenCaptureKit
import Foundation
import AVFoundation

@MainActor
class AudioTapManager: NSObject, ObservableObject, SCStreamOutput {
    @Published var activeStreams: [pid_t: SCStream] = [:]
    
    // Callback for when we receive audio data
    var onAudioBuffer: ((pid_t, CMSampleBuffer) -> Void)?
    
    func createTap(for pid: pid_t) {
        if activeStreams[pid] != nil { return }
        
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let app = content.applications.first(where: { $0.processID == pid }) else {
                    print("ERROR: Could not find SCShareableContent application for PID \(pid)")
                    return
                }
                
                guard let display = content.displays.first else {
                    print("ERROR: No displays found in SCShareableContent. Check permissions.")
                    return
                }
                
                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
                
                try await stream.startCapture()
                
                DispatchQueue.main.async {
                    self.activeStreams[pid] = stream
                    print("SUCCESS: Started SCStream for PID \(pid)")
                }
            } catch {
                print("ERROR: Failed to start SCStream for PID \(pid): \(error)")
            }
        }
    }
    
    func removeTap(for pid: pid_t) {
        guard let stream = activeStreams[pid] else { return }
        stream.stopCapture()
        activeStreams.removeValue(forKey: pid)
        print("Stopped SCStream for PID \(pid)")
    }
    
    // SCStreamOutput delegate
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // Use Task to get back to MainActor to access activeStreams
        Task { @MainActor in
            // Find which PID this stream belongs to
            if let pid = activeStreams.first(where: { $0.value === stream })?.key {
                onAudioBuffer?(pid, sampleBuffer)
            }
        }
    }
}
