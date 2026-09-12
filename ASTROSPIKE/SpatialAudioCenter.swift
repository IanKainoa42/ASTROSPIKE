import AVFAudio

@MainActor
final class SpatialAudioCenter {
    static let shared = SpatialAudioCenter()

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0

    private init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        engine.attach(environment)
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.referenceDistance = 1
        player.renderingAlgorithm = .HRTF
        try? engine.start()
    }

    /// The format everything on this graph speaks. Handed out so recorded
    /// clips can be converted to it once, at load, instead of per playback.
    var mixFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            ?? engine.mainMixerNode.outputFormat(forBus: 0)
    }

    func ensureRunning() {
        if !engine.isRunning { try? engine.start() }
    }

    /// Another player node on the same environment, so a caller can hold its
    /// own voice rather than fighting for the shared one.
    func makeVoice(format: AVAudioFormat) -> AVAudioPlayerNode {
        let voice = AVAudioPlayerNode()
        engine.attach(voice)
        engine.connect(voice, to: environment, format: format)
        voice.renderingAlgorithm = .HRTF
        ensureRunning()
        return voice
    }

    /// A voice with a speed control ahead of the environment, so a held sound
    /// can climb while it plays. Varispeed moves rate and pitch together,
    /// which is what an engine spooling up actually does. The connection stays
    /// mono end to end because HRTF will not take anything else.
    func makePitchedVoice(format: AVAudioFormat) -> (AVAudioPlayerNode, AVAudioUnitVarispeed) {
        let voice = AVAudioPlayerNode()
        let speed = AVAudioUnitVarispeed()
        engine.attach(voice)
        engine.attach(speed)
        engine.connect(voice, to: speed, format: format)
        engine.connect(speed, to: environment, format: format)
        voice.renderingAlgorithm = .HRTF
        ensureRunning()
        return (voice, speed)
    }

    func play(frequency: Double, duration: Double, positionX: Float) {
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
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
