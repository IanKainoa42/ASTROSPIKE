import ASTROSPIKECore
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
    /// The net comes off the roof and stands up out of the floor, covering
    /// the bottom half of the arena. Play it over the top; the floor is live.
    case volleyball(AIDifficulty)
    /// One rim at centre court that both halves shoot at. First ball through
    /// it takes the match, for whoever touched it last.
    case basketball(AIDifficulty)

    /// Everything but a Game Center match: nothing on the wire, the pilot's
    /// own tuning applies.
    var isOffline: Bool {
        switch self {
        case .solo, .doubles, .volleyball, .basketball: true
        case .online, .warmup: false
        }
    }

    /// The court this mode is played on. The arena carries the whole of what
    /// makes a mode different -- the hump, the net, the hoop -- so the engine
    /// and the renderer only have to agree on this one value.
    ///
    /// It is cut for the ball that will be played on it: the goal mouth has
    /// to be taller than the ball is wide, and the ball is a slider now.
    func court(ballRadius: Double) -> ArenaGeometry {
        switch self {
        case .volleyball: .volleyball
        case .basketball: .basketball(ballRadius: ballRadius)
        case .solo, .doubles, .online, .warmup: .standard(ballRadius: ballRadius)
        }
    }

    /// What the board should call it.
    var title: String {
        switch self {
        case .solo: "SOLO FLIGHT"
        case .doubles: "DOUBLES"
        case .online: "ONLINE DUEL"
        case .warmup: "WARM-UP BAY"
        case .volleyball: "VOLLEYBALL"
        case .basketball: "BASKETBALL"
        }
    }

    /// The bot ladder this mode is on, if any. Online and the bay have none.
    var rivalDifficulty: AIDifficulty? {
        switch self {
        case let .solo(difficulty), let .doubles(difficulty),
             let .volleyball(difficulty), let .basketball(difficulty):
            difficulty
        case .online, .warmup:
            nil
        }
    }

    func withRival(_ difficulty: AIDifficulty) -> GameMode {
        switch self {
        case .solo: .solo(difficulty)
        case .doubles: .doubles(difficulty)
        case .volleyball: .volleyball(difficulty)
        case .basketball: .basketball(difficulty)
        case .online, .warmup: self
        }
    }
}

@MainActor
@Observable
final class GameSession {
    private(set) var state: WorldState
    private(set) var events: [SimulationEvent] = []
    private(set) var countdown = 3
    private(set) var lastPointText: String?
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
    /// The host mirrors the score to the lobby; guests leave it alone.
    private weak var lobby: LobbyService?
    private var frameDriver: FrameDriver?
    private var accumulator = 0.0
    private var previousTimestamp: CFTimeInterval?
    private var countdownAccumulator = 0.0
    /// The guest's own recent inputs by tick, so a snapshot that lands behind
    /// the local clock can be rolled forward through what the thumb did since.
    private var localInputHistory: [UInt64: PlayerInput] = [:]
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
        var initialEngine = SimulationEngine.testing()
        let roster: Set<Seat>
        var botSeats: [Seat: AIDifficulty] = [:]
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
        case .warmup:
            // Nobody to defend against, and no ceremony before the first serve.
            roster = [.cyan]
            countdown = 1
        case .online:
            let filled = online?.filledSeats ?? Seat.singles
            // Three pilots, or a team-up of two, play doubles with the host
            // flying the empty chairs.
            roster = OnlineSeating.roster(filled: filled, teamUp: online?.teamUp ?? false)
            if online?.isAuthoritative == true {
                for seat in roster.subtracting(filled) { botSeats[seat] = .pilot }
            }
        }
        let isDoubles = roster == Seat.doubles
        self.isDoubles = isDoubles
        let configuration = isDoubles ? SimulationConfiguration.doubles(from: configuration) : configuration
        let court = isDoubles ? ArenaGeometry.doubles(ballRadius: configuration.ballRadius)
            : mode.court(ballRadius: configuration.ballRadius)
        initialEngine.updateConfiguration(configuration)
        // The court goes on before the roster: the opening ball is staged as
        // part of seating, and it is staged into this arena.
        initialEngine.updateArena(court)
        initialEngine.configureRoster(roster)
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
        engine = initialEngine
        state = initialEngine.state
        for (seat, difficulty) in botSeats {
            pilots[seat] = AIController(difficulty: difficulty, configuration: configuration, arena: court)
        }
        if mode != .online, ProcessInfo.processInfo.arguments.contains("--demo") {
            demoAI = AIController(difficulty: .pilot, configuration: configuration, arena: court)
        }
        scene.scaleMode = .resizeFill
        scene.arena = court
        scene.tractorRange = engine.configuration.tractorRange
        scene.boltPunch = engine.configuration.boltPunch
        scene.snapshot = state
        // After the snapshot: the goal calls are drawn for the ends in it.
        scene.localTeam = mode == .warmup || isSpectator ? nil : localSeat.team
        scene.localSeat = mode == .warmup || isSpectator ? nil : localSeat
        if mode == .warmup { scene.rings = rings.rings }
        if let winner = finishedAs {
            engine.finishByForfeit(winner: winner)
            state = engine.state
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
        thrustingTeams = []
        thrustCenter = [:]
        offsideLastFrame = []
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
        isDoubles ? .doubles(ballRadius: configuration.ballRadius) : mode.court(ballRadius: configuration.ballRadius)
    }

    /// The pilot's sliders, as this table plays them: doubles fixes the
    /// ball count and size whatever the slider says.
    private func resolved(_ configuration: SimulationConfiguration) -> SimulationConfiguration {
        isDoubles ? .doubles(from: configuration) : configuration
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
        countdown = mode == .warmup ? 1 : 3
        countdownAccumulator = 0
        accumulator = 0
        lastPointText = nil
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
            // A teammate whose hold ran out left their chair empty: a bot
            // flies it so the one who stayed is not a pilot short. So does
            // a guest who took over hosting from a host that ran the bots.
            // A guest runs the same bots too -- the pilot is deterministic,
            // so its prediction of the bot's ship stays close to the host's
            // instead of leaving every bot dead in the air between snapshots.
            for seat in engine.state.ships.keys where seat != flownSeat
                && pilots[seat] == nil && !online.filledSeats.contains(seat) {
                pilots[seat] = AIController(
                    difficulty: .pilot,
                    configuration: engine.configuration,
                    arena: court
                )
            }
        }
        for seat in pilots.keys.sorted() {
            guard var pilot = pilots[seat] else { continue }
            inputs[seat] = pilot.input(for: engine.state, seat: seat, tick: tick)
            pilots[seat] = pilot
        }

        switch mode {
        case .solo, .doubles, .warmup, .volleyball, .basketball:
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
        if mode == .warmup {
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
        case .solo, .doubles, .warmup, .volleyball, .basketball: true
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
        } else if presentsLocalEvents, events.contains(.rallyReset) {
            lastPointText = nil
        }
        if presentsLocalEvents,
           let set = events.first(where: { if case .setEnded = $0 { true } else { false } }) {
            lastPointText = set.label(bounceAllowance: engine.configuration.allowedFloorBounces)
        }
        for event in events where presentsLocalEvents {
            if case .collisionEffect = event { FeedbackCenter.shared.impactHaptic() }
            if case let .matchEnded(winner) = event, !isSpectator {
                switch MatchEndCue.forLocalSide(localSeat.team, winner: winner) {
                case .win: FeedbackCenter.shared.win()
                case .lose: FeedbackCenter.shared.lose()
                }
            }
            if case .online = mode, online?.isAuthoritative == true {
                if case .matchEnded = event {
                    online?.sendFullResync(engine.state)
                }
                online?.sendEvent(event)
                if case .point = event {
                    lobby?.hostDuelScored(engine.state.match.score)
                }
                if case let .matchEnded(winner) = event {
                    lobby?.hostDuelFinished(winner: winner, score: engine.state.match.score)
                    online?.finishCompletedMatch(winner: winner)
                }
            }
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
            if ship.position.x * intrusionSign > limit {
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
                localInput: { history[$0] ?? latest ?? .idle(tick: $0) },
                remoteInput: { seat, tick in online.remoteInput(for: seat, tick: tick) ?? .idle(tick: tick) }
            )
            self.pilots = resolution.bots
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
            case .rallyReset:
                self.lastPointText = nil
            case .setEnded:
                self.lastPointText = event.label(
                    bounceAllowance: self.engine.configuration.allowedFloorBounces
                )
            case .collisionEffect:
                FeedbackCenter.shared.impactHaptic()
            case .destruction:
                FeedbackCenter.shared.impact()
            case let .matchEnded(winner):
                // The bench cheers nobody in particular.
                if !self.isSpectator { FeedbackCenter.shared.win() }
                // The winner matters to a table host that was not running
                // this duel -- it keeps them on for the next.
                online.finishCompletedMatch(winner: winner)
            }
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
}
