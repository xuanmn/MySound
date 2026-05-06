import AVFoundation
import ScreenCaptureKit

class AudioEngineManager: ObservableObject {
    private let engine = AVAudioEngine()
    private var playerNodes: [pid_t: AVAudioPlayerNode] = [:]
    private var mixerNodes: [pid_t: AVAudioMixerNode] = [:]
    
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
        engine.connect(player, to: mixer, format: nil)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        
        playerNodes[pid] = player
        mixerNodes[pid] = mixer
        
        player.play()
    }
    
    func processBuffer(pid: pid_t, sampleBuffer: CMSampleBuffer) {
        guard let player = playerNodes[pid] else {
            setupPlayer(for: pid)
            return
        }
        
        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = pcmBufferFrom(sampleBuffer: sampleBuffer) else { return }
        
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
    
    private func pcmBufferFrom(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(count)) else {
            return nil
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(count)
        
        guard let destination = pcmBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        
        let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: CMBlockBufferGetDataLength(blockBuffer), destination: destination)
        
        return status == noErr ? pcmBuffer : nil
    }
}
