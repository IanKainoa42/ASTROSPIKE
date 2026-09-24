import ASTROSPIKECore
import AVFAudio

/// The music under a match. Two recorded beds: one for ordinary play and one
/// for when it matters. The epic track takes over the moment either side
/// reaches match point, or from the first serve of a deciding set, and holds
/// until that set is decided so a deuce cannot flick the music back and forth.
///
/// Stereo and straight to the mixer, not through the HRTF environment the
/// effects use: a bed has no position in the arena. `AVAudioPlayer` does its
/// own fades, so nothing here runs per frame beyond a comparison.
@MainActor
final class Soundscape {
    static let shared = Soundscape()
    static let enabledKey = "music"

    enum Track: String, CaseIterable {
        case suspense = "volleySuspense"
        case epic = "volleyEpic"
    }

    var enabled: Bool {
        didSet { if !enabled { silence(over: 0.4) } }
    }

    private var players: [Track: AVAudioPlayer] = [:]
    private var playing: Track?
    private var ducked = false
    /// The sets tally when the epic bed took over. While the tally still
    /// matches, the bed stays epic whatever the score does.
    private var epicLatch: Score?
    /// True when the pilot had their own audio running as the match began;
    /// their playlist wins and the effects mix in over it.
    private var yielding = false

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Called as a match (or a Play Again) starts. Loads on first use.
    func begin() {
        epicLatch = nil
        ducked = false
        guard enabled else { return }
        #if os(iOS)
        yielding = AVAudioSession.sharedInstance().isOtherAudioPlaying
        #endif
        guard !yielding else { return }
        if players.isEmpty { load() }
    }

    /// Drive once per frame. Cheap: only a change of bed or of pause state
    /// touches a player.
    func update(match: MatchRuleState, paused: Bool) {
        guard enabled, !yielding, !players.isEmpty else { return }
        if match.phase == .finished {
            silence(over: Self.fadeOutSeconds)
            return
        }
        let wanted = track(for: match)
        if wanted != playing { crossfade(to: wanted) }
        if paused != ducked {
            ducked = paused
            players[wanted]?.setVolume(level, fadeDuration: 0.3)
        }
    }

    /// Leaving the arena. Hard stop: the menu has no bed.
    func end() {
        for player in players.values { player.stop() }
        playing = nil
        epicLatch = nil
    }

    private func track(for match: MatchRuleState) -> Track {
        if let epicLatch, epicLatch == match.sets { return .epic }
        let deciding = match.setsToWin > 1
            && match.sets[.cyan] == match.setsToWin - 1
            && match.sets[.orange] == match.setsToWin - 1
        let matchPoint = match.stake(for: .cyan) == .matchPoint
            || match.stake(for: .orange) == .matchPoint
        guard deciding || matchPoint else { return .suspense }
        epicLatch = match.sets
        return .epic
    }

    private var level: Float { ducked ? Self.duckedLevel : Self.bedLevel }

    private func crossfade(to track: Track) {
        let incoming = playing == nil ? Self.fadeInSeconds : Self.crossfadeSeconds
        if let playing, let outgoing = players[playing] {
            outgoing.setVolume(0, fadeDuration: Self.crossfadeSeconds)
        }
        guard let player = players[track] else { return }
        // From the top, every time. The epic bed opening on its first bar is
        // the moment that tells a pilot the stakes just changed.
        player.stop()
        player.currentTime = 0
        player.volume = 0
        player.play()
        player.setVolume(level, fadeDuration: incoming)
        playing = track
    }

    /// Fade to nothing and forget which bed was up, so the next `update`
    /// starts one fresh. The players keep running at zero rather than being
    /// stopped on a timer; `end()` stops them for real.
    private func silence(over seconds: TimeInterval) {
        guard playing != nil else { return }
        for player in players.values { player.setVolume(0, fadeDuration: seconds) }
        playing = nil
    }

    private func load() {
        for track in Track.allCases {
            guard let url = Bundle.main.url(forResource: track.rawValue, withExtension: "m4a"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            players[track] = player
        }
    }

    /// Under the effects: a goal or a thruster burn has to sit on top of it.
    private static let bedLevel: Float = 0.32
    private static let duckedLevel: Float = 0.14
    private static let fadeInSeconds: TimeInterval = 1.2
    private static let crossfadeSeconds: TimeInterval = 2.0
    private static let fadeOutSeconds: TimeInterval = 1.5
}
