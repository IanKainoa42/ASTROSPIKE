import Foundation
import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Ship hitbox")
struct ShipHitboxTests {
    private let s = ShipHitbox.worldPerOutlineUnit

    @Test("The shared hitbox is the Lancet at its drawn size, plus a thin skin")
    func sharedIsTheDrawnLancet() {
        #expect(abs(ShipHitbox.shared.noseReach - (30 * s + ShipHitbox.skin)) < 1e-12)
        #expect(ShipHitbox.skin < BallState.nominalRadius / 2)
        #expect(ShipHitbox.shared == ShipHitbox(Hull.lancet.spec.outline))
    }

    @Test("A point coming straight at the nose stops one radius short of the tip")
    func noseOnSweep() throws {
        let hitbox = ShipHitbox.shared
        let radius = 0.04
        let t = try #require(hitbox.sweepTime(from: SIMD2(0.3, 0), to: SIMD2(0, 0), radius: radius))
        let reached = 0.3 * (1 - t)
        #expect(abs(reached - (30 * s + radius)) < 1e-9)
    }

    @Test("Each hull's own shape meets the ball where that hull is drawn")
    func perHullShapesDiffer() throws {
        // Coming down the ship's axis, a little to one side: the Anvil's flat
        // nose is out at 26 units there, the Lancet's needle has already
        // tapered back to its body.
        let lateral = -6 * s
        let radius = 0.001
        let start = SIMD2(0.2, lateral), end = SIMD2(-0.2, lateral)
        let lancet = try #require(ShipHitbox(Hull.lancet.spec.outline).sweepTime(from: start, to: end, radius: radius))
        let anvil = try #require(ShipHitbox(Hull.anvil.spec.outline).sweepTime(from: start, to: end, radius: radius))
        #expect(anvil < lancet)
        let anvilFront = 0.2 - 0.4 * anvil
        #expect(abs(anvilFront - (26 * s + radius)) < 1e-9)
    }

    @Test("Starting inside or already touching is not a new hit")
    func startInsideIsIgnored() {
        #expect(ShipHitbox.shared.sweepTime(from: .zero, to: SIMD2(0.2, 0), radius: 0.01) == nil)
    }

    private func dropBall(lateral: Double, hitboxes: [Seat: ShipHitbox] = [:]) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.shipHitboxes = hitboxes
        let ship = SIMD2(-0.45, -0.1)
        engine.state.ships[.cyan]!.position = ship
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angle = .pi / 2
        let radius = engine.state.ball.radius
        engine.state.ball.position = ship + SIMD2(lateral, 30 * s + radius + 0.03)
        engine.state.ball.velocity = SIMD2(0, -1.2)
        engine.state.ball.spin = 0
        for tick in 0 ..< 20 {
            engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        return engine
    }

    @Test("A ball dropped on the nose bounces off the drawn nose")
    func ballBouncesOffDrawnNose() {
        let engine = dropBall(lateral: 0)
        #expect(engine.state.ball.velocity.y > 0)
    }

    @Test("A ball passing just outside the drawn wingtip is not touched")
    func ballMissesPastWingtip() {
        // The wingtip is 21 units out. The old centre fixture reached 0.041,
        // well past it, and this ball would have bounced off empty space.
        let radius = SimulationEngine.testing().state.ball.radius
        let engine = dropBall(lateral: 21 * s + ShipHitbox.skin + radius + 0.004)
        #expect(engine.state.ball.velocity.y < 0)
    }

    @Test("With per-hull hitboxes a blunt nose stops the ball higher than a needle")
    func perHullHitboxesReachTheEngine() {
        func stoppedAt(_ hull: Hull) -> Double {
            var engine = SimulationEngine.testing()
            engine.shipHitboxes[.cyan] = ShipHitbox(hull.spec.outline)
            let ship = SIMD2(-0.45, -0.1)
            engine.state.ships[.cyan]!.position = ship
            engine.state.ships[.cyan]!.velocity = .zero
            engine.state.ships[.cyan]!.angle = .pi / 2
            // A small ball, well off the axis: it clears the Lancet's needle
            // and meets its swept wing, but lands on the Anvil's broad nose.
            engine.state.ball.radius = 0.005
            engine.state.ball.position = ship + SIMD2(20 * s, 0.12)
            engine.state.ball.velocity = SIMD2(0, -1.2)
            engine.state.ball.spin = 0
            for tick in 0 ..< 30 {
                let before = engine.state.ball.velocity
                engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
                // Out here the Lancet's wing is steep, so the ball glances
                // sideways rather than bouncing up: take the first step that
                // knocks it (gravity alone changes it by ~0.016 a step).
                if simd_length(engine.state.ball.velocity - before) > 0.1 {
                    return engine.state.ball.position.y - engine.state.ships[.cyan]!.position.y
                }
            }
            return -.infinity
        }
        let anvil = stoppedAt(.anvil), lancet = stoppedAt(.lancet)
        #expect(lancet > -.infinity, "the ball never reached the Lancet")
        #expect(anvil > lancet + 10 * s)
    }

    @Test("A ship settles on the floor on its drawn tail")
    func shipRestsOnItsTail() {
        var engine = SimulationEngine.testing()
        engine.state.ball.position = SIMD2(0.5, 0.3)
        engine.state.ships[.cyan]!.position = SIMD2(-0.45, engine.arena.floorY + 0.1)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angle = .pi / 2
        for tick in 0 ..< 120 {
            engine.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        let ship = engine.state.ships[.cyan]!
        // The Lancet's tail fins are 19 units behind its centre.
        let height = ship.position.y - engine.arena.floorY
        #expect(abs(height - ShipHitbox.shared.extent(along: SIMD2(0, -1), angle: ship.angle)) < 1e-9)
        #expect(height < 0.03)
    }

    @Test("Two ships only bump where their drawn hulls meet")
    func shipsBumpAtTheirArt() {
        // One step closes 0.005, so `gap` is where the centres would end up.
        func bumped(gap: Double) -> Bool {
            var engine = SimulationEngine.testing()
            engine.state.ball.position = SIMD2(0.5, 0.3)
            engine.state.ships[.cyan] = ShipState(position: SIMD2(-0.2, 0), velocity: SIMD2(0.3, 0), angle: .pi / 2)
            engine.state.ships[.orange] = ShipState(position: SIMD2(-0.2 + gap + 0.005, 0), velocity: SIMD2(-0.3, 0), angle: .pi / 2)
            engine.step(inputs: [:])
            return engine.state.ships[.cyan]!.velocity.x < 0.2
        }
        let touching = 2 * ShipHitbox.shared.reach
        #expect(!bumped(gap: touching + 0.004))
        #expect(bumped(gap: touching - 0.004))
    }
}
