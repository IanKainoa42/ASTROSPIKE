import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

@Suite("Saber")
struct SaberTests {
    private func engine(astroball: Bool = true) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        if astroball {
            engine.updateConfiguration(.astroball(from: engine.configuration, tuning: AstroballTuning()))
        }
        engine.updateArena(.astroball(doubles: false))
        engine.beginPlay()
        // Park the cyan hull mid-air, nose level, blade out, the orange hull
        // and the ball far off.
        engine.state.ships[.cyan]!.position = .init(-0.55, 0.15)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angle = 0
        engine.state.ships[.orange]!.position = .init(0.8, 0.5)
        engine.state.ball = BallState(position: .init(0.5, -0.3), velocity: .zero)
        if astroball { engine.state.ships[.cyan]!.saber.drawn = 1 }
        return engine
    }

    private func held(_ tick: UInt64, flick: SaberFlick? = nil, count: UInt8 = 0, tractor: Bool = false) -> PlayerInput {
        PlayerInput(tick: tick, torque: 0, thrust: false, tractor: tractor, saber: true, saberFlick: flick, saberFlickCount: count)
    }

    /// Steps `ticks` with the blade out and the flick sent from the first
    /// of them; the ship is held still against gravity until the ball is
    /// played, so only the move turns it. Returns the ball's velocity the
    /// step it was played.
    @discardableResult
    private func fly(_ engine: inout SimulationEngine, flick: SaberFlick? = nil, ticks: Int) -> SIMD2<Double>? {
        var tick: UInt64 = 0
        var played: SIMD2<Double>?
        for _ in 0 ..< ticks {
            engine.step(inputs: [.cyan: held(tick, flick: flick, count: flick == nil ? 0 : 1)])
            tick += 1
            if played == nil, engine.state.ball.lastPlay?.seat == .cyan { played = engine.state.ball.velocity }
            if played == nil { engine.state.ships[.cyan]!.velocity = .zero }
        }
        return played
    }

    private func ticks(_ seconds: Double, _ engine: SimulationEngine) -> Int {
        Int((seconds / engine.configuration.stepDuration).rounded(.up)) + 2
    }

    private var blade: (base: Double, length: Double) {
        (ShipHitbox.shared.noseReach, Saber.length)
    }

    @Test("A spin is a full turn each way and lands the nose where it began")
    func spinReturns() {
        for (flick, sign) in [(SaberFlick.left, 1.0), (.right, -1.0)] {
            var engine = engine()
            engine.state.ships[.cyan]!.angle = 0.3
            var turnedMost = 0.0
            var tick: UInt64 = 0
            engine.step(inputs: [.cyan: held(tick)]); tick += 1
            for _ in 0 ..< ticks(Saber.spinDuration, engine) {
                engine.step(inputs: [.cyan: held(tick, flick: flick, count: 1)]); tick += 1
                turnedMost = max(turnedMost, abs(engine.state.ships[.cyan]!.angle - 0.3))
            }
            let ship = engine.state.ships[.cyan]!
            #expect(abs(ship.angle - (0.3 + sign * 2 * .pi)) < 1e-9, "\(flick)")
            #expect(ship.angularVelocity == 0)
            #expect(ship.saber.move == nil)
            #expect(turnedMost > 6)
        }
    }

    @Test("One flick is one move: a repeated count, a dropped input or a flick mid-move starts nothing")
    func flickIsEdgeTriggered() {
        var engine = engine()
        var tick: UInt64 = 0
        func send(_ input: PlayerInput) { engine.step(inputs: [.cyan: input]); tick += 1 }
        let spin = ticks(Saber.spinDuration, engine)
        for _ in 0 ..< spin { send(held(tick, flick: .left, count: 1)) }
        let afterOne = engine.state.ships[.cyan]!.angle
        #expect(abs(afterOne - 2 * .pi) < 1e-9)
        // The same count keeps arriving: no second spin.
        for _ in 0 ..< spin { send(held(tick, flick: .left, count: 1)) }
        #expect(engine.state.ships[.cyan]!.angle == afterOne)
        // A dropped tick (idle) then the same count again: still nothing.
        send(.idle(tick: tick))
        send(held(tick, flick: .left, count: 1))
        #expect(engine.state.ships[.cyan]!.saber.move == nil)
        // A new flick during a move is dropped, not queued.
        send(held(tick, flick: .left, count: 2))
        send(held(tick, flick: .right, count: 3))
        for _ in 0 ..< spin * 2 { send(held(tick, flick: .right, count: 3)) }
        #expect(abs(engine.state.ships[.cyan]!.angle - (afterOne + 2 * .pi)) < 1e-6)
    }

    @Test("The ball leaves along the angle the blade met it at, and slow off a still blade")
    func normalDecidesDirection() {
        for tilt in [0.0, 0.5, -0.5] {
            var engine = engine()
            engine.state.ships[.cyan]!.angle = tilt
            let ship = engine.state.ships[.cyan]!
            let axis = SIMD2(cos(tilt), sin(tilt))
            let side = SIMD2(-sin(tilt), cos(tilt))
            let r = engine.state.ball.radius
            let point = ship.position + axis * (blade.base + blade.length * 0.75)
            engine.state.ball = BallState(position: point + side * (r + 0.04), velocity: .init(0, -1))
            let played = fly(&engine, ticks: 30)
            #expect(played != nil, "tilt \(tilt)")
            guard let v = played else { continue }
            #expect(engine.state.ball.lastPlay?.seat == .cyan)
            if tilt == 0 { #expect(abs(v.x) < 0.05) }
            if tilt > 0 { #expect(v.x < -0.2, "tilt \(tilt) v \(v)") }
            if tilt < 0 { #expect(v.x > 0.2, "tilt \(tilt) v \(v)") }
            // A dead bat: well under the 1 it came in at.
            #expect(simd_length(v) < 0.9)
        }
    }

    @Test("The spike chops down: a ball beside the blade leaves going down, a dink pokes it soft")
    func spikeAndDink() {
        func exit(_ flick: SaberFlick, ballAt place: (SimulationEngine) -> SIMD2<Double>) -> SIMD2<Double>? {
            var engine = engine()
            engine.state.ball = BallState(position: place(engine), velocity: .zero)
            return fly(&engine, flick: flick, ticks: ticks(0.4, engine))
        }
        let spike = exit(.down) { engine in
            let ship = engine.state.ships[.cyan]!
            let angle = -0.9
            return ship.position + SIMD2(cos(angle), sin(angle)) * (blade.base + blade.length * 0.7)
        }
        let dink = exit(.up) { engine in
            let ship = engine.state.ships[.cyan]!
            return ship.position + SIMD2(blade.base + blade.length * 0.8 + engine.state.ball.radius + 0.01, 0)
        }
        #expect(spike != nil && dink != nil)
        guard let spike, let dink else { return }
        #expect(spike.y < -1, "spike \(spike)")
        #expect(dink.x > 0.5, "dink \(dink)")
        #expect(simd_length(dink) * 2 < simd_length(spike), "dink \(dink) spike \(spike)")
    }

    @Test("A blade hit is a touch and shares the hull's debounce")
    func bladeIsATouch() {
        var engine = engine()
        let ship = engine.state.ships[.cyan]!
        let point = ship.position + SIMD2(blade.base + blade.length * 0.75, 0)
        engine.state.ball = BallState(position: point + SIMD2(0, engine.state.ball.radius + 0.03), velocity: .init(0, -1))
        fly(&engine, ticks: 4)
        #expect(engine.state.match.shipTouches.cyan == 1)
        #expect(engine.state.match.lastTouch == .cyan)
        // Straight back onto the blade inside the debounce: a hit, but no
        // second touch.
        let now = engine.state.ships[.cyan]!
        #expect(now.ballTouchCooldownTicks > 0)
        let again = now.position + SIMD2(cos(now.angle), sin(now.angle)) * (blade.base + blade.length * 0.75)
        engine.state.ball.position = again + SIMD2(0, engine.state.ball.radius + 0.005)
        engine.state.ball.velocity = .init(0, -1)
        engine.step(inputs: [.cyan: held(999)])
        #expect(engine.state.ball.velocity.y > 0, "the ball missed the blade")
        #expect(engine.state.match.shipTouches.cyan == 1)
        #expect(engine.state.match.lastTouchRun == 1)
    }

    @Test("The blade hits the ball in a duel and in the warm-up bay, not just ASTROBALL", arguments: [false, true])
    func hitsOutsideAstroball(warmup: Bool) {
        var engine = SimulationEngine.testing()
        if warmup { engine.updateConfiguration(.warmup(from: engine.configuration)) }
        engine.beginPlay()
        #expect(engine.state.match.phase == .playing)
        let at = SIMD2(-0.5, 0.2)
        engine.state.ships[.cyan]!.position = at
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angle = 0
        engine.state.ships[.orange]!.position = .init(0.8, 0.5)
        // The ball drops onto the middle of the blade, clear of the hull.
        let radius = engine.state.ball.radius
        engine.state.ball = BallState(
            position: at + SIMD2(blade.base + blade.length * 0.6, radius + Saber.radius + 0.01),
            velocity: .init(0, -1)
        )
        for tick in 0 ..< 12 {
            engine.step(inputs: [.cyan: held(UInt64(tick))])
            engine.state.ships[.cyan]!.velocity = .zero
        }
        #expect(engine.state.ball.velocity.y > 0, "the ball fell through the blade")
    }

    @Test("A fresh press after a flick only draws the blade: the old flick is not replayed")
    func pressAfterFlickDoesNotSpin() {
        var engine = engine()
        engine.state.ships[.cyan]!.saber = SaberState()
        var tick: UInt64 = 0
        engine.step(inputs: [.cyan: held(tick)]); tick += 1
        engine.step(inputs: [.cyan: held(tick, flick: .left, count: 1)]); tick += 1
        #expect(engine.state.ships[.cyan]!.saber.move == .spinLeft)
        // Let go until the blade is sheathed and the move is over.
        for _ in 0 ..< ticks(Saber.spinDuration + Saber.drawTime, engine) {
            engine.step(inputs: [.cyan: PlayerInput(tick: tick, torque: 0, thrust: false, saberFlick: .left, saberFlickCount: 1)])
            tick += 1
        }
        #expect(!engine.state.ships[.cyan]!.saber.isOut)
        // Press again, twice: the input still carries the last flick and its count.
        for _ in 0 ..< 2 {
            for _ in 0 ..< 5 {
                engine.step(inputs: [.cyan: held(tick, flick: .left, count: 1)])
                tick += 1
                #expect(engine.state.ships[.cyan]!.saber.isOut)
                #expect(engine.state.ships[.cyan]!.saber.move == nil, "a plain press spun the hull")
            }
            for _ in 0 ..< ticks(Saber.drawTime, engine) {
                engine.step(inputs: [.cyan: PlayerInput(tick: tick, torque: 0, thrust: false, saberFlick: .left, saberFlickCount: 1)])
                tick += 1
            }
        }
    }

    @Test("The saber flies in a duel too; the blade drops the beam; a stun drops the move")
    func limits() {
        var duel = engine(astroball: false)
        duel.step(inputs: [.cyan: held(0)])
        #expect(duel.state.ships[.cyan]!.saber.isOut)

        var engine = engine()
        engine.step(inputs: [.cyan: held(0, tractor: true)])
        #expect(engine.state.ships[.cyan]!.saber.isOut)
        #expect(!engine.state.ships[.cyan]!.tractorActive)

        engine.step(inputs: [.cyan: held(1, flick: .left, count: 1)])
        #expect(engine.state.ships[.cyan]!.saber.move == .spinLeft)
        engine.state.ships[.cyan]!.stunTicks = 10
        engine.step(inputs: [.cyan: held(2, flick: .left, count: 1)])
        #expect(engine.state.ships[.cyan]!.saber.move == nil)
    }
}
