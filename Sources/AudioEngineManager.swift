import AVFoundation
import CoreAudio

class AudioEngineManager: ObservableObject {
    static let shared = AudioEngineManager()

    private let engine = AVAudioEngine()
    private var sourceNodes: [pid_t: AVAudioSourceNode] = [:]
    private var ringBuffers: [pid_t: RingBuffer] = [:]
    private var mixerNodes: [pid_t: AVAudioMixerNode] = [:]
    private let lock = NSLock()

    init() {
        // Optimize for minimum latency to eliminate echo
        let outputNode = engine.outputNode
        if let audioUnit = outputNode.audioUnit {
            var frames: UInt32 = 256 // Smallest stable buffer for macOS
            AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        }
    }

    func setupPlayer(for pid: pid_t) {
        lock.lock()
        if sourceNodes[pid] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = hardwareFormat.sampleRate

        let ringBuffer = RingBuffer(capacity: Int(sampleRate) * 2 / 10)

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

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        engine.connect(sourceNode, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)

        lock.lock()
        sourceNodes[pid] = sourceNode
        ringBuffers[pid] = ringBuffer
        mixerNodes[pid] = mixer
        lock.unlock()

        if !engine.isRunning {
            try? engine.start()
        }
    }

    func processBuffer(pid: pid_t, bufferList: UnsafePointer<AudioBufferList>) {
        lock.lock()
        let rb = ringBuffers[pid]
        lock.unlock()

        guard let ringBuffer = rb else {
            DispatchQueue.main.async { self.setupPlayer(for: pid) }
            return
        }

        let mBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))

        if mBuffers.count == 1 {
            let channelCount = mBuffers[0].mNumberChannels
            let frameCount = mBuffers[0].mDataByteSize / (4 * channelCount)
            if let src = mBuffers[0].mData {
                ringBuffer.writeInterleaved(src: src.assumingMemoryBound(to: Float.self), frames: Int(frameCount), channels: Int(channelCount))
            }
        } else {
            for i in 0..<min(mBuffers.count, 2) {
                let frameCount = mBuffers[i].mDataByteSize / 4
                if let src = mBuffers[i].mData {
                    ringBuffer.write(src: src.assumingMemoryBound(to: Float.self), frames: Int(frameCount), channel: i)
                }
            }
        }
    }

    func setVolume(for pid: pid_t, volume: Float) {
        lock.lock()
        let mixer = mixerNodes[pid]
        lock.unlock()
        mixer?.outputVolume = volume
    }
}

class RingBuffer {
    private var buffer: [UnsafeMutablePointer<Float>]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [
            UnsafeMutablePointer<Float>.allocate(capacity: capacity),
            UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        ]
        self.buffer[0].initialize(repeating: 0, count: capacity)
        self.buffer[1].initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer[0].deallocate()
        buffer[1].deallocate()
    }

    func write(src: UnsafePointer<Float>, frames: Int, channel: Int) {
        guard channel < 2 else { return }
        lock.lock()
        let w = writeIndex
        let c = capacity

        let firstPart = min(frames, c - w)
        memcpy(buffer[channel].advanced(by: w), src, firstPart * 4)
        if frames > firstPart {
            let secondPart = frames - firstPart
            memcpy(buffer[channel], src.advanced(by: firstPart), secondPart * 4)
        }

        if channel == 0 { writeIndex = (w + frames) % c }
        lock.unlock()
    }

    func writeInterleaved(src: UnsafePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        let w = writeIndex
        let c = capacity
        for f in 0..<frames {
            let idx = (w + f) % c
            for ch in 0..<min(channels, 2) {
                buffer[ch][idx] = src[f * channels + ch]
            }
        }
        writeIndex = (w + frames) % c
        lock.unlock()
    }

    func read(into dst: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard channel < 2 else { return }
        lock.lock()
        let r = readIndex
        let c = capacity

        let firstPart = min(frames, c - r)
        memcpy(dst, buffer[channel].advanced(by: r), firstPart * 4)
        if frames > firstPart {
            let secondPart = frames - firstPart
            memcpy(dst.advanced(by: firstPart), buffer[channel], secondPart * 4)
        }

        if channel == 0 { readIndex = (r + frames) % c }
        lock.unlock()
    }
}
