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

    @Test("The beam is holstered deep in the opponent's half")
    func beamOnlyFromOwnHalf() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(0.6, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        #expect(!engine.state.ships[.cyan]!.tractorActive)
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
