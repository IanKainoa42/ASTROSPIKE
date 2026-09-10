import ASTROSPIKECore
import Observation
import QuartzCore
import SwiftUI

/// The circuit's session: a fixed-step pump around `TrackEngine`, the same
/// shape as `GameSession` but with none of its match plumbing. The ship it
/// flies is the match's ship, under the match's gravity and off the match's
/// tuning sliders -- what the circuit drops is the ball, the net, the teams
/// and the rulebook, not the flight model. There is still no online path
/// here: the race is a local three-lapper against one pace ship, and nothing
/// it produces has ever crossed the wire.
@MainActor
@Observable
final class TrackSession {
    private(set) var state: TrackState
    private(set) var isPaused = false

    var torque = 0.0
    var thrust = false
    /// The retro pad. A ship has no brake, so this burns out of the tail.
    var retro = false

    let scene: TrackScene
    private var engine: TrackEngine
    private var frameDriver: FrameDriver?
    private var previousTimestamp: CFTimeInterval?
    private var accumulator = 0.0
    private var tick: UInt64 = 0

    private let flight: FlightTuningSnapshot

    init(
        track: TrackGeometry = .circuit,
        flight: FlightTuningSnapshot = .defaults,
        lapsToWin: Int = 3
    ) {
        self.flight = flight
        let engine = TrackEngine(
            track: track,
            configuration: TrackConfiguration(flight: flight),
            lapsToWin: lapsToWin
        )
        self.engine = engine
        state = engine.state
        scene = TrackScene(track: track)
        scene.snapshot = engine.state
    }

    var countdownSecondsRemaining: Double { engine.countdownSecondsRemaining }
    var lapsToWin: Int { state.lapsToWin }
    var player: CarState? { state.cars[.player] }
    var rival: CarState? { state.cars[.rival] }

    func start() {
        guard frameDriver == nil else { return }
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
        SoundBank.shared.stopEverything()
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { SoundBank.shared.stopEverything() }
    }

    func resume() { isPaused = false }

    func restart() {
        engine = TrackEngine(
            track: engine.track,
            configuration: TrackConfiguration(flight: flight),
            lapsToWin: state.lapsToWin
        )
        state = engine.state
        scene.snapshot = engine.state
        accumulator = 0
        tick = 0
        isPaused = false
        SoundBank.shared.stopEverything()
    }

    func setApplicationActive(_ active: Bool) {
        if !active {
            isPaused = true
            SoundBank.shared.stopEverything()
        }
    }

    private func frame(timestamp: CFTimeInterval) {
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return
        }
        let elapsed = min(timestamp - previousTimestamp, 0.1)
        self.previousTimestamp = timestamp
        guard !isPaused else { return }

        accumulator += elapsed
        while accumulator >= engine.configuration.stepDuration {
            accumulator -= engine.configuration.stepDuration
            simulateOneTick()
        }
        scene.snapshot = state
    }

    private func simulateOneTick() {
        let input = PlayerInput(
            tick: tick,
            torque: max(-1, min(1, torque)),
            thrust: thrust,
            fire: false,
            tractor: retro
        )
        engine.step(input: input)
        tick &+= 1
        state = engine.state
        let events = engine.lastEvents
        if !events.isEmpty {
            scene.present(events)
            announce(events)
        }
        // The thruster note follows the burn, not the button: a ship sliding
        // through a penalty makes no noise, because its engine is out.
        let driving = thrust && state.phase == .racing && player?.isStunned == false
        if driving {
            SoundBank.shared.startLoop(
                .thrusterCyan,
                positionX: Float(player?.position.x ?? 0),
                volume: 0.5
            )
        } else {
            SoundBank.shared.stopLoop(.thrusterCyan)
        }
    }

    private func announce(_ events: [TrackEvent]) {
        for event in events {
            switch event {
            case let .railStrike(seat, position, _):
                FeedbackCenter.shared.crossedOffside(
                    team: seat == .player ? .cyan : .orange,
                    positionX: position.x
                )
            case .lapCompleted:
                FeedbackCenter.shared.tap()
            case let .raceFinished(winner):
                SoundBank.shared.stopEverything()
                if winner == .player {
                    FeedbackCenter.shared.win()
                } else {
                    FeedbackCenter.shared.impact()
                }
            }
        }
    }
}
