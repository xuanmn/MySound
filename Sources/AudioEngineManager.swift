import AVFoundation
import CoreAudio

class AudioEngineManager: ObservableObject {
    private let engine = AVAudioEngine()
    private var playerNodes: [pid_t: AVAudioPlayerNode] = [:]
    private var mixerNodes: [pid_t: AVAudioMixerNode] = [:]
    
    // Default format for taps (stereo, 48kHz, float32)
    // In a production app, you might want to query the tap's actual format
    private let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    
    init() {
        startEngine()
    }
    
    func setupPlayer(for pid: pid_t) {
        if playerNodes[pid] != nil { return }
        
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        
        engine.attach(player)
        engine.attach(mixer)
        
        // Connect: Player -> Mixer -> MainMixer
        engine.connect(player, to: mixer, format: tapFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: tapFormat)
        
        playerNodes[pid] = player
        mixerNodes[pid] = mixer
        
        player.play()
    }
    
    func processBuffer(pid: pid_t, bufferList: UnsafePointer<AudioBufferList>) {
        guard let player = playerNodes[pid] else {
            DispatchQueue.main.async {
                self.setupPlayer(for: pid)
            }
            return
        }
        
        // Convert AudioBufferList to AVAudioPCMBuffer
        // The tap usually provides 512 or 1024 frames
        let frameCount = bufferList.pointee.mBuffers.mDataByteSize / UInt32(MemoryLayout<Float>.size * 2)
        guard frameCount > 0 else { return }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount
        
        // Copy data from bufferList to pcmBuffer
        let abl = bufferList.pointee
        if let dest = pcmBuffer.floatChannelData {
            let mBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            for i in 0..<Int(tapFormat.channelCount) {
                if i < mBuffers.count {
                    let src = mBuffers[i].mData
                    let size = Int(mBuffers[i].mDataByteSize)
                    if let src = src {
                        dest[i].assign(from: src.assumingMemoryBound(to: Float.self), count: size / MemoryLayout<Float>.size)
                    }
                }
            }
        }
        
        // Schedule the buffer for playback
        player.scheduleBuffer(pcmBuffer, at: nil, options: .interrupts, completionHandler: nil)
        
        if !player.isPlaying {
            player.play()
        }
    }
    
    func setVolume(for pid: pid_t, volume: Float) {
        mixerNodes[pid]?.outputVolume = volume
    }
    
    private func startEngine() {
        do {
            try engine.start()
        } catch {
            print("ERROR: Could not start audio engine: \(error)")
        }
    }
}

