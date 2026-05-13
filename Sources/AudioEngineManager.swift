import AVFoundation
import CoreAudio

class AudioEngineManager: ObservableObject {
    static let shared = AudioEngineManager()
    
    private let engine = AVAudioEngine()
    // Cache for SourceNodes and their associated RingBuffers
    private var sourceNodes: [pid_t: AVAudioSourceNode] = [:]
    private var ringBuffers: [pid_t: RingBuffer] = [:]
    private var mixerNodes: [pid_t: AVAudioMixerNode] = [:]
    private let lock = NSLock()

    init() {}

    func setupPlayer(for pid: pid_t) {
        lock.lock()
        if sourceNodes[pid] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        // Create a ring buffer for this PID (approx 100ms of audio at 48k)
        let ringBuffer = RingBuffer(capacity: 48000 * 2 / 10) 
        
        let sourceNode = AVAudioSourceNode { [weak ringBuffer] (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            guard let rb = ringBuffer else { return noErr }
            
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            for i in 0..<outputs.count {
                if let dst = outputs[i].mData {
                    rb.read(into: dst.assumingMemoryBound(to: Float.self), frames: Int(frameCount), channel: i)
                }
            }
            return noErr
        }

        let mixer = AVAudioMixerNode()

        engine.attach(sourceNode)
        engine.attach(mixer)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        engine.connect(sourceNode, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)

        lock.lock()
        sourceNodes[pid] = sourceNode
        ringBuffers[pid] = ringBuffer
        mixerNodes[pid] = mixer
        lock.unlock()

        // Start the engine ONLY after we have connected nodes to the output
        ensureEngineIsRunning()
    }

    func processBuffer(pid: pid_t, bufferList: UnsafePointer<AudioBufferList>) {
        lock.lock()
        let ringBuffer = ringBuffers[pid]
        lock.unlock()

        guard let rb = ringBuffer else {
            DispatchQueue.main.async {
                self.setupPlayer(for: pid)
            }
            return
        }

        let mBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard mBuffers.count > 0 else { return }

        // Simply write to the ring buffer. This is real-time safe.
        let isInterleaved = mBuffers.count == 1
        if isInterleaved {
            // Handle interleaved by splitting or just copying if mono
            let channelCount = mBuffers[0].mNumberChannels
            let frameCount = mBuffers[0].mDataByteSize / (4 * channelCount)
            if let src = mBuffers[0].mData {
                rb.writeInterleaved(src: src.assumingMemoryBound(to: Float.self), frames: Int(frameCount), channels: Int(channelCount))
            }
        } else {
            for i in 0..<mBuffers.count {
                let frameCount = mBuffers[i].mDataByteSize / 4
                if let src = mBuffers[i].mData {
                    rb.write(src: src.assumingMemoryBound(to: Float.self), frames: Int(frameCount), channel: i)
                }
            }
        }
    }

    func setVolume(for pid: pid_t, volume: Float) {
        print("SET VOLUME for PID \(pid) to \(volume)")
        lock.lock()
        let mixer = mixerNodes[pid]
        lock.unlock()
        mixer?.outputVolume = volume
    }

    func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    private func ensureEngineIsRunning() {
        if !engine.isRunning {
            startEngine()
        }
    }

    private func startEngine() {
        do {
            try engine.start()
        } catch {
            print("ERROR: Could not start audio engine: \(error)")
        }
    }

}

// Simple thread-safe Ring Buffer for audio data
class RingBuffer {
    private var buffer: [[Float]]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Array(repeating: 0, count: capacity), Array(repeating: 0, count: capacity)]
    }

    func write(src: UnsafePointer<Float>, frames: Int, channel: Int) {
        guard channel < 2 else { return }
        lock.lock()
        for i in 0..<frames {
            buffer[channel][(writeIndex + i) % capacity] = src[i]
        }
        if channel == 0 { writeIndex = (writeIndex + frames) % capacity }
        lock.unlock()
    }

    func writeInterleaved(src: UnsafePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        for i in 0..<frames {
            for c in 0..<min(channels, 2) {
                buffer[c][(writeIndex + i) % capacity] = src[i * channels + c]
            }
        }
        writeIndex = (writeIndex + frames) % capacity
        lock.unlock()
    }

    func read(into dst: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard channel < 2 else { return }
        lock.lock()
        for i in 0..<frames {
            dst[i] = buffer[channel][(readIndex + i) % capacity]
        }
        if channel == 0 { readIndex = (readIndex + frames) % capacity }
        lock.unlock()
    }
}
