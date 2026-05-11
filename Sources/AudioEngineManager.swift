import AVFoundation
import CoreAudio

class AudioEngineManager: ObservableObject {
    private let engine = AVAudioEngine()
    private var playerNodes: [pid_t: AVAudioPlayerNode] = [:]
    private var mixerNodes: [pid_t: AVAudioMixerNode] = [:]

    // Core Audio Tap is generally interleaved float32. Let's create a format that matches.
    private let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!

    // Heartbeat tracker to not spam console
    private var bufferCount: [pid_t: Int] = [:]

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

        bufferCount[pid, default: 0] += 1
        if bufferCount[pid]! % 100 == 0 {
            print("HEARTBEAT: Processing buffer #\(bufferCount[pid]!) for PID \(pid)")
        }

        let mBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard mBuffers.count > 0, let mData = mBuffers[0].mData else { return }

        // Convert AudioBufferList to AVAudioPCMBuffer
        // For interleaved stereo float32, mDataByteSize = frameCount * 2 channels * 4 bytes
        let frameCount = mBuffers[0].mDataByteSize / UInt32(MemoryLayout<Float>.size * Int(tapFormat.channelCount))
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Because we are using an interleaved format, we just copy the single interleaved buffer directly
        if let dest = pcmBuffer.audioBufferList.pointee.mBuffers.mData {
            memcpy(dest, mData, Int(mBuffers[0].mDataByteSize))
        }

        // Schedule the buffer for playback smoothly without interrupting
        player.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)

        if !player.isPlaying {
            player.play()
        }
    }

    func setVolume(for pid: pid_t, volume: Float) {
        print("SET VOLUME for PID \(pid) to \(volume)")
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

