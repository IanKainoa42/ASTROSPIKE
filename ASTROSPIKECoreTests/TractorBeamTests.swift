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
        // A ball 35 degrees off the nose is outside the cone; 25 is inside.
        #expect(cos(35 * .pi / 180) < SimulationEngine.tractorCone)
        #expect(cos(25 * .pi / 180) > SimulationEngine.tractorCone)
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
}
