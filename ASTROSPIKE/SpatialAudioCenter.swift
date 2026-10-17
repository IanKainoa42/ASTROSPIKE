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
        #if os(iOS)
        // An interruption stops the engine and leaves it stopped. Start it
        // again when the interruption ends rather than on the next cue.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.ensureRunning()
            }
        }
        #endif
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.ensureRunning() }
        }
    }

    /// The format everything on this graph speaks. Handed out so recorded
    /// clips can be converted to it once, at load, instead of per playback.
    var mixFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            ?? engine.mainMixerNode.outputFormat(forBus: 0)
    }

    /// Whether a node on this graph may be told to play. `play()` on a node
    /// whose engine is stopped raises an Objective-C exception (a crash),
    /// and the engine is stopped for us by any audio interruption or
    /// configuration change -- a notification sound, a call, a route change.
    @discardableResult
    func ensureRunning() -> Bool {
        if !engine.isRunning { try? engine.start() }
        return engine.isRunning
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

    /// A voice with a speed control and a resonant low-pass ahead of the
    /// environment, so a held sound can be opened up while it plays. Mono end
    /// to end, like the pitched voice.
    func makeFilteredVoice(format: AVAudioFormat) -> (AVAudioPlayerNode, AVAudioUnitEQ) {
        let voice = AVAudioPlayerNode()
        let filter = AVAudioUnitEQ(numberOfBands: 1)
        let band = filter.bands[0]
        band.filterType = .resonantLowPass
        band.frequency = 320
        band.bandwidth = 0.47
        band.bypass = false
        engine.attach(voice)
        engine.attach(filter)
        engine.connect(voice, to: filter, format: format)
        engine.connect(filter, to: environment, format: format)
        voice.renderingAlgorithm = .HRTF
        ensureRunning()
        return (voice, filter)
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
