import AVFoundation
import CoreAudio

class AudioEngineManager: ObservableObject {
    private let engine = AVAudioEngine()
    private var playerNodes: [pid_t: AVAudioPlayerNode] = [:]
    private var mixerNodes: [pid_t: AVAudioMixerNode] = [:]
    private let lock = NSLock()

    // Core Audio Tap is generally non-interleaved float32. Let's create a format that matches.
    private let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!

    // Heartbeat tracker to not spam console
    private var bufferCount: [pid_t: Int] = [:]

    init() {
        startEngine()
    }

    func setupPlayer(for pid: pid_t) {
        lock.lock()
        let exists = playerNodes[pid] != nil
        lock.unlock()
        if exists { return }

        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        engine.attach(player)
        engine.attach(mixer)

        // Connect: Player -> Mixer -> MainMixer
        engine.connect(player, to: mixer, format: tapFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: tapFormat)

        lock.lock()
        playerNodes[pid] = player
        mixerNodes[pid] = mixer
        lock.unlock()

        player.play()
    }

    func processBuffer(pid: pid_t, bufferList: UnsafePointer<AudioBufferList>) {
        lock.lock()
        let player = playerNodes[pid]
        lock.unlock()

        guard let player = player else {
            DispatchQueue.main.async {
                self.setupPlayer(for: pid)
            }
            return
        }

        lock.lock()
        bufferCount[pid, default: 0] += 1
        let count = bufferCount[pid]!
        lock.unlock()

        if count % 100 == 0 {
            print("HEARTBEAT: Processing buffer #\(count) for PID \(pid)")
        }

        let mBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard mBuffers.count > 0 else { return }

        let isInterleaved = mBuffers.count == 1
        let channelCount = UInt32(mBuffers.count)
        
        let frameCount: UInt32
        if isInterleaved {
            frameCount = mBuffers[0].mDataByteSize / UInt32(MemoryLayout<Float>.size * Int(tapFormat.channelCount))
        } else {
            frameCount = mBuffers[0].mDataByteSize / UInt32(MemoryLayout<Float>.size)
        }
        
        guard frameCount > 0 else { return }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.sampleRate, channels: tapFormat.channelCount, interleaved: isInterleaved)!
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let destBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for i in 0..<Int(channelCount) {
            if i < destBuffers.count && i < mBuffers.count {
                if let dest = destBuffers[i].mData, let src = mBuffers[i].mData {
                    memcpy(dest, src, Int(mBuffers[i].mDataByteSize))
                }
            }
        }

        // Schedule the buffer for playback smoothly without interrupting
        player.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)

        if !player.isPlaying {
            player.play()
        }
    }

    func setVolume(for pid: pid_t, volume: Float) {
        print("SET VOLUME for PID \(pid) to \(volume)")
        lock.lock()
        let mixer = mixerNodes[pid]
        lock.unlock()
        mixer?.outputVolume = volume
    }

    private func startEngine() {
        do {
            try engine.start()
        } catch {
            print("ERROR: Could not start audio engine: \(error)")
        }
    }
}
