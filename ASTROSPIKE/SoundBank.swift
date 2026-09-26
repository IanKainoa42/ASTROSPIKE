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
        // Rendered from the FX Lab picks (thump, crack, thunk, thud, hum).
        case boltFire
        case boltHit
        case ballHit
        case wallHit
        case tractorHum

        /// The lab sounds ship as WAV: they are short, and the lead-in trim
        /// and sustain search are for recordings, not synthesis.
        var isRendered: Bool {
            switch self {
            case .boltFire, .boltHit, .ballHit, .wallHit, .tractorHum: true
            default: false
            }
        }

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
        let held: Set<Cue> = [.thrusterCyan, .thrusterOrange]
        for cue in Cue.allCases {
            guard let buffer = Self.load(cue, into: format, looping: held.contains(cue))
            else { continue }
            buffers[cue] = buffer
        }
        // Bolts, their hits and every contact now sound, so a busy rally
        // needs more voices than the old goal-and-offside set did.
        for _ in 0..<10 {
            voices.append(SpatialAudioCenter.shared.makeVoice(format: format))
        }
        for cue in [Cue.thrusterCyan, .thrusterOrange] {
            let (voice, speed) = SpatialAudioCenter.shared.makePitchedVoice(format: format)
            loops[cue] = voice
            loopSpeeds[cue] = speed
        }
        for team in [Team.cyan, .orange] {
            hums[team] = SpatialAudioCenter.shared.makeFilteredVoice(format: format)
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

    /// The tractor hum for one team, driven every frame like the thruster:
    /// it swells in over 0.12s while a beam is up and dies over 0.25s after,
    /// and opens up -- louder and brighter -- the harder the beam has the ball.
    func driveHum(_ team: Team, active: Bool, grip: Double, positionX: Float, dt: Double) {
        guard let (voice, filter) = hums[team] else { return }
        let step = Float(max(0, min(dt, 0.1)))
        var level = humLevels[team] ?? 0
        if active && enabled {
            level = min(1, level + step / 0.12)
        } else {
            level = max(0, level - step / 0.25)
        }
        humLevels[team] = level
        guard level > 0 else {
            if voice.isPlaying { voice.stop() }
            return
        }
        guard let buffer = buffers[.tractorHum] else { return }
        let g = Float(max(0, min(1, grip)))
        voice.position = AVAudio3DPoint(x: positionX, y: 0, z: -1)
        voice.volume = Self.humVolume * (0.55 + 0.45 * g) * level
        filter.bands[0].frequency = 320 + 1400 * g
        if !voice.isPlaying {
            SpatialAudioCenter.shared.ensureRunning()
            voice.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])
            voice.play()
        }
    }

    func stopEverything() {
        for voice in voices { voice.stop() }
        for voice in loops.values { voice.stop() }
        for (voice, _) in hums.values { voice.stop() }
        spools.removeAll()
        humLevels.removeAll()
    }

    private var hums: [Team: (AVAudioPlayerNode, AVAudioUnitEQ)] = [:]
    private var humLevels: [Team: Float] = [:]
    /// The file is the lab hum at 0.57 of full scale; the lab played it at
    /// 0.22 of its own level, so this is the gain that restores it.
    private static let humVolume: Float = 0.386

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
    /// How much of a held clip survives the trim, and how long the two ends
    /// take to hand over at the seam.
    ///
    /// Two seconds rather than one because the cycle is what gives a loop
    /// away, and at full throttle the varispeed runs at `loopBaseRate +
    /// loopRateClimb`, so a one-second window came back round every 0.89s --
    /// a 1.1 Hz pulse sitting right where hearing is most alert to rhythm.
    /// Two seconds halves that to 0.56 Hz, slow enough to read as texture.
    /// The cost is paid in flatness: the longer window has to take in more of
    /// the clip's own shape (0.32 to 0.58 on cyan), so each pass is less even.
    /// Fewer, less uniform cycles beat more, more uniform ones.
    private static let loopSeconds = 2.0
    private static let loopFadeSeconds = 0.03

    /// Decode a bundled clip, convert it to the engine's format, and drop the
    /// silence in front of it. Every one of these files starts with about four
    /// tenths of a second of nothing, and a sound effect that arrives four
    /// tenths of a second after the thing it describes reads as a bug.
    private static func load(
        _ cue: Cue,
        into format: AVAudioFormat,
        looping: Bool = false
    ) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: cue.isRendered ? "wav" : "mp3"),
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
        if cue.isRendered { return converted }
        let trimmed = trimmingLeadIn(converted)
        return looping ? sustainWindow(trimmed) : trimmed
    }

    /// Cut a held clip down to a single loopable second. These recordings have
    /// a shape of their own -- attack, body, then a long fade -- and looping
    /// the whole of one replays that arc on a fixed cycle, which is the part
    /// that still reads as a clip however the envelope is driven. A second of
    /// the steadiest stretch has no arc left to hear.
    ///
    /// The window is found rather than dialled in. The two thrusters settle at
    /// different times, and an offset measured off the files as they are today
    /// would be wrong the moment either one is re-recorded.
    private static func sustainWindow(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount == 1,
              let samples = buffer.floatChannelData?[0] else { return buffer }
        let rate = buffer.format.sampleRate
        let length = Int(buffer.frameLength)
        let bin = max(1, Int(rate * 0.05))
        let fade = max(1, Int(rate * loopFadeSeconds))
        guard length > Int(rate * loopSeconds) + fade + bin else { return buffer }

        var energy: [Float] = []
        energy.reserveCapacity(length / bin)
        for base in stride(from: 0, to: length - bin, by: bin) {
            var sum: Float = 0
            for i in base ..< base + bin { sum += samples[i] * samples[i] }
            energy.append((sum / Float(bin)).squareRoot())
        }
        guard let peak = energy.max(), peak > 0 else { return buffer }

        let span = Int(rate * loopSeconds) / bin
        // Reserve the crossfade's worth of bins past the window as well: the
        // seam reads samples from beyond the body, so a window allowed to end
        // on the last bin would read off the end of the buffer.
        let tail = (fade + bin - 1) / bin
        guard span > 0, energy.count > span + tail else { return buffer }

        // Only bins carrying real signal are eligible, which is what keeps the
        // search out of the silent lead-in and the fade -- both are flat, and
        // both would otherwise win outright.
        let floorLevel = peak * 0.35
        var bestStart = -1
        var bestFlatness = Float.greatestFiniteMagnitude
        for s in 0 ... (energy.count - span - tail) {
            let window = energy[s ..< s + span]
            guard let low = window.min(), low >= floorLevel, let high = window.max() else { continue }
            let mean = window.reduce(0, +) / Float(span)
            guard mean > 0 else { continue }
            let flatness = (high - low) / mean
            if flatness < bestFlatness {
                bestFlatness = flatness
                bestStart = s
            }
        }
        guard bestStart >= 0 else { return buffer }

        let start = bestStart * bin
        let body = span * bin
        guard let loop = AVAudioPCMBuffer(
                  pcmFormat: buffer.format,
                  frameCapacity: AVAudioFrameCount(body)
              ),
              let out = loop.floatChannelData?[0] else { return buffer }
        loop.frameLength = AVAudioFrameCount(body)
        out.update(from: samples + start, count: body)
        // The seam is already continuous -- the sample that opens the loop is
        // the one that followed its last -- so the fade is only there to stop
        // the waveform kinking. Equal power (a^2 + b^2 = 1) rather than a
        // straight blend, or the level dips through the middle of it.
        for i in 0 ..< fade {
            let t = Float(i) / Float(fade)
            out[i] = samples[start + body + i] * (1 - t).squareRoot()
                + samples[start + i] * t.squareRoot()
        }
        return loop
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
