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
    /// Held sounds get a node of their own -- they have to be stoppable -- and
    /// a speed control, so the note can climb while the pad stays down.
    private var loops: [Cue: AVAudioPlayerNode] = [:]
    private var loopSpeeds: [Cue: AVAudioUnitVarispeed] = [:]
    /// How far each held cue has spooled up, 0 to 1. This is the whole reason
    /// the thruster stops sounding like a clip: the physics thrust is a step
    /// (`FlightTuning` runs initial == maximum with no ramp), so the sense of
    /// an engine winding up has to be kept here, in wall-clock time.
    private var spools: [Cue: Float] = [:]
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
            let (voice, speed) = SpatialAudioCenter.shared.makePitchedVoice(format: format)
            loops[cue] = voice
            loopSpeeds[cue] = speed
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

    /// Drive a held cue for one frame. Safe -- expected, in fact -- to call
    /// every frame whether or not the pad is down: the cue swells while it is
    /// held, coasts down when it is let go, and only stops once it has
    /// actually reached silence. A stab and a long burn are different sounds
    /// because a stab never gets far up the swell.
    func driveLoop(_ cue: Cue, pressed: Bool, positionX: Float, dt: Double) {
        guard let voice = loops[cue] else { return }
        let step = Float(max(0, min(dt, 0.1)))
        var level = spools[cue] ?? 0
        if pressed && enabled {
            level = min(1, level + step / Self.spoolUp)
        } else {
            level = max(0, level - step / Self.spoolDown)
        }
        spools[cue] = level

        guard level > 0 else {
            if voice.isPlaying { voice.stop() }
            return
        }
        guard let buffer = buffers[cue] else { return }
        voice.position = AVAudio3DPoint(x: positionX, y: 0, z: -1)
        // The curve is deliberately steep at the bottom: a tap has to make a
        // noise on the frame it happens, or the pad reads as dead. The last
        // two thirds of the swell are the part you only hear on a long burn.
        // Set ahead of `play()`, never after: a fresh node sits at full volume
        // and the render thread can pull a quantum before the assignment
        // lands, which is a bang on the very first press.
        voice.volume = Self.loopPeakVolume * pow(level, 0.45)
        loopSpeeds[cue]?.rate = Self.loopBaseRate + Self.loopRateClimb * level
        if !voice.isPlaying {
            SpatialAudioCenter.shared.ensureRunning()
            voice.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])
            voice.play()
        }
    }

    func stopEverything() {
        for voice in voices { voice.stop() }
        for voice in loops.values { voice.stop() }
        spools.removeAll()
    }

    /// Seconds from the pad going down to the engine sitting at full song.
    private static let spoolUp: Float = 0.85
    /// Seconds from full song to silence once it is released. Short enough to
    /// feel like a cut-off, long enough not to click.
    private static let spoolDown: Float = 0.3
    private static let loopPeakVolume: Float = 0.72
    /// The clip plays flat and slightly slow at ignition and passes its
    /// recorded pitch near the top, so the burn climbs through the note.
    private static let loopBaseRate: Float = 0.82
    private static let loopRateClimb: Float = 0.3

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
