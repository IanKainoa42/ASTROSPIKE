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
    var court: ArenaGeometry {
        switch self {
        case .volleyball: .volleyball
        case .basketball: .basketball
        case .solo, .doubles, .online, .warmup: .standard
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
    /// Which teams had an engine lit last frame, so the thruster bed starts
    /// and stops on the edges rather than restarting sixty times a second.
    private var thrustingLastFrame: Set<Team> = []
    let localSeat: Seat
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
    /// How many ticks a late snapshot may be re-simulated before it just snaps.
    private static let maximumRollForward: UInt64 = 24

    init(
        mode: GameMode,
        online: OnlineMatchCoordinator? = nil,
        lobby: LobbyService? = nil,
        configuration: SimulationConfiguration = .init(),
        setsToWin: Int = 1,
        localHull: Hull = .lancet,
        rivalHull: Hull = .anvil
    ) {
        self.mode = mode
        self.online = online
        self.lobby = lobby
        let localSeat = mode == .online ? (online?.localSeat ?? .cyan) : .cyan
        self.localSeat = localSeat
        var initialEngine = SimulationEngine.testing()
        initialEngine.updateConfiguration(configuration)
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
            // Three pilots play doubles with the host flying the empty wing.
            roster = filled.count > 2 ? Seat.doubles : Seat.singles
            if online?.isAuthoritative == true {
                for seat in roster.subtracting(filled) { botSeats[seat] = .pilot }
            }
        }
        // The court goes on before the roster: the opening ball is staged as
        // part of seating, and it is staged into this arena.
        initialEngine.updateArena(mode.court)
        initialEngine.configureRoster(roster)
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
            pilots[seat] = AIController(difficulty: difficulty, configuration: configuration, arena: mode.court)
        }
        if mode != .online, ProcessInfo.processInfo.arguments.contains("--demo") {
            demoAI = AIController(difficulty: .pilot, configuration: configuration, arena: mode.court)
        }
        scene.scaleMode = .resizeFill
        scene.arena = mode.court
        scene.tractorRange = engine.configuration.tractorRange
        scene.snapshot = state
        if mode == .warmup { scene.rings = rings.rings }
        for seat in Seat.allCases {
            let hull: Hull = if seat == localSeat {
                localHull
            } else if let remote = online?.remoteHulls[seat], mode == .online {
                remote
            } else if seat == Seat.lead(localSeat.team.opponent) {
                rivalHull
            } else {
                Hull.defaultHull(forSeat: seat)
            }
            scene.setHull(hull, for: seat)
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
        thrustingLastFrame = []
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

    func applyTuning(_ configuration: SimulationConfiguration) {
        guard mode.isOffline else { return }
        engine.updateConfiguration(configuration)
        scene.tractorRange = engine.configuration.tractorRange
        for seat in pilots.keys { pilots[seat]?.updateConfiguration(configuration) }
        demoAI?.updateConfiguration(configuration)
    }

    func restartRally(with configuration: SimulationConfiguration) {
        guard mode.isOffline, state.match.phase != .finished else { return }
        engine.updateConfiguration(configuration)
        scene.tractorRange = engine.configuration.tractorRange
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
        guard !isPaused else { return }

        switch state.match.phase {
        case .countdown:
            countdownAccumulator += elapsed
            while countdownAccumulator >= 1, countdown > 0 {
                countdownAccumulator -= 1
                countdown -= 1
            }
            if countdown == 0 {
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
        fireLatched = false
        if var demoAI {
            localInput = demoAI.input(for: engine.state, seat: localSeat, tick: tick)
            self.demoAI = demoAI
        }
        var inputs: [Seat: PlayerInput] = [localSeat: localInput]
        // A pilot who connected after kick-off takes over the bot's chair the
        // moment the host seats them.
        if mode == .online, let online, online.isAuthoritative {
            for seat in pilots.keys where online.filledSeats.contains(seat) {
                pilots[seat] = nil
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
            if tick.isMultiple(of: 2) {
                online.sendInput(localInput)
            }
            if !online.isAuthoritative {
                localInputHistory[tick] = localInput
                if tick > 64 { localInputHistory[tick - 64] = nil }
            }
            let remote = online.remoteInputs
            for seat in engine.state.ships.keys where seat != localSeat && inputs[seat] == nil {
                inputs[seat] = remote[seat] ?? .idle(tick: tick)
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
            if case .collisionEffect = event { FeedbackCenter.shared.impact() }
            if case .matchEnded = event { FeedbackCenter.shared.win() }
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
                    online?.finishCompletedMatch()
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
        let limit = mode.court.opponentCrossingLimit
        var offsideNow: Set<Seat> = []
        var thrustingNow: Set<Team> = []
        var thrustCenter: [Team: Double] = [:]

        for (seat, ship) in state.ships {
            let intrusionSign = ship.homeSide == .cyan ? 1.0 : -1.0
            if ship.position.x * intrusionSign > limit {
                offsideNow.insert(seat)
                if !offsideLastFrame.contains(seat) {
                    FeedbackCenter.shared.crossedOffside(
                        team: ship.homeSide,
                        positionX: ship.position.x
                    )
                }
            }
            if inputs[seat]?.thrust == true, state.match.phase == .playing {
                thrustingNow.insert(ship.homeSide)
                thrustCenter[ship.homeSide] = ship.position.x
            }
        }
        offsideLastFrame = offsideNow

        for team in Team.allCases {
            let cue = SoundBank.Cue.thruster(team)
            if thrustingNow.contains(team) {
                SoundBank.shared.startLoop(
                    cue,
                    positionX: Float(thrustCenter[team] ?? 0)
                )
            } else if thrustingLastFrame.contains(team) {
                SoundBank.shared.stopLoop(cue)
            }
        }
        thrustingLastFrame = thrustingNow
    }

    private func installOnlineCallbacks() {
        guard let online else { return }
        online.onSnapshot = { [weak self] authoritative in
            guard let self, !online.isAuthoritative else { return }
            let displayed = self.smoothing.apply(to: self.state)
            let predicted = self.engine.state
            // Keep the online physics: a rebuilt engine defaults to the solo
            // tuning, and the guest's own ship then flies a different game
            // between snapshots.
            var rolled = SimulationEngine(state: authoritative, configuration: self.engine.configuration)
            // The snapshot left the host a ping ago. Re-run the ticks the guest
            // has already flown since, with the inputs it actually gave, so the
            // world never steps backwards on arrival.
            let behind = predicted.tick > authoritative.tick ? predicted.tick - authoritative.tick : 0
            let remote = online.remoteInputs
            if behind <= Self.maximumRollForward, [.serve, .playing].contains(self.state.match.phase) {
                while rolled.state.tick < predicted.tick {
                    let tick = rolled.state.tick
                    var inputs: [Seat: PlayerInput] = [
                        self.localSeat: self.localInputHistory[tick] ?? .idle(tick: tick),
                    ]
                    for seat in rolled.state.ships.keys where seat != self.localSeat {
                        inputs[seat] = remote[seat] ?? .idle(tick: tick)
                    }
                    rolled.step(inputs: inputs)
                }
            }
            var resolved = rolled.state
            if let mine = predicted.ships[self.localSeat], let hostShip = resolved.ships[self.localSeat] {
                resolved.ships[self.localSeat] = StateReconciler().reconcile(
                    predicted: mine,
                    authoritative: hostShip
                )
            }
            self.engine = SimulationEngine(state: resolved, configuration: self.engine.configuration)
            self.smoothing.capture(displayed: displayed, corrected: resolved, excluding: self.localSeat)
            self.state = resolved
            self.announceStakes()
        }
        online.onResync = { [weak self] authoritative in
            guard let self else { return }
            self.engine = SimulationEngine(state: authoritative, configuration: self.engine.configuration)
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
                FeedbackCenter.shared.impact()
            case .destruction:
                FeedbackCenter.shared.impact()
            case .matchEnded:
                FeedbackCenter.shared.win()
                online.finishCompletedMatch()
            }
        }
        online.onForfeit = { [weak self] winner in
            guard let self else { return }
            self.engine.finishByForfeit(winner: winner)
            self.state = self.engine.state
            self.events = self.engine.lastEvents
            if online.isAuthoritative {
                self.lobby?.hostDuelFinished(winner: winner, score: self.state.match.score)
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
        case .touchLimit: return "TOO MANY TOUCHES — \(scorer)"
        case .crash: return "CRASH — \(scorer)"
        case .netContact: return "NET / CROSS — \(scorer)"
        case .forfeit: return "FORFEIT — \(scorer)"
        }
    }
}
