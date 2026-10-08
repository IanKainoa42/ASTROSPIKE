import ASTROSPIKECore
import GameKit
import Observation
import QuartzCore
import SwiftUI

enum GameMode: Hashable {
    case solo(AIDifficulty)
    /// Two a side on the same court: you and an AI wingman against two bots.
    case doubles(AIDifficulty)
    case online
    /// The warm-up bay: a lone pilot, the same court, hoops to pop and a
    /// keep-up streak, while a Game Center invite is out.
    case warmup
    /// The same bay with no invite behind it, for as long as the pilot likes.
    case practice
    /// The net comes off the roof and stands up out of the floor, covering
    /// the bottom half of the arena. Play it over the top; the floor is live.
    case volleyball(AIDifficulty)
    /// One rim at centre court that both halves shoot at. First ball through
    /// it takes the match, for whoever touched it last.
    case basketball(AIDifficulty)
    /// Three or four pilots round one ring, a goal each, five lives,
    /// last one flying wins. Bots fill every seat but yours.
    case freeForAll(pilots: Int, AIDifficulty)

    /// Everything but a Game Center match: nothing on the wire, the pilot's
    /// own tuning applies.
    var isOffline: Bool {
        switch self {
        case .solo, .doubles, .volleyball, .basketball, .practice, .freeForAll: true
        case .online, .warmup: false
        }
    }

    var isFreeForAll: Bool {
        if case .freeForAll = self { true } else { false }
    }

    /// The bay: one pilot, no rival, hoops and a keep-up streak. Warm-up
    /// waits on an invite; practice waits on nothing.
    var isBay: Bool { self == .warmup || self == .practice }

    /// The court this mode is played on. The arena carries the whole of what
    /// makes a mode different -- the hump, the net, the hoop -- so the engine
    /// and the renderer only have to agree on this one value.
    ///
    /// It is cut for the ball that will be played on it: the goal mouth has
    /// to be taller than the ball is wide, and the ball is a slider now.
    func court(ballRadius: Double, ring: RingTuning = RingTuning()) -> ArenaGeometry {
        switch self {
        case .volleyball: .volleyball
        case .basketball: .basketball(ballRadius: ballRadius)
        case let .freeForAll(pilots, _): .freeForAll(pilots: pilots, ballRadius: ballRadius, tuning: ring)
        case .solo, .doubles, .online, .warmup, .practice: .standard(ballRadius: ballRadius)
        }
    }

    /// What the board should call it.
    var title: String {
        switch self {
        case .solo: "SOLO FLIGHT"
        case .doubles: "DOUBLES"
        case .online: "ONLINE DUEL"
        case .warmup: "WARM-UP BAY"
        case .practice: "PRACTICE"
        case .volleyball: "VOLLEYBALL"
        case .basketball: "BASKETBALL"
        case .freeForAll: "FREE-FOR-ALL"
        }
    }

    /// The bot ladder this mode is on, if any. Online and the bay have none.
    var rivalDifficulty: AIDifficulty? {
        switch self {
        case let .solo(difficulty), let .doubles(difficulty),
             let .volleyball(difficulty), let .basketball(difficulty),
             let .freeForAll(_, difficulty):
            difficulty
        case .online, .warmup, .practice:
            nil
        }
    }

    func withRival(_ difficulty: AIDifficulty) -> GameMode {
        switch self {
        case .solo: .solo(difficulty)
        case .doubles: .doubles(difficulty)
        case .volleyball: .volleyball(difficulty)
        case .basketball: .basketball(difficulty)
        case let .freeForAll(pilots, _): .freeForAll(pilots: pilots, difficulty)
        case .online, .warmup, .practice: self
        }
    }
}

@MainActor
@Observable
final class GameSession {
    private(set) var state: WorldState {
        didSet { reportStatsIfFinished(previous: oldValue.match.phase) }
    }
    /// The boards the local pilot set a personal best on in the match just
    /// finished. Empty until it finishes.
    private(set) var newBests: Set<StatBoard> = []
    /// `--results-win` / `--results-lose`: a staged finish whose sample book
    /// must not be recorded as the pilot's bests or sent to Game Center.
    private var isResultsPreview = false
    private(set) var events: [SimulationEvent] = []
    private(set) var countdown = 3
    private(set) var lastPointText: String?
    /// Plays called by name while the rally runs -- zaps, slams, saves --
    /// newest last, each for a couple of seconds.
    private(set) var callouts: [PlayCallout] = []
    private var calloutSerial = 0
    static let calloutLife: CFTimeInterval = 2.4
    /// What the last cue said, so the sound fires on the way up and not on
    /// every frame the score sits there.
    private var announcedStakes: (cyan: Stake, orange: Stake) = (.none, .none)
    private(set) var isPaused = false
    private(set) var ringsPopped = 0
    private(set) var bestKeepUp = 0
    private var rings = WarmupRings()

    var torque = 0.0
    var thrust = false
    /// A tap shorter than one simulation tick would otherwise be lost, so a
    /// press latches until the next tick consumes it.
    var fire = false { didSet { if fire { fireLatched = true } } }
    private var fireLatched = false
    var tractor = false

    let mode: GameMode
    let scene = ArenaScene()

    private var engine: SimulationEngine
    /// One bot per seat the local pilot is not flying. Online, only the host
    /// runs bots, and only for a seat nobody took.
    private var pilots: [Seat: AIController] = [:]
    /// The free-for-all field's bots, one per seat but yours. They fly a
    /// ring with a goal each, which the duel bot alone cannot read.
    private var fieldPilots: [Seat: FreeForAllPilot] = [:]
    /// Free-for-all pilots in the order they were knocked out, first out
    /// first. The results card ranks the field from it.
    private(set) var knockedOut: [Seat] = []
    private var demoAI: AIController?
    /// Which ships were past their MAX CROSS line last frame, so the call
    /// fires once on the way over instead of every frame they spend there.
    private var offsideLastFrame: Set<Seat> = []
    /// Which teams have an engine lit, and where the burn is coming from.
    /// The simulation writes these; the display frame reads them and feeds
    /// the thruster bed in wall-clock time, so the swell keeps its shape even
    /// when a frame carries several simulation ticks.
    private var thrustingTeams: Set<Team> = []
    private var thrustCenter: [Team: Double] = [:]
    let localSeat: Seat
    /// Watching from an open table's bench: every ship on the court is
    /// someone else's, and `localSeat` is only a placeholder.
    let isSpectator: Bool
    /// The seat this board's thumb flies, or nil on the bench.
    private var flownSeat: Seat? { isSpectator ? nil : localSeat }
    private weak var online: OnlineMatchCoordinator?
    /// Settings: hide the emotes other pilots play.
    static let muteEmotesKey = "muteOtherPilotsEmotes"
    private var emoteCooldown = EmoteCooldown()
    /// Each peer's own clock, a touch shorter than theirs so a pair sent on
    /// cooldown that arrive bunched by the network both still play.
    private var heardEmotes: [Seat: EmoteCooldown] = [:]
    /// When the local pilot may emote again, for the button's cooldown ring.
    private(set) var emoteReadyAt: Date = .distantPast
    /// Whether this board flies a ship it could emote with.
    var canEmote: Bool { flownSeat != nil }
    /// The host mirrors the score to the lobby; guests leave it alone.
    private weak var lobby: LobbyService?
    private var frameDriver: FrameDriver?
    private var accumulator = 0.0
    private var previousTimestamp: CFTimeInterval?
    private var countdownAccumulator = 0.0
    /// The guest's own recent inputs by tick, so a snapshot that lands behind
    /// the local clock can be rolled forward through what the thumb did since.
    private var localInputHistory: [UInt64: PlayerInput] = [:]
    private static let holdBeamPreview = ProcessInfo.processInfo.arguments.contains("--hold-beam")
    private var holdBeamStaged = false
    private var smoothing = GuestSmoothing()
    /// How many ticks of the guest's own inputs are kept for replaying a
    /// snapshot. Past the longest roll-forward, with room to spare.
    private static let inputHistoryDepth: UInt64 = GuestRollForward.maximumTicks + 40
    /// The input sent on the last even tick, flown again on the odd one.
    private var heldOnlineInput: PlayerInput?
    /// The thumb as of the last simulated tick, so a roll past the guest's
    /// own clock flies what the pilot is doing rather than nothing.
    private var latestLocalInput: PlayerInput?
    /// Two a side. The doubles court is bigger and plays two small balls,
    /// whoever fills the chairs -- bots, friends, or a mix.
    let isDoubles: Bool
    /// The ring: three or four pilots, a net and five lives each, no teams.
    /// Offline it is its own mode; online it is the host's call, carried in
    /// the seating plan, so a `.online` session can be a ring too.
    let isFreeForAll: Bool
    /// How many nets the ring has, or nil off it.
    private let ringPilots: Int?

    init(
        mode: GameMode,
        online: OnlineMatchCoordinator? = nil,
        lobby: LobbyService? = nil,
        configuration: SimulationConfiguration = .init(),
        setsToWin: Int = 1,
        localHull: Hull = .lancet,
        rivalHull: Hull = .anvil,
        finishedAs: Team? = nil
    ) {
        self.mode = mode
        self.online = online
        self.lobby = lobby
        let localSeat = mode == .online ? (online?.localSeat ?? .cyan) : .cyan
        self.localSeat = localSeat
        let isSpectator = mode == .online && online?.isSpectating == true
        self.isSpectator = isSpectator
        let onlineFormat = online?.format ?? .duel
        let isFreeForAll = mode.isFreeForAll || (mode == .online && onlineFormat.isFreeForAll)
        self.isFreeForAll = isFreeForAll
        var initialEngine = SimulationEngine.testing()
        let roster: Set<Seat>
        var botSeats: [Seat: AIDifficulty] = [:]
        var fieldBotSeats: [Seat: AIDifficulty] = [:]
        switch mode {
        case let .solo(difficulty):
            roster = Seat.singles
            botSeats[.orange] = difficulty
        case let .doubles(difficulty):
            roster = Seat.doubles
            for seat in Seat.doubles where seat != localSeat { botSeats[seat] = difficulty }
        case let .volleyball(difficulty), let .basketball(difficulty):
            roster = Seat.singles
            botSeats[.orange] = difficulty
        case let .freeForAll(pilots, difficulty):
            roster = FreeForAllState.seats(pilots: pilots)
            for seat in roster where seat != localSeat { fieldBotSeats[seat] = difficulty }
        case .warmup, .practice:
            // Nobody to defend against, and no ceremony before the first serve.
            roster = [.cyan]
            countdown = 1
        case .online:
            let filled = online?.filledSeats ?? Seat.singles
            // Three pilots, or a team-up of two, play doubles with the host
            // flying the empty chairs; a free-for-all is a ring of three or
            // four with the host's ring bots in the chairs nobody took.
            roster = OnlineSeating.roster(filled: filled, format: onlineFormat)
            if online?.isAuthoritative == true {
                for seat in roster.subtracting(filled) {
                    if isFreeForAll { fieldBotSeats[seat] = .pilot } else { botSeats[seat] = .pilot }
                }
            }
        }
        // Four free-for-all pilots fill the same seats as doubles, but it is
        // not doubles: one ball, one ring, no teams.
        let isDoubles = !isFreeForAll && roster == Seat.doubles
        self.isDoubles = isDoubles
        let ringPilots = isFreeForAll ? roster.count : nil
        self.ringPilots = ringPilots
        let configuration = Self.resolved(configuration, mode: mode, isDoubles: isDoubles, isFreeForAll: isFreeForAll)
        let court = Self.court(for: configuration, mode: mode, isDoubles: isDoubles, ringPilots: ringPilots)
        initialEngine.updateConfiguration(configuration)
        // The court goes on before the roster: the opening ball is staged as
        // part of seating, and it is staged into this arena.
        initialEngine.updateArena(court)
        if isFreeForAll {
            initialEngine.configureFreeForAll(roster)
        } else {
            initialEngine.configureRoster(roster)
        }
        // A guest flies the physics between snapshots and never keeps the
        // book: points, serves and phases all come from the host.
        initialEngine.followsHost = mode == .online && online?.isAuthoritative != true
        // Whoever runs the rules picks the length. A guest's board plays to
        // the host's format, which arrived with the seating plan, never to
        // its own slider.
        if mode.isOffline || online?.isAuthoritative == true {
            initialEngine.setMatchFormat(setsToWin: setsToWin)
        } else if let online {
            initialEngine.setMatchFormat(setsToWin: online.hostSetsToWin)
        }
        // `--set-break-preview`: cyan one step from taking the first set of a
        // best of three, so the simulator shows the set-break board without
        // anyone having to fly the set.
        if mode.isOffline, ProcessInfo.processInfo.arguments.contains("--set-break-preview") {
            var staged = initialEngine.state
            staged.match = MatchRuleState(
                score: Score(cyan: MatchRules.setTarget - 1, orange: 2), phase: .playing, setsToWin: 2
            )
            staged.stats = MatchStats(
                pilots: [
                    .cyan: PilotStats(goals: 3, boltGoals: 2, slamDunks: 1, zaps: 2, saves: 3, closeSaves: 1, beamSaves: 1),
                    .orange: PilotStats(goals: 2, boltGoals: 1, zaps: 5),
                ],
                longestRally: 7
            )
            let arena = initialEngine.arena
            staged.ball = BallState(
                position: SIMD2(arena.netHalfWidth + BallState.nominalRadius + 0.004, (arena.netBottomY + arena.portalMouthTopY) / 2),
                velocity: SIMD2(-2, 0),
                radius: BallState.nominalRadius,
                lastPlay: BallPlay(seat: .cyan, kind: .slamDunk)
            )
            initialEngine = SimulationEngine(state: staged, configuration: initialEngine.configuration, arena: arena)
        }
        engine = initialEngine
        state = initialEngine.state
        for (seat, difficulty) in botSeats {
            pilots[seat] = AIController(difficulty: difficulty, configuration: configuration, arena: court)
        }
        for (seat, difficulty) in fieldBotSeats {
            fieldPilots[seat] = FreeForAllPilot(difficulty: difficulty, configuration: configuration)
        }
        if mode != .online, ProcessInfo.processInfo.arguments.contains("--demo") {
            demoAI = AIController(difficulty: .pilot, configuration: configuration, arena: court)
        }
        scene.scaleMode = .resizeFill
        scene.seatColors = isFreeForAll ? .freeForAll : .teams
        scene.arena = court
        scene.tractorRange = engine.configuration.tractorRange
        scene.boltPunch = engine.configuration.boltPunch
        scene.snapshot = state
        // After the snapshot: the goal calls are drawn for the ends in it.
        // The bay keeps the court calls: SCORE and DEFEND read the same as in
        // the match it is warming up for.
        scene.localTeam = isSpectator ? nil : localSeat.team
        scene.localSeat = mode.isBay || isSpectator ? nil : localSeat
        if mode.isBay { scene.rings = rings.rings }
        if let winner = finishedAs {
            isResultsPreview = true
            engine.finishByForfeit(winner: winner)
            // A sample book, so the preview shows the stat line filled in.
            engine.state.stats = MatchStats(
                pilots: [localSeat: PilotStats(goals: 6, boltGoals: 3, slamDunks: 1, zaps: 4, saves: 2, closeSaves: 1, boltSaves: 1)],
                longestRally: 9
            )
            state = engine.state
            newBests = [.goals, .slamDunks]
            scene.snapshot = state
        }
        for seat in Seat.allCases {
            let hull: Hull = if seat == localSeat, !isSpectator {
                localHull
            } else if let remote = online?.remoteHulls[seat], mode == .online {
                remote
            } else if seat == Seat.lead(localSeat.team.opponent) {
                rivalHull
            } else {
                Hull.defaultHull(forSeat: seat)
            }
            scene.setHull(hull, for: seat)
            // Developer toggle: each hull meets the ball with its own shape.
            // Offline only -- both ends of an online match have to agree.
            if mode != .online, UserDefaults.standard.bool(forKey: ShipHitbox.perHullKey) {
                engine.shipHitboxes[seat] = ShipHitbox(hull.spec.outline)
            }
        }
    }

    func start() {
        guard frameDriver == nil else { return }
        // Hooked here, not in init. SwiftUI builds a throwaway GameSession
        // every time the arena's parent re-renders (each status change does
        // it), and a throwaway that hooks the coordinator leaves every
        // callback pointing at an object that is already gone: the guest
        // then never sees a snapshot and plays its own single game.
        if mode == .online { installOnlineCallbacks() }
        SoundBank.shared.warm()
        Soundscape.shared.begin()
        let driver = FrameDriver { [weak self] timestamp in
            self?.frame(timestamp: timestamp)
        }
        frameDriver = driver
        driver.start()
    }

    func stop() {
        frameDriver?.stop()
        frameDriver = nil
        previousTimestamp = nil
        // The thruster bed loops. Leaving the arena with the throttle down
        // must not leave it droning under the menu.
        SoundBank.shared.stopEverything()
        Soundscape.shared.end()
        if mode.isBay { StatsReporter.reportPractice(keepUp: bestKeepUp, hoops: ringsPopped) }
        thrustingTeams = []
        thrustCenter = [:]
        offsideLastFrame = []
    }

    /// Plays `emote` on the local ship and sends it to the court. Refused
    /// (false) while the cooldown runs or with no ship to play it on.
    @discardableResult
    func playEmote(_ emote: Emote) -> Bool {
        guard let seat = flownSeat, emoteCooldown.attempt(at: CACurrentMediaTime()) else { return false }
        emoteReadyAt = Date().addingTimeInterval(emoteCooldown.interval)
        scene.playEmote(emote, for: seat)
        if mode == .online { online?.sendEmote(emote) }
        return true
    }

    func togglePause() {
        guard state.match.phase != .finished else { return }
        isPaused.toggle()
    }

    func resume() {
        isPaused = false
    }

    func setApplicationActive(_ active: Bool) {
        guard mode != .online else { return }
        isPaused = !active
    }

    /// The court as it currently stands, cut for the ball now in play. Read
    /// off the engine rather than a stored value so it can never disagree
    /// with the physics the ball is actually obeying.
    private var court: ArenaGeometry { court(for: engine.configuration) }

    private func court(for configuration: SimulationConfiguration) -> ArenaGeometry {
        Self.court(for: configuration, mode: mode, isDoubles: isDoubles, ringPilots: ringPilots)
    }

    /// The one place a table's court is cut: the ring for this many pilots,
    /// doubles or duel, for this ball, with the chosen layout's walls built
    /// in. Only the portal court takes a layout; the parked volleyball and
    /// hoop courts stay as they were, and the ring has none.
    private static func court(
        for configuration: SimulationConfiguration,
        mode: GameMode,
        isDoubles: Bool,
        ringPilots: Int?
    ) -> ArenaGeometry {
        if let ringPilots {
            return .freeForAll(pilots: ringPilots, ballRadius: configuration.ballRadius, tuning: configuration.ring)
        }
        let court = isDoubles ? ArenaGeometry.doubles(ballRadius: configuration.ballRadius)
            : mode.court(ballRadius: configuration.ballRadius, ring: configuration.ring)
        guard court.netStyle == .roofPortal else { return court }
        return court.laidOut(configuration.arenaLayout)
    }

    /// The pilot's sliders, as this table plays them: doubles fixes the
    /// ball count and size whatever the slider says.
    private func resolved(_ configuration: SimulationConfiguration) -> SimulationConfiguration {
        Self.resolved(configuration, mode: mode, isDoubles: isDoubles, isFreeForAll: isFreeForAll)
    }

    /// Free-for-all plays one ball, or two when the ring's Two balls is on,
    /// whatever the duel's settings say. How it
    /// flies and where its nets and lines stand are the pilot's ring settings
    /// offline; online they are the host's, already in the configuration
    /// that came with the seating plan.
    private static func resolved(
        _ configuration: SimulationConfiguration,
        mode: GameMode,
        isDoubles: Bool,
        isFreeForAll: Bool
    ) -> SimulationConfiguration {
        if isDoubles { return .doubles(from: configuration) }
        var configuration = configuration
        if isFreeForAll {
            if mode.isOffline { configuration.ring = RingTuning.stored() }
            configuration.ballCount = configuration.ring.twoBalls ? 2 : 1
        }
        return configuration
    }

    func applyTuning(_ configuration: SimulationConfiguration) {
        guard mode.isOffline else { return }
        let configuration = resolved(configuration)
        engine.updateConfiguration(configuration)
        // The mouth is cut to the ball, so moving the size slider re-cuts
        // the court under the ball in the same breath.
        engine.updateArena(court(for: configuration))
        scene.arena = engine.arena
        scene.tractorRange = engine.configuration.tractorRange
        scene.boltPunch = engine.configuration.boltPunch
        for seat in pilots.keys { pilots[seat]?.updateConfiguration(configuration) }
        for seat in fieldPilots.keys { fieldPilots[seat]?.updateConfiguration(configuration) }
        demoAI?.updateConfiguration(configuration)
    }

    /// Whole seconds left in the break between sets, or nil outside one. Read
    /// off the engine's serve clock, so a guest counts down with the host.
    var setBreakCountdown: Int? {
        guard state.match.phase == .serve, state.setBreak else { return nil }
        return Int((Double(state.serveTicksRemaining) * engine.configuration.stepDuration).rounded(.up))
    }

    /// Play Again: same rival, same format, new countdown. Online cannot.
    func restartMatch() {
        guard mode.isOffline else { return }
        engine.restartMatch()
        state = engine.state
        scene.snapshot = state
        Soundscape.shared.begin()
        countdown = mode.isBay ? 1 : 3
        countdownAccumulator = 0
        accumulator = 0
        lastPointText = nil
        callouts = []
        announcedStakes = (.none, .none)
        isPaused = false
        torque = 0
        thrust = false
        fire = false
        fireLatched = false
        tractor = false
        for seat in pilots.keys {
            let difficulty = pilots[seat]?.difficulty ?? .pilot
            pilots[seat] = AIController(
                difficulty: difficulty,
                configuration: engine.configuration,
                arena: court
            )
        }
        for seat in fieldPilots.keys {
            let difficulty = fieldPilots[seat]?.difficulty ?? .pilot
            fieldPilots[seat] = FreeForAllPilot(difficulty: difficulty, configuration: engine.configuration)
        }
        knockedOut = []
        if demoAI != nil {
            demoAI = AIController(difficulty: .pilot, configuration: engine.configuration, arena: court)
        }
        SoundBank.shared.stopEverything()
        thrustingTeams = []
        thrustCenter = [:]
        offsideLastFrame = []
    }

    func restartRally(with configuration: SimulationConfiguration) {
        guard mode.isOffline, state.match.phase != .finished else { return }
        let configuration = resolved(configuration)
        engine.updateConfiguration(configuration)
        scene.tractorRange = engine.configuration.tractorRange
        scene.boltPunch = engine.configuration.boltPunch
        for seat in pilots.keys { pilots[seat]?.updateConfiguration(configuration) }
        for seat in fieldPilots.keys { fieldPilots[seat]?.updateConfiguration(configuration) }
        demoAI?.updateConfiguration(configuration)
        engine.prepareNextRally(mirrored: false)
        state = engine.state
        scene.snapshot = state
        countdown = 3
        countdownAccumulator = 0
        accumulator = 0
        torque = 0
        thrust = false
        fire = false
        fireLatched = false
        tractor = false
    }

    private func frame(timestamp: CFTimeInterval) {
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return
        }
        let elapsed = min(timestamp - previousTimestamp, 0.1)
        self.previousTimestamp = timestamp
        if let oldest = callouts.first, timestamp - oldest.born > Self.calloutLife {
            callouts.removeAll { timestamp - $0.born > Self.calloutLife }
        }
        // Ahead of the pause guard on purpose. A pause with the throttle down
        // has to let the bed coast to silence rather than freeze mid-swell.
        driveThrusterBed(dt: elapsed)
        Soundscape.shared.update(match: state.match, paused: isPaused)
        guard !isPaused else { return }

        switch state.match.phase {
        case .countdown:
            countdownAccumulator += elapsed
            while countdownAccumulator >= 1, countdown > 0 {
                countdownAccumulator -= 1
                countdown -= 1
            }
            // A guest never kicks off on its own count: the host's first
            // snapshot carries the whistle. Two boards counting on their own
            // clocks used to start a second apart, and the guest's ball was
            // already falling when the host's snapshot yanked it back.
            if countdown == 0, mode != .online || online?.isAuthoritative == true {
                engine.beginPlay()
                state = engine.state
                announceStakes()
            }
        case .serve, .playing:
            accumulator += elapsed
            while accumulator >= engine.configuration.stepDuration {
                accumulator -= engine.configuration.stepDuration
                simulateOneTick()
            }
        case .paused, .finished:
            break
        }

        smoothing.decay(dt: elapsed)
        scene.snapshot = smoothing.apply(to: state)
        scene.reduceMotion = UIAccessibility.isReduceMotionEnabled
    }

    private func simulateOneTick() {
        let tick = engine.state.tick
        var localInput = PlayerInput(tick: tick, torque: torque, thrust: thrust, fire: fire || fireLatched, tractor: tractor)
        // Online only every other tick goes out. A tap that landed on an odd
        // tick and was cleared there never reached the host.
        if mode != .online || tick.isMultiple(of: 2) { fireLatched = false }
        if var demoAI {
            localInput = demoAI.input(for: engine.state, seat: localSeat, tick: tick)
            self.demoAI = demoAI
        }
        if mode == .online {
            // Online, the thumb is read on the ticks it is sent and held
            // between them -- exactly what the host plays, since it holds
            // each input until the next arrives. Reading it every tick here
            // meant any change on an odd tick was a guaranteed disagreement
            // with the host, and a correction on the next snapshot.
            if tick.isMultiple(of: 2) {
                heldOnlineInput = localInput
            } else if let held = heldOnlineInput {
                localInput = PlayerInput(
                    tick: tick, torque: held.torque, thrust: held.thrust,
                    fire: held.fire, tractor: held.tractor
                )
            }
        }
        if Self.holdBeamPreview, let seat = flownSeat, let ship = engine.state.ships[seat],
           engine.state.match.phase == .playing {
            // `--hold-beam`: for screenshots of the beam lock. The pilot's
            // beam is held throughout, and the first live ball is set just
            // off the nose so the lock closes on it.
            localInput = PlayerInput(
                tick: tick, torque: localInput.torque, thrust: localInput.thrust,
                fire: localInput.fire, tractor: true
            )
            if !holdBeamStaged {
                holdBeamStaged = true
                engine.state.balls[0].position = ship.position + SIMD2(cos(ship.angle), sin(ship.angle)) * 0.3
                engine.state.balls[0].velocity = .zero
            }
        }
        latestLocalInput = localInput
        var inputs: [Seat: PlayerInput] = [:]
        if let flownSeat { inputs[flownSeat] = localInput }
        if mode == .online, let online {
            // The host keeps the book; a guest, or a host that just stepped
            // up, follows or leads accordingly from this tick on.
            engine.followsHost = !online.isAuthoritative
            // A pilot who connected after kick-off takes over the bot's chair
            // the moment the host seats them.
            for seat in pilots.keys where online.filledSeats.contains(seat) {
                pilots[seat] = nil
            }
            for seat in fieldPilots.keys where online.filledSeats.contains(seat) {
                fieldPilots[seat] = nil
            }
            // A teammate whose hold ran out left their chair empty: a bot
            // flies it so the one who stayed is not a pilot short. So does
            // a guest who took over hosting from a host that ran the bots.
            // A guest runs the same bots too -- the pilot is deterministic,
            // so its prediction of the bot's ship stays close to the host's
            // instead of leaving every bot dead in the air between snapshots.
            // On the ring the chair goes to a ring bot.
            for seat in engine.state.ships.keys where seat != flownSeat
                && pilots[seat] == nil && fieldPilots[seat] == nil && !online.filledSeats.contains(seat) {
                if isFreeForAll {
                    fieldPilots[seat] = FreeForAllPilot(difficulty: .pilot, configuration: engine.configuration)
                } else {
                    pilots[seat] = AIController(
                        difficulty: .pilot,
                        configuration: engine.configuration,
                        arena: court
                    )
                }
            }
        }
        for seat in pilots.keys.sorted() {
            guard var pilot = pilots[seat] else { continue }
            inputs[seat] = pilot.input(for: engine.state, seat: seat, tick: tick)
            pilots[seat] = pilot
        }
        for seat in fieldPilots.keys.sorted() {
            guard var pilot = fieldPilots[seat] else { continue }
            inputs[seat] = pilot.input(for: engine.state, seat: seat, arena: engine.arena, tick: tick)
            fieldPilots[seat] = pilot
        }

        switch mode {
        case .solo, .doubles, .warmup, .practice, .volleyball, .basketball, .freeForAll:
            engine.step(inputs: inputs)
        case .online:
            guard let online else { return }
            if tick.isMultiple(of: 2), !isSpectator {
                online.sendInput(localInput)
            }
            if !online.isAuthoritative, !isSpectator {
                localInputHistory[tick] = localInput
                let depth = Self.inputHistoryDepth
                if tick > depth { localInputHistory[tick - depth] = nil }
            }
            // Every other pilot on the input they sent for this very tick:
            // the host flies a guest exactly as the guest flew itself.
            for seat in engine.state.ships.keys where seat != flownSeat && inputs[seat] == nil {
                inputs[seat] = online.remoteInput(for: seat, tick: tick) ?? .idle(tick: tick)
            }
            engine.step(inputs: inputs)
            if online.isAuthoritative, tick.isMultiple(of: 6) {
                online.sendSnapshot(engine.state)
            }
        }

        state = engine.state
        announceStakes()
        events = engine.lastEvents
        announceShipCues(inputs: inputs)
        if mode.isBay {
            bestKeepUp = max(bestKeepUp, state.match.shipTouches.cyan)
            let burst = rings.observe(state)
            if !burst.isEmpty {
                ringsPopped = rings.popped
                scene.rings = rings.rings
                for ring in burst { scene.popRing(ring) }
                FeedbackCenter.shared.impact()
            }
        }
        let presentsLocalEvents = switch mode {
        case .solo, .doubles, .warmup, .practice, .volleyball, .basketball, .freeForAll: true
        case .online: online?.isAuthoritative == true
        }
        if presentsLocalEvents, !events.isEmpty { scene.present(events) }
        if presentsLocalEvents,
           let point = events.first(where: { if case .point = $0 { true } else { false } }) {
            lastPointText = point.label(
                bounceAllowance: engine.configuration.allowedFloorBounces
            )
            if case let .point(team, reason) = point {
                FeedbackCenter.shared.point(team: team, reason: reason)
            }
            if let shot = events.first(where: { if case .goalScored = $0 { true } else { false } }),
               let text = shot.goalLabel(name: callSign) {
                lastPointText = text
            }
        } else if presentsLocalEvents, events.contains(.rallyReset) {
            lastPointText = nil
        }
        if presentsLocalEvents,
           let set = events.first(where: { if case .setEnded = $0 { true } else { false } }) {
            callouts = []
            lastPointText = set.label(bounceAllowance: engine.configuration.allowedFloorBounces)
        }
        for event in events where presentsLocalEvents {
            callOut(event)
            presentFreeForAll(event)
            if case .collisionEffect = event { FeedbackCenter.shared.impactHaptic() }
            if case let .shipZapped(seat, _) = event, seat == flownSeat { FeedbackCenter.shared.impact() }
            if case let .matchEnded(winner) = event, !isSpectator {
                switch MatchEndCue.forLocalSide(localSeat.team, winner: winner) {
                case .win: FeedbackCenter.shared.win()
                case .lose: FeedbackCenter.shared.lose()
                }
            }
            if case .online = mode, online?.isAuthoritative == true {
                switch event {
                case .matchEnded, .lastPilotStanding:
                    // The final book goes out whole ahead of the call that
                    // ends the match, so every board finishes on it.
                    online?.sendFullResync(engine.state)
                default:
                    break
                }
                online?.sendEvent(event)
                if case .point = event {
                    lobby?.hostDuelScored(engine.state.match.score)
                }
                if case let .matchEnded(winner) = event {
                    lobby?.hostDuelFinished(winner: winner, score: engine.state.match.score)
                    online?.finishCompletedMatch(winner: winner)
                }
                if case .lastPilotStanding = event {
                    // The ring has no sides for the lobby's board to score.
                    online?.finishCompletedMatch()
                }
            }
        }
    }

    /// Once per finished match, on the edge into `.finished`: the local
    /// pilot's numbers go to Game Center and the personal bests are marked
    /// for the results card. Driven off the state rather than the
    /// `matchEnded` event so a guest reads the host's final book from the
    /// same snapshot that finished the match. Real matches only -- not the
    /// warm-up bay, the parked side modes, or the bench.
    private func reportStatsIfFinished(previous: MatchPhase) {
        if state.match.phase != .finished {
            if previous == .finished { newBests = [] }
            return
        }
        // A duel's winner is a team; the ring's is its last pilot. A forfeit
        // on the ring finishes the match with neither, and reports nothing.
        guard previous != .finished, state.match.winner != nil || state.freeForAll?.winner != nil,
              keepsStats, !isResultsPreview else { return }
        newBests = StatsReporter.report(state.stats, for: localSeat)
    }

    /// The name a call goes out under: the pilot's Game Center name online,
    /// yours on this phone when you are signed in, CPU for every seat a bot
    /// flies. The callout's colour says which side.
    func callSign(_ seat: Seat) -> String {
        if case .online = mode, let online,
           let id = online.seating.first(where: { $0.value == seat })?.key {
            return online.pilotName(id).uppercased()
        }
        if seat == flownSeat {
            return GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName.uppercased() : "YOU"
        }
        // Three bots on one field: CPU says nothing about which.
        if isFreeForAll { return ArenaScene.freeForAllName(for: seat) }
        return "CPU"
    }

    /// Puts a `.play` event on the feed. A repeat of a call still on screen
    /// replaces it rather than stacking, so a burst of zaps reads as one.
    private func callOut(_ event: SimulationEvent) {
        guard case let .play(seat, call) = event else { return }
        let name = callSign(seat)
        let text: String
        switch call {
        case let .zap(victim):
            text = "ZAP  \(name) → \(callSign(victim))"
        case .slam:
            text = "SLAM  \(name)"
        case let .save(kind, close):
            let what = switch kind {
            case .hull: "SAVE"
            case .bolt: "BOLT SAVE"
            case .beam: "BEAM SAVE"
            }
            text = (close ? "CLOSE " : "") + what + "  \(name)"
        }
        callouts.removeAll { $0.text == text }
        calloutSerial += 1
        callouts.append(PlayCallout(id: calloutSerial, text: text, team: seat.team, born: CACurrentMediaTime()))
        if callouts.count > 3 { callouts.removeFirst(callouts.count - 3) }
    }

    /// The free-for-all's calls: who lost a life, who is out, who won.
    private func presentFreeForAll(_ event: SimulationEvent) {
        // "YOU" takes the plural verb: YOU LOSE, not YOU LOSES.
        func says(_ seat: Seat, _ one: String, _ you: String) -> String {
            let name = callSign(seat)
            return "\(name) \(name == "YOU" ? you : one)"
        }
        switch event {
        case let .lifeLost(seat, _, left):
            lastPointText = left == 0 ? says(seat, "IS OUT", "ARE OUT")
                : says(seat, "LOSES A LIFE", "LOSE A LIFE") + " · \(left) LEFT"
            if seat == flownSeat { FeedbackCenter.shared.impact() }
        case let .pilotOut(seat):
            knockedOut.append(seat)
            if seat == flownSeat { FeedbackCenter.shared.lose() }
        case let .lastPilotStanding(seat):
            lastPointText = says(seat, "WINS", "WIN")
            if seat == flownSeat { FeedbackCenter.shared.win() }
        default:
            break
        }
    }

    /// Whether this board has a pilot whose match counts: a real match --
    /// not the warm-up bay or the parked side modes -- flown, not watched.
    /// The ring counts: its goals, slams and zaps go in the same book.
    var keepsStats: Bool {
        guard flownSeat != nil else { return false }
        return switch mode {
        case .solo, .doubles, .online, .freeForAll: true
        case .warmup, .practice, .volleyball, .basketball: false
        }
    }

    /// The two sounds that come from the ships rather than from the rulebook:
    /// scraping past your own MAX CROSS line, and holding the throttle down.
    /// Both are edge-triggered -- a cue that retriggers every frame the
    /// condition holds is not a cue, it is a buzz.
    /// Edge-triggered, like the ship cues below: only the moment a side comes
    /// to set or match point gets a sound. A stake that has been standing for
    /// three rallies is not news.
    private func announceStakes() {
        let now = (cyan: state.match.stake(for: .cyan), orange: state.match.stake(for: .orange))
        if now.cyan > announcedStakes.cyan {
            FeedbackCenter.shared.stakeRaised(team: .cyan, stake: now.cyan)
        }
        if now.orange > announcedStakes.orange {
            FeedbackCenter.shared.stakeRaised(team: .orange, stake: now.orange)
        }
        announcedStakes = now
    }

    private func announceShipCues(inputs: [Seat: PlayerInput]) {
        let limit = court.opponentCrossingLimit
        var offsideNow: Set<Seat> = []
        var thrustingNow: Set<Team> = []
        // Both ships on a team share one voice, so the burn is panned to the
        // middle of whoever is actually burning rather than to whichever ship
        // the dictionary happened to visit last.
        var burnSum: [Team: Double] = [:]
        var burnCount: [Team: Double] = [:]

        // `homeSide` is the half a hull flies, which changes between sets;
        // the voice belongs to the seat's colour, which never does.
        for (seat, ship) in state.ships {
            let intrusionSign = ship.homeSide == .cyan ? 1.0 : -1.0
            // On the ring only your own hull calls it: three bots leaning
            // on their lines would chirp all match.
            let offside = isFreeForAll
                ? seat == localSeat && engine.ringOffside(ship.position, seat: seat) != nil
                : ship.position.x * intrusionSign > limit
            if offside {
                offsideNow.insert(seat)
                if !offsideLastFrame.contains(seat) {
                    FeedbackCenter.shared.crossedOffside(
                        team: seat.team,
                        positionX: ship.position.x
                    )
                }
            }
            if inputs[seat]?.thrust == true, state.match.phase == .playing {
                thrustingNow.insert(seat.team)
                burnSum[seat.team, default: 0] += ship.position.x
                burnCount[seat.team, default: 0] += 1
            }
        }
        offsideLastFrame = offsideNow
        thrustingTeams = thrustingNow
        for team in Team.allCases where burnCount[team] != nil {
            thrustCenter[team] = burnSum[team]! / burnCount[team]!
        }
    }

    /// The thruster bed, one display frame's worth. It runs every frame
    /// rather than on the press and release edges, because the whole point is
    /// that the sound is still changing while the pad sits there.
    private func driveThrusterBed(dt: CFTimeInterval) {
        // `announceShipCues` only runs on the ticks it is asked for, so the
        // last set of burning teams sits there through a countdown or a
        // finish. The bed has to answer the phase, not the stale set, or a
        // point scored with the throttle down drones under the restart.
        let playing = !isPaused && state.match.phase == .playing
        let live = playing ? thrustingTeams : []
        for team in Team.allCases {
            SoundBank.shared.driveLoop(
                .thruster(team),
                pressed: live.contains(team),
                positionX: Float(thrustCenter[team] ?? 0),
                dt: dt
            )
            // The hum answers the same phase gate: a beam held through a
            // restart would otherwise drone under the countdown.
            let pulls = scene.beamPulls.filter { $0.key.team == team }.values
            SoundBank.shared.driveHum(
                team,
                active: playing && !pulls.isEmpty,
                grip: pulls.map(\.grip).max() ?? 0,
                positionX: Float(pulls.first?.x ?? 0),
                dt: dt
            )
        }
    }

    private func installOnlineCallbacks() {
        guard let online else { return }
        online.onSnapshot = { [weak self] authoritative in
            guard let self, !online.isAuthoritative else { return }
            let displayed = self.smoothing.apply(to: self.state)
            let predicted = self.engine.state
            // The snapshot left the host half a round trip ago. Re-run the
            // ticks since, with the inputs this board really sent, up to where
            // its clock should be: a round trip ahead of the snapshot, so what
            // it sends lands before the host plays that tick. With the host
            // playing each input on its own tick, the two then agree and this
            // board's own ship does not move under the pilot. See
            // `GuestClock` and `GuestRollForward`, and the latency tests that
            // measure it.
            let target = GuestClock.target(
                predicted: predicted.tick,
                authoritative: authoritative.tick,
                roundTripTicks: online.roundTripTicks
            )
            let history = self.localInputHistory
            let latest = self.latestLocalInput
            let resolution = GuestRollForward.resolve(
                authoritative: authoritative,
                predicted: predicted,
                target: target,
                // Keep the online physics and court: a rebuilt engine
                // defaults to the solo tuning and the nominal goal mouth.
                configuration: self.engine.configuration,
                arena: self.engine.arena,
                flownSeat: self.flownSeat,
                bots: self.pilots,
                fieldBots: self.fieldPilots,
                localInput: { history[$0] ?? latest ?? .idle(tick: $0) },
                remoteInput: { seat, tick in online.remoteInput(for: seat, tick: tick) ?? .idle(tick: tick) }
            )
            self.pilots = resolution.bots
            self.fieldPilots = resolution.fieldBots
            let resolved = resolution.state
            self.engine = SimulationEngine(
                state: resolved,
                configuration: self.engine.configuration,
                arena: self.engine.arena
            )
            self.engine.followsHost = true
            // Only a clock thrown well back -- a snapshot too old to roll
            // forward -- makes the inputs kept under its old tick numbers
            // wrong. A tick's easing back re-flies those numbers, which is
            // exactly what they are kept for.
            if resolved.tick + 1 < predicted.tick { self.localInputHistory = [:] }
            self.smoothing.capture(displayed: displayed, corrected: resolved, excluding: self.flownSeat)
            self.state = resolved
            self.announceStakes()
        }
        online.onResync = { [weak self] authoritative in
            guard let self else { return }
            self.engine = SimulationEngine(
                state: authoritative,
                configuration: self.engine.configuration,
                arena: self.engine.arena
            )
            self.engine.followsHost = !online.isAuthoritative
            self.smoothing.reset()
            self.localInputHistory = [:]
            self.state = authoritative
            self.announceStakes()
            self.isPaused = false
            self.countdown = 3
            self.countdownAccumulator = 0
        }
        online.onEvent = { [weak self] event in
            guard let self, !online.isAuthoritative else { return }
            self.events = [event]
            self.scene.present([event])
            switch event {
            case let .point(team, reason):
                self.lastPointText = event.label(
                    bounceAllowance: self.engine.configuration.allowedFloorBounces
                )
                FeedbackCenter.shared.point(team: team, reason: reason)
            case .goalScored:
                if let text = event.goalLabel(name: self.callSign) { self.lastPointText = text }
            case .play:
                self.callOut(event)
            case .rallyReset:
                self.lastPointText = nil
            case .setEnded:
                self.callouts = []
                self.lastPointText = event.label(
                    bounceAllowance: self.engine.configuration.allowedFloorBounces
                )
            case .collisionEffect:
                FeedbackCenter.shared.impactHaptic()
            case let .shipZapped(seat, _):
                if seat == self.flownSeat { FeedbackCenter.shared.impact() }
            case .destruction:
                FeedbackCenter.shared.impact()
            case .lifeLost, .pilotOut:
                self.presentFreeForAll(event)
            case .lastPilotStanding:
                self.presentFreeForAll(event)
                online.finishCompletedMatch()
            case let .matchEnded(winner):
                // The bench cheers nobody in particular.
                if !self.isSpectator { FeedbackCenter.shared.win() }
                // The winner matters to a table host that was not running
                // this duel -- it keeps them on for the next.
                online.finishCompletedMatch(winner: winner)
            }
        }
        online.onEmote = { [weak self] seat, emote in
            guard let self, !UserDefaults.standard.bool(forKey: Self.muteEmotesKey) else { return }
            var heard = self.heardEmotes[seat] ?? EmoteCooldown(interval: EmoteCooldown.interval - 0.5)
            guard heard.attempt(at: CACurrentMediaTime()) else { return }
            self.heardEmotes[seat] = heard
            self.scene.playEmote(emote, for: seat)
        }
        online.onForfeit = { [weak self] winner in
            guard let self else { return }
            self.engine.finishByForfeit(winner: winner)
            self.state = self.engine.state
            self.events = self.engine.lastEvents
            if online.isAuthoritative {
                self.lobby?.hostDuelFinished(winner: winner, score: self.state.match.score)
                // At a table the link stays up: tell every board the duel is
                // over, rather than leave each to its own hold clock.
                if online.openTable != nil {
                    online.sendFullResync(self.engine.state)
                    for event in self.engine.lastEvents { online.sendEvent(event) }
                }
            }
        }
        online.onConnectionPaused = { [weak self] paused in
            self?.isPaused = paused
        }
        online.onReconnect = { [weak self] in
            guard let self else { return }
            self.isPaused = false
            if online.isAuthoritative {
                self.countdown = 3
                self.countdownAccumulator = 0
                self.engine.prepareNextRally(mirrored: false)
                self.state = self.engine.state
                online.sendFullResync(self.engine.state)
            }
        }
    }
}

@MainActor
/// A display link that hands its timestamp back on the main actor. Shared by
/// the arena and the circuit -- both want the same fixed-step pump.
final class FrameDriver: NSObject {
    private let onFrame: @MainActor (CFTimeInterval) -> Void
    private var displayLink: CADisplayLink?

    init(onFrame: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        onFrame(link.timestamp)
    }
}

private extension SimulationEvent {
    func label(bounceAllowance: Int) -> String {
        if case let .setEnded(winner, sets) = self {
            return "\(winner == .cyan ? "CYAN" : "ORANGE") TAKES THE SET · \(sets.cyan)–\(sets.orange)"
        }
        guard case let .point(team, reason) = self else { return "" }
        let scorer = team == .cyan ? "CYAN" : "ORANGE"
        switch reason {
        case .goal: return "\(scorer) GOAL"
        case .thirdBounce: return "BOUNCE LIMIT (\(bounceAllowance)) — \(scorer)"
        case .crash: return "CRASH — \(scorer)"
        case .netContact: return "NET / CROSS — \(scorer)"
        case .forfeit: return "FORFEIT — \(scorer)"
        }
    }

    /// The call for how a goal went in, under the scorer's name.
    func goalLabel(name: (Seat) -> String) -> String? {
        guard case let .goalScored(seat, style) = self else { return nil }
        let who = name(seat)
        return switch style {
        case .hull: "GOAL — \(who)"
        case .bolt: "BOLT GOAL — \(who)"
        case .slamDunk: "SLAM DUNK — \(who)"
        case .ownGoal: "OWN GOAL — \(who)"
        }
    }
}

/// One play on the call feed.
struct PlayCallout: Identifiable, Equatable {
    let id: Int
    let text: String
    let team: Team
    let born: CFTimeInterval
}
