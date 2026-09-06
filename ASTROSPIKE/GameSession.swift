import ASTROSPIKECore
import Observation
import QuartzCore
import SwiftUI

enum GameMode: Equatable {
    case solo(AIDifficulty)
    case online
}

@MainActor
@Observable
final class GameSession {
    private(set) var state: WorldState
    private(set) var events: [SimulationEvent] = []
    private(set) var countdown = 3
    private(set) var lastPointText: String?
    private(set) var isPaused = false

    var torque = 0.0
    var thrust = false

    let mode: GameMode
    let scene = ArenaScene()

    private var engine: SimulationEngine
    private var ai: AIController?
    private var demoAI: AIController?
    private weak var online: OnlineMatchCoordinator?
    private var frameDriver: FrameDriver?
    private var accumulator = 0.0
    private var previousTimestamp: CFTimeInterval?
    private var countdownAccumulator = 0.0

    init(
        mode: GameMode,
        online: OnlineMatchCoordinator? = nil,
        configuration: SimulationConfiguration = .init(),
        localHull: Hull = .lancet,
        rivalHull: Hull = .anvil
    ) {
        self.mode = mode
        self.online = online
        var initialEngine = SimulationEngine.testing()
        initialEngine.updateConfiguration(configuration)
        initialEngine.prepareNextRally(mirrored: false)
        engine = initialEngine
        state = initialEngine.state
        if case let .solo(difficulty) = mode {
            ai = AIController(difficulty: difficulty, configuration: configuration)
            if ProcessInfo.processInfo.arguments.contains("--demo") {
                demoAI = AIController(difficulty: .pilot, configuration: configuration)
            }
        }
        scene.scaleMode = .resizeFill
        scene.snapshot = state
        let localTeam = online?.localTeam ?? .cyan
        scene.setHull(localHull, for: localTeam)
        scene.setHull(online?.remoteHull ?? rivalHull, for: localTeam.opponent)
        installOnlineCallbacks()
    }

    func start() {
        guard frameDriver == nil else { return }
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
    }

    func togglePause() {
        guard state.match.phase != .finished else { return }
        isPaused.toggle()
    }

    func resume() {
        isPaused = false
    }

    func setApplicationActive(_ active: Bool) {
        guard case .solo = mode else { return }
        isPaused = !active
    }

    func applyTuning(_ configuration: SimulationConfiguration) {
        guard case .solo = mode else { return }
        engine.updateConfiguration(configuration)
        ai?.updateConfiguration(configuration)
        demoAI?.updateConfiguration(configuration)
    }

    func restartRally(with configuration: SimulationConfiguration) {
        guard case .solo = mode, state.match.phase != .finished else { return }
        engine.updateConfiguration(configuration)
        ai?.updateConfiguration(configuration)
        demoAI?.updateConfiguration(configuration)
        engine.prepareNextRally(mirrored: false)
        state = engine.state
        scene.snapshot = state
        countdown = 3
        countdownAccumulator = 0
        accumulator = 0
        torque = 0
        thrust = false
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

        scene.snapshot = state
        scene.reduceMotion = UIAccessibility.isReduceMotionEnabled
    }

    private func simulateOneTick() {
        let tick = engine.state.tick
        let localTeam = online?.localTeam ?? .cyan
        var localInput = PlayerInput(tick: tick, torque: torque, thrust: thrust)
        if var demoAI {
            localInput = demoAI.input(for: engine.state, team: localTeam, tick: tick)
            self.demoAI = demoAI
        }
        var inputs: [Team: PlayerInput] = [localTeam: localInput]

        switch mode {
        case .solo:
            if var ai {
                inputs[.orange] = ai.input(for: engine.state, team: .orange, tick: tick)
                self.ai = ai
            }
            engine.step(inputs: inputs)
        case .online:
            guard let online else { return }
            if tick.isMultiple(of: 4) {
                online.sendInput(localInput)
            }
            inputs[localTeam.opponent] = online.remoteInput ?? .idle(tick: tick)
            engine.step(inputs: inputs)
            if online.isAuthoritative, tick.isMultiple(of: 6) {
                online.sendSnapshot(engine.state)
            }
        }

        state = engine.state
        events = engine.lastEvents
        let presentsLocalEvents = switch mode {
        case .solo: true
        case .online: online?.isAuthoritative == true
        }
        if presentsLocalEvents, !events.isEmpty { scene.present(events) }
        if presentsLocalEvents,
           let point = events.first(where: { if case .point = $0 { true } else { false } }) {
            lastPointText = point.label(
                bounceAllowance: engine.configuration.allowedFloorBounces
            )
            if case let .point(team, _) = point { FeedbackCenter.shared.point(team: team) }
        } else if presentsLocalEvents, events.contains(.rallyReset) {
            lastPointText = nil
        }
        for event in events where presentsLocalEvents {
            if case .collisionEffect = event { FeedbackCenter.shared.impact() }
            if case .matchEnded = event { FeedbackCenter.shared.win() }
            if case .online = mode, online?.isAuthoritative == true {
                if case .matchEnded = event {
                    online?.sendFullResync(engine.state)
                }
                online?.sendEvent(event)
                if case .matchEnded = event {
                    online?.finishCompletedMatch()
                }
            }
        }
    }

    private func installOnlineCallbacks() {
        guard let online else { return }
        online.onSnapshot = { [weak self] authoritative in
            guard let self, !online.isAuthoritative else { return }
            var resolved = authoritative
            if let localTeam = online.localTeam,
               let predicted = self.engine.state.ships[localTeam],
               let hostShip = authoritative.ships[localTeam] {
                resolved.ships[localTeam] = StateReconciler().reconcile(
                    predicted: predicted,
                    authoritative: hostShip
                )
            }
            self.engine = SimulationEngine(state: resolved)
            self.state = resolved
        }
        online.onResync = { [weak self] authoritative in
            guard let self else { return }
            self.engine = SimulationEngine(state: authoritative)
            self.state = authoritative
            self.isPaused = false
            self.countdown = 3
            self.countdownAccumulator = 0
        }
        online.onEvent = { [weak self] event in
            guard let self, !online.isAuthoritative else { return }
            self.events = [event]
            self.scene.present([event])
            switch event {
            case let .point(team, _):
                self.lastPointText = event.label(
                    bounceAllowance: self.engine.configuration.allowedFloorBounces
                )
                FeedbackCenter.shared.point(team: team)
            case .rallyReset:
                self.lastPointText = nil
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
private final class FrameDriver: NSObject {
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
