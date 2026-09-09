import ASTROSPIKECore
import Observation
import QuartzCore
import SwiftUI

/// The circuit's session: a fixed-step pump around `TrackEngine`, the same
/// shape as `GameSession` but with none of its match plumbing. There is no
/// online path here on purpose -- the track is a local time trial against one
/// pace car, and nothing it produces has ever crossed the wire.
@MainActor
@Observable
final class TrackSession {
    private(set) var state: TrackState
    private(set) var isPaused = false

    var torque = 0.0
    var thrust = false
    var brake = false

    let scene: TrackScene
    private var engine: TrackEngine
    private var frameDriver: FrameDriver?
    private var previousTimestamp: CFTimeInterval?
    private var accumulator = 0.0
    private var tick: UInt64 = 0

    init(track: TrackGeometry = .circuit, lapsToWin: Int = 3) {
        let engine = TrackEngine(track: track, lapsToWin: lapsToWin)
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
        engine = TrackEngine(track: engine.track, lapsToWin: state.lapsToWin)
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
            tractor: brake
        )
        engine.step(input: input)
        tick &+= 1
        state = engine.state
        let events = engine.lastEvents
        if !events.isEmpty {
            scene.present(events)
            announce(events)
        }
        // The engine note follows the throttle, not the button: a car sliding
        // through a penalty makes no noise, because it has no drive.
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
