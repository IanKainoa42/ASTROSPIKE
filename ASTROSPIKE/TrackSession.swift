import ASTROSPIKECore
import Observation
import QuartzCore
import SwiftUI

/// The circuit's session: a fixed-step pump around `TrackEngine`, the same
/// shape as `GameSession` but with none of its match plumbing. The ship it
/// flies is the match's ship, under the match's gravity and off the match's
/// tuning sliders -- what the circuit drops is the ball, the net, the teams
/// and the rulebook, not the flight model. There is still no online path
/// here: the race is a local run against one pace ship, and nothing it
/// produces has ever crossed the wire.
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
    /// The circuit's own sliders. Lane width and lap count live here and only
    /// here -- passing either alongside the snapshot would let the two
    /// disagree, and a slider that moves nothing is worse than no slider.
    private(set) var tuning: TrackTuningSnapshot
    private let hulls: [TrackSeat: Hull]

    init(
        flight: FlightTuningSnapshot = .defaults,
        tuning: TrackTuningSnapshot = .defaults,
        hulls: [TrackSeat: Hull] = [:]
    ) {
        self.flight = flight
        self.tuning = tuning
        self.hulls = hulls
        let engine = TrackEngine(
            track: tuning.track,
            configuration: TrackConfiguration(flight: flight, track: tuning),
            lapsToWin: tuning.laps
        )
        self.engine = engine
        state = engine.state
        scene = TrackScene(track: tuning.track, hulls: hulls)
        scene.snapshot = engine.state
    }

    var countdownSecondsRemaining: Double { engine.countdownSecondsRemaining }
    var lapsToWin: Int { state.lapsToWin }
    var isEndless: Bool { state.isEndless }
    /// Seconds of arcing left on the pilot's hull, for the badge that tells
    /// them why the ship is down on power.
    var damageSecondsRemaining: Double {
        Double(player?.damageTicksRemaining ?? 0) * engine.configuration.stepDuration
    }
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

    /// Takes the sliders and drops back onto the grid. Everything the race
    /// runs on is rebuilt from the snapshot, so a lane the pilot just widened
    /// is the lane they line up on and the lane the railing measures.
    func apply(_ tuning: TrackTuningSnapshot) {
        self.tuning = tuning
        restart()
    }

    func restart() {
        engine = TrackEngine(
            track: tuning.track,
            configuration: TrackConfiguration(flight: flight, track: tuning),
            lapsToWin: tuning.laps
        )
        state = engine.state
        scene.track = tuning.track
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
        // The thruster note follows the burn, not the button. A damaged ship
        // is still burning -- weakly -- so it still sounds like one: silence
        // while the pads answer would read as the audio breaking.
        let driving = thrust && state.phase == .racing
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
