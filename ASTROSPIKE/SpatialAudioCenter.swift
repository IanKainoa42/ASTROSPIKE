import AVFAudio

@MainActor
final class SpatialAudioCenter {
    static let shared = SpatialAudioCenter()

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0

    private init() {
        engine.attach(environment)
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.referenceDistance = 1
        player.renderingAlgorithm = .HRTF
        try? engine.start()
    }

    func play(frequency: Double, duration: Double, positionX: Float) {
        if !engine.isRunning { try? engine.start() }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let progress = Double(frame) / Double(frameCount)
            let envelope = Float(sin(.pi * progress)) * 0.22
            samples[frame] = sin(Float(frame) * Float(2 * Double.pi * frequency / sampleRate)) * envelope
        }
        player.stop()
        player.position = AVAudio3DPoint(x: positionX, y: 0, z: -1)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}
