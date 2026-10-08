import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

@Suite("Tractor beam")
struct TractorBeamTests {
    private func playing() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        return engine
    }

    @Test("A held beam draws a ball ahead of the nose toward the ship without a touch")
    func beamPullsBallIn() {
        var engine = playing()
        let ship = engine.state.ships[.cyan]!
        // Straight ahead of the nose (which points up), inside range.
        engine.state.ball.position = ship.position + .init(0, 0.3)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        let gravityOnly = engine.configuration.gravity.y * engine.configuration.ballGravityMultiplier
            * engine.configuration.stepDuration
        #expect(engine.state.ships[.cyan]!.tractorActive)
        #expect(engine.state.ball.velocity.y < gravityOnly, "the beam adds pull on top of gravity")
        #expect(engine.state.match.shipTouches[.cyan] == 0, "reeling in is not a touch")
    }

    @Test("A ball behind the ship or out of range is left alone")
    func beamHasConeAndRange() {
        var engine = playing()
        let ship = engine.state.ships[.cyan]!
        let gravityOnly = engine.configuration.gravity.y * engine.configuration.ballGravityMultiplier
            * engine.configuration.stepDuration
        // Level with the ship, off to the side: outside the cone.
        engine.state.ball.position = ship.position - .init(0.2, 0)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        #expect(engine.state.ball.velocity.y == gravityOnly)
        engine.state.ball.position = ship.position + .init(0, engine.configuration.tractorRange + 0.05)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 1, torque: 0, thrust: false, tractor: true)])
        #expect(engine.state.ball.velocity.y == gravityOnly)
    }

    @Test("The beam works anywhere, including deep in the opponent's half")
    func beamWorksAnywhere() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(0.6, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        #expect(engine.state.ships[.cyan]!.tractorActive)
    }

    @Test("The cannon stays holstered deep in the opponent's half")
    func cannonStillHolstered() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(0.6, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.isEmpty)
    }

    @Test("The drawn cone is the cone that grabs")
    func coneIsNarrowAndLong() {
        let engine = playing()
        // A ball 26 degrees off the nose is outside the cone; 20 is inside.
        #expect(cos(26 * .pi / 180) < SimulationEngine.tractorCone)
        #expect(cos(20 * .pi / 180) > SimulationEngine.tractorCone)
        #expect(engine.configuration.tractorRange > 0.7, "the beam is a long reach")
    }

    /// Zero gravity is the only way to see the beam on its own: gravity is an
    /// outside force and would swamp the very thing under test.
    private func weightless() -> SimulationEngine {
        var engine = playing()
        var configuration = engine.configuration
        configuration.gravity = .zero
        engine.updateConfiguration(configuration)
        return engine
    }

    private func momentum(_ engine: SimulationEngine) -> SIMD2<Double> {
        var total = engine.state.ball.velocity * SimulationEngine.ballMass
        for seat in Seat.allCases {
            total += (engine.state.ships[seat]?.velocity ?? .zero) * SimulationEngine.shipMass
        }
        return total
    }

    @Test("Reeling the ball in drags the hull toward it, and the pair's momentum is unchanged")
    func beamConservesMomentum() {
        var engine = weightless()
        let ship = engine.state.ships[.cyan]!
        engine.state.ball.position = ship.position + .init(0, 0.3)
        engine.state.ball.velocity = .init(0.12, -0.2)
        let before = momentum(engine)
        for tick in 0 ..< 20 {
            engine.step(inputs: [.cyan: PlayerInput(
                tick: UInt64(tick), torque: 0, thrust: false, tractor: true
            )])
        }
        let drift = simd_length(momentum(engine) - before)
        #expect(drift < 1e-9, "the beam invented \(drift) of momentum")
        #expect(engine.state.ships[.cyan]!.velocity.y > 0, "the hull is pulled up toward the ball")
        #expect(engine.state.ball.velocity.y < -0.2, "the ball is still pulled down toward the hull")
    }

    @Test("The grab damps the ball against the ship's frame, not the world's")
    func grabDampsAgainstTheShipNotTheWorld() {
        var engine = weightless()
        let ship = engine.state.ships[.cyan]!
        // Hull and ball drifting sideways together, so there is nothing
        // between them for the grab to bleed off. Damping against the world
        // would drag the ball's 0.5 down to about 0.36 over these 30 steps
        // and leave the hull at 0.5; damping against the hull keeps the pair
        // flying as one. Not exact to the last bit -- the hull's position is
        // integrated a half step before the beam reads it, so the beam axis
        // leans a hair off true and leaks a little sideways pull.
        engine.state.ships[.cyan]!.velocity = .init(0.5, 0)
        engine.state.ball.position = ship.position + .init(0, 0.3)
        engine.state.ball.velocity = .init(0.5, 0)
        for tick in 0 ..< 30 {
            engine.step(inputs: [.cyan: PlayerInput(
                tick: UInt64(tick), torque: 0, thrust: false, tractor: true
            )])
        }
        let ballDrift = engine.state.ball.velocity.x
        let hullDrift = engine.state.ships[.cyan]!.velocity.x
        #expect(engine.configuration.tractorDrag > 0, "the damping under test is switched on")
        #expect(ballDrift > 0.49, "the ball keeps station with the hull, not with the world")
        #expect(abs(ballDrift - hullDrift) < 0.01, "hull and ball still fly as one")
    }

    @Test("S and the down arrow hold the beam; a snapshot with it on still fits an unreliable packet")
    func keysAndWireSize() throws {
        #expect(KeyboardControlMapping.action(forKeyCode: 22) == .tractor)
        #expect(KeyboardControlMapping.action(forKeyCode: 81) == .tractor)
        var engine = playing()
        engine.state.ships[.cyan]!.tractorActive = true
        let data = try WireCodec().encode(WireEnvelope(sequence: 1, payload: .snapshot(engine.state)))
        #expect(data.count < 1000, "singles snapshot is \\(data.count) bytes")
    }

    // MARK: Beam lock

    /// Weightless, with the beam set to lock after `seconds`, the hull
    /// clear of every wall and the ball straight off its nose.
    private func lockable(after seconds: Double) -> SimulationEngine {
        var engine = weightless()
        var configuration = engine.configuration
        configuration.beamLockTime = seconds
        engine.updateConfiguration(configuration)
        engine.state.ships[.cyan]!.position = .init(-0.5, 0)
        engine.state.ball.position = .init(-0.5, 0.25)
        engine.state.ball.velocity = .zero
        return engine
    }

    private func hold(_ engine: inout SimulationEngine, tractor: Bool = true) {
        engine.step(inputs: [.cyan: PlayerInput(tick: engine.state.tick, torque: 0, thrust: false, tractor: tractor)])
    }

    /// Angular momentum of hull and ball about their shared centre of mass,
    /// the hull's own turn included.
    private func spinMomentum(_ engine: SimulationEngine) -> Double {
        let ship = engine.state.ships[.cyan]!
        let ball = engine.state.ball
        let ms = SimulationEngine.shipMass
        let mb = SimulationEngine.ballMass
        let centre = (ship.position * ms + ball.position * mb) / (ms + mb)
        let drift = (ship.velocity * ms + ball.velocity * mb) / (ms + mb)
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
        let reach = ShipHitbox.shared.reach
        let own = SimulationEngine.lockedHullInertia * ms * reach * reach * (ball.beamLock?.spin ?? 0)
        return ms * cross(ship.position - centre, ship.velocity - drift)
            + mb * cross(ball.position - centre, ball.velocity - drift) + own
    }

    private func pairMomentum(_ engine: SimulationEngine) -> SIMD2<Double> {
        engine.state.ball.velocity * SimulationEngine.ballMass
            + engine.state.ships[.cyan]!.velocity * SimulationEngine.shipMass
    }

    @Test("A beam held long enough locks the ball on: the pair turns as one body, momentum and angular momentum kept")
    func heldBeamLocksAndSpins() throws {
        var engine = lockable(after: 0.3)
        var steps = 0
        while engine.state.ball.beamLock == nil, steps < 120 {
            hold(&engine)
            steps += 1
        }
        let lock = try #require(engine.state.ball.beamLock, "the beam never locked on")
        #expect(lock.seat == .cyan)
        #expect(Double(steps) * engine.configuration.stepDuration >= 0.3 - 1e-9, "locked before the hold time")
        // Flick the ball sideways: the weld has to turn that into a spin.
        engine.state.ball.velocity += .init(0.6, 0)
        let angularBefore = spinMomentum(engine)
        let linearBefore = pairMomentum(engine)
        let angleBefore = engine.state.ships[.cyan]!.angle
        for _ in 0 ..< 45 { hold(&engine) }
        let ship = engine.state.ships[.cyan]!
        let ball = engine.state.ball
        let held = try #require(ball.beamLock, "the lock let go with the beam still held")
        #expect(abs(simd_length(ball.position - ship.position) - lock.length) < 1e-9, "the distance is locked")
        #expect(abs(spinMomentum(engine) - angularBefore) < 1e-9, "angular momentum drifted")
        #expect(simd_length(pairMomentum(engine) - linearBefore) < 1e-9, "linear momentum drifted")
        #expect(abs(ship.angle - angleBefore) > 0.3, "the pair barely turned")
        let line = ball.position - ship.position
        #expect(abs(remainder(atan2(line.y, line.x) - ship.angle - held.bearing, 2 * .pi)) < 1e-9, "the nose stays on the ball")
    }

    @Test("Let go before the lock and the ball flies on in to a headbutt")
    func earlyReleaseNeverLocks() {
        var engine = lockable(after: 0.7)
        for _ in 0 ..< 30 { hold(&engine) } // half a second
        #expect(engine.state.ball.beamLock == nil)
        let contact = ShipHitbox.shared.noseReach + engine.state.ball.radius + 0.01
        var touched = false
        for _ in 0 ..< 240 where !touched {
            hold(&engine, tractor: false)
            #expect(engine.state.ball.beamLock == nil)
            touched = simd_length(engine.state.ball.position - engine.state.ships[.cyan]!.position) < contact
        }
        #expect(touched, "the ball never reached the hull")
    }

    @Test("Letting go drops the lock; the ball flies off along the spin and the hull keeps turning")
    func releaseFlingsTheBall() throws {
        var engine = lockable(after: 0.3)
        for _ in 0 ..< 120 where engine.state.ball.beamLock == nil { hold(&engine) }
        engine.state.ball.velocity += .init(0.6, 0)
        for _ in 0 ..< 10 { hold(&engine) }
        let lock = try #require(engine.state.ball.beamLock)
        let flung = engine.state.ball.velocity
        hold(&engine, tractor: false)
        #expect(engine.state.ball.beamLock == nil)
        #expect(simd_length(engine.state.ball.velocity - flung) < 1e-9, "the ball keeps the speed the spin gave it")
        #expect(engine.state.ships[.cyan]!.knockSpin == lock.spin, "the hull's spin carries on and winds down")
    }

    @Test("The shipped match rules lock the beam on; a bare configuration never does")
    func lockIsAMatchRule() {
        #expect(SimulationConfiguration().beamLockTime == 0)
        #expect(FlightTuningSnapshot.defaults.configuration.beamLockTime == FlightTuningSnapshot.defaults.beamLock)
        #expect(FlightTuningSnapshot.beamLockRange.contains(FlightTuningSnapshot.defaults.beamLock))
    }
}
