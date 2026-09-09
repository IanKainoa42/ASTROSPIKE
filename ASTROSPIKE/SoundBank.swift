import ASTROSPIKECore
import AVFAudio

/// The recorded sounds, as opposed to the synthesised beeps in
/// `SpatialAudioCenter`. They go through the same environment node, so a hit on
/// the left of the arena still arrives on the left, and they are decoded once
/// at launch rather than on the frame that needs them.
@MainActor
final class SoundBank {
    static let shared = SoundBank()

    enum Cue: String, CaseIterable {
        case goal
        case offsideCyan
        case offsideOrange
        case thrusterCyan
        case thrusterOrange

        static func offside(_ team: Team) -> Cue { team == .cyan ? .offsideCyan : .offsideOrange }
        static func thruster(_ team: Team) -> Cue { team == .cyan ? .thrusterCyan : .thrusterOrange }
    }

    var enabled = true

    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    /// A small ring of voices, so a second cue does not cut the first off.
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    /// Held sounds get a node of their own -- they have to be stoppable.
    private var loops: [Cue: AVAudioPlayerNode] = [:]
    private var loaded = false

    private init() {}

    /// Decode every clip up front. Cheap enough to do on the first frame of a
    /// match and much better than discovering the decode cost mid-rally.
    func warm() {
        guard !loaded else { return }
        loaded = true
        let format = SpatialAudioCenter.shared.mixFormat
        for cue in Cue.allCases {
            guard let buffer = Self.load(cue.rawValue, into: format) else { continue }
            buffers[cue] = buffer
        }
        for _ in 0..<6 {
            voices.append(SpatialAudioCenter.shared.makeVoice(format: format))
        }
        for cue in [Cue.thrusterCyan, .thrusterOrange] {
            loops[cue] = SpatialAudioCenter.shared.makeVoice(format: format)
        }
    }

    /// Fire and forget. `positionX` is the arena x, -1 to 1.
    func play(_ cue: Cue, positionX: Float = 0, volume: Float = 1) {
        guard enabled, let buffer = buffers[cue], !voices.isEmpty else { return }
        SpatialAudioCenter.shared.ensureRunning()
        let voice = voices[nextVoice % voices.count]
        nextVoice += 1
        voice.stop()
        voice.volume = volume
        voice.position = AVAudio3DPoint(x: positionX, y: 0, z: -1)
        voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
        voice.play()
    }

    /// Starts the cue looping if it is not already running. Calling it again
    /// while it plays does nothing, which is what a held button wants.
    func startLoop(_ cue: Cue, positionX: Float, volume: Float = 0.6) {
        guard enabled, let buffer = buffers[cue], let voice = loops[cue] else { return }
        voice.position = AVAudio3DPoint(x: positionX, y: 0, z: -1)
        guard !voice.isPlaying else { return }
        SpatialAudioCenter.shared.ensureRunning()
        voice.volume = volume
        voice.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])
        voice.play()
    }

    func stopLoop(_ cue: Cue) {
        loops[cue]?.stop()
    }

    func stopEverything() {
        for voice in voices { voice.stop() }
        for voice in loops.values { voice.stop() }
    }

    /// Decode a bundled clip, convert it to the engine's format, and drop the
    /// silence in front of it. Every one of these files starts with about four
    /// tenths of a second of nothing, and a sound effect that arrives four
    /// tenths of a second after the thing it describes reads as a bug.
    private static func load(_ name: String, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: source)) != nil else { return nil }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, converted.frameLength > 0 else { return nil }
        return trimmingLeadIn(converted)
    }

    private static func trimmingLeadIn(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let samples = buffer.floatChannelData?[0] else { return buffer }
        let length = Int(buffer.frameLength)
        var start = 0
        while start < length, abs(samples[start]) < 0.004 { start += 1 }
        // Back off a couple of milliseconds so the attack is not clipped.
        start = max(0, start - Int(buffer.format.sampleRate * 0.002))
        guard start > 0, start < length,
              let trimmed = AVAudioPCMBuffer(
                  pcmFormat: buffer.format,
                  frameCapacity: AVAudioFrameCount(length - start)
              ),
              let destination = trimmed.floatChannelData?[0] else { return buffer }
        trimmed.frameLength = AVAudioFrameCount(length - start)
        destination.update(from: samples + start, count: length - start)
        return trimmed
    }
}
