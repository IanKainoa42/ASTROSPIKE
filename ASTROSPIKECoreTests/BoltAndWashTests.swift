import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Bolts and exhaust wash")
struct BoltAndWashTests {
    private func playing() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        return engine
    }

    @Test("Firing spawns one bolt from the nose and starts the cooldown")
    func fireSpawnsBoltAndCooldown() {
        var engine = playing()
        engine.state.ball.position = .init(0.5, 0.3)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.count == 1)
        #expect(engine.state.bolts.first?.owner == .cyan)
        #expect(engine.state.ships[.cyan]!.fireCooldownTicks > 0)
        // Ahead of the ship along its nose, which points up.
        #expect(engine.state.bolts.first!.position.y > engine.state.ships[.cyan]!.position.y)
        #expect(engine.state.bolts.first!.velocity.y > 2)
    }

    @Test("A held trigger auto-repeats only once the cooldown has elapsed")
    func heldTriggerRepeatsAtCooldown() {
        var engine = playing()
        engine.state.ball.position = .init(0.5, 0.3)
        for tick in 0 ..< 20 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: true)])
        }
        #expect(engine.state.nextBoltID == 1)
        for tick in 20 ..< 70 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: true)])
        }
        #expect(engine.state.nextBoltID == 2)
    }

    @Test("A bolt that reaches the ball knocks it along the nose and counts as a touch")
    func boltPunchesBallAndCountsTouch() {
        var engine = playing()
        engine.state.ball.position = .init(-0.55, -0.25)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        var hit = false
        for tick in 1 ..< 12 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: false)])
            if engine.state.match.shipTouches[.cyan] == 1 { hit = true; break }
        }
        #expect(hit, "the bolt never reached the ball")
        #expect(engine.state.ball.velocity.y > 0.9)
        #expect(engine.state.bolts.isEmpty, "a spent bolt is removed")
    }

    @Test("A bolt crosses the centre line and can hit a ball on the far half")
    func boltCrossesCentreLine() {
        var engine = playing()
        engine.state.ball.position = .init(0.4, 0)
        engine.state.ball.velocity = .zero
        engine.state.ships[.cyan]!.position = .init(-0.1, 0)
        engine.state.ships[.cyan]!.angle = 0 // nose toward +x
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.count == 1)
        var hit = false
        for tick in 1 ..< 60 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: false)])
            if engine.state.match.shipTouches[.cyan] == 1 { hit = true; break }
        }
        #expect(hit, "the bolt fizzled before the far half")
        #expect(engine.state.ball.velocity.x > 0.9)
    }

    /// One bolt flown at a resting ball on a line `offset` above the ball's
    /// centre, travelling +x for `side` 1 and -x for -1, run up to the tick it
    /// lands -- alongside the same ball left alone. Stopping on the hit keeps
    /// the spin it sets from turning the ball before anything is measured.
    private func boltHit(side: Double, offset: Double) -> (struck: SimulationEngine, alone: SimulationEngine) {
        func court() -> SimulationEngine {
            var engine = playing()
            engine.state.ships[.cyan]!.position = .init(-0.8, -0.5)
            engine.state.ships[.orange]!.position = .init(0.8, -0.5)
            engine.state.ball = BallState(position: .init(-side * 0.4, 0.05))
            return engine
        }
        var struck = court()
        var alone = court()
        let travel = SIMD2(side, 0.0)
        let reach = struck.state.ball.radius + BoltState.radius
        struck.state.bolts = [BoltState(
            id: 99,
            owner: .cyan,
            position: struck.state.ball.position - travel * (reach + 0.01) + SIMD2(0, offset),
            velocity: travel * struck.configuration.boltSpeed,
            ticksRemaining: 60
        )]
        for _ in 0 ..< 6 {
            struck.step(inputs: [:])
            alone.step(inputs: [:])
            if struck.state.bolts.isEmpty { break }
        }
        return (struck, alone)
    }

    /// What that bolt did to the ball's velocity. Measured against the ball
    /// left alone, so gravity cancels.
    private func boltImpulse(side: Double, offset: Double) -> SIMD2<Double> {
        let hit = boltHit(side: side, offset: offset)
        return hit.struck.state.ball.velocity - hit.alone.state.ball.velocity
    }

    @Test("A bolt that clips the ball off its centre glances it off the line")
    func offCentreBoltGlancesTheBall() {
        let punch = SimulationConfiguration().boltPunch
        let reach = BallState.nominalRadius + BoltState.radius
        for side in [1.0, -1.0] {
            // Dead centre is the plain punch straight down the bolt's line. The
            // ball drops a hair while the bolt closes, hence the tolerance.
            let centre = boltImpulse(side: side, offset: 0)
            #expect(abs(centre.x - side * punch) < 0.001)
            #expect(abs(centre.y) < 0.01)
            // Under the centre lifts it, over the centre drives it down, and
            // the nearer the edge the harder it turns.
            let under = boltImpulse(side: side, offset: -reach * 0.6)
            let over = boltImpulse(side: side, offset: reach * 0.6)
            let edge = boltImpulse(side: side, offset: -reach * 0.95)
            #expect(under.y > 0.2)
            #expect(over.y < -0.2)
            #expect(edge.y > under.y)
            // Always the full punch, always onward, never past 45 degrees.
            for hit in [under, over, edge] {
                #expect(abs(simd_length(hit) - punch) < 1e-9)
                #expect(hit.x * side >= abs(hit.y))
            }
        }
    }

    @Test("An off-centre bolt sets the ball spinning, harder nearer the edge")
    func offCentreBoltSpinsTheBall() {
        let reach = BallState.nominalRadius + BoltState.radius
        for side in [1.0, -1.0] {
            // Dead centre there is nothing to drag round. The ball drops a
            // hair while the bolt closes, hence the tolerance.
            #expect(abs(boltHit(side: side, offset: 0).struck.state.ball.spin) < 0.5)
            // Underneath is backspin -- counter-clockwise on a ball driven
            // right, clockwise on one driven left -- and over the top is the
            // reverse.
            let under = boltHit(side: side, offset: -reach * 0.6).struck.state.ball.spin
            let over = boltHit(side: side, offset: reach * 0.6).struck.state.ball.spin
            let edge = boltHit(side: side, offset: -reach * 0.95).struck.state.ball.spin
            #expect(under * side > 1)
            #expect(over * side < -1)
            #expect(abs(edge) > abs(under))
            #expect(abs(edge) <= BoltState.spinKick)
        }
        // A bolt that misses leaves the ball as still as it was.
        #expect(boltHit(side: 1, offset: BallState.nominalRadius + 0.010).struck.state.ball.spin == 0)
    }

    @Test("Spin turns the ball's path without speeding it up or slowing it down")
    func spinOnlyTurnsTheVelocity() {
        let velocity = SIMD2(1.3, 0.4)
        let dt = SimulationConfiguration().stepDuration
        let back = BallState.curved(velocity, spin: 20, over: dt)
        let top = BallState.curved(velocity, spin: -20, over: dt)
        for turned in [back, top] {
            #expect(abs(simd_length(turned.velocity) - simd_length(velocity)) < 1e-12)
            #expect(abs(turned.spin) < 20)
            #expect(abs(turned.spin) > 19.5)
        }
        // Counter-clockwise spin turns the path counter-clockwise, and back.
        #expect(velocity.x * back.velocity.y - velocity.y * back.velocity.x > 0)
        #expect(velocity.x * top.velocity.y - velocity.y * top.velocity.x < 0)
        let still = BallState.curved(velocity, spin: 0, over: dt)
        #expect(still.velocity == velocity)
        #expect(still.spin == 0)
        // A roll faster than any bolt could set bends no harder than the
        // hardest clip, though it keeps all of its turn.
        let rolled = BallState.curved(velocity, spin: 200, over: dt)
        let clipped = BallState.curved(velocity, spin: BoltState.spinKick, over: dt)
        #expect(simd_distance(rolled.velocity, clipped.velocity) < 1e-12)
        #expect(rolled.spin > 198)
    }

    @Test("A spinning ball curves off the line a still one flies, until it hits something")
    func spinCurvesTheFlight() {
        func thrown(spin: Double) -> SimulationEngine {
            var engine = playing()
            engine.state.ball = BallState(position: .init(-0.6, -0.2), velocity: .init(0, 1.2), spin: spin)
            return engine
        }
        var spinning = thrown(spin: 20)
        var still = thrown(spin: 0)
        for _ in 0 ..< 30 {
            spinning.step(inputs: [:])
            still.step(inputs: [:])
        }
        // Counter-clockwise on a ball going up swings it left.
        #expect(spinning.state.ball.position.x < still.state.ball.position.x - 0.005)
        // The air bleeds the spin off gradually.
        #expect(abs(spinning.state.ball.spin - 20 * exp(-BallState.spinDecay * 0.25)) < 1e-9)

        // Driven into the side wall, the wall grips it: it comes off rolling
        // along the wall rather than skidding with the spin it brought.
        spinning.state.ball.velocity = .init(-2, 0.3)
        var bounced = false
        for _ in 0 ..< 240 {
            spinning.step(inputs: [:])
            if spinning.state.ball.velocity.x > 0 { bounced = true; break }
        }
        #expect(bounced, "the ball never reached the wall")
        let ball = spinning.state.ball
        #expect(abs(ball.position.x - (-spinning.arena.halfWidth + ball.radius)) < 1e-9, "it met something other than the side wall")
        #expect(abs(ball.velocity.y - ball.spin * ball.radius) < 1e-9)
    }

    @Test("A bounce grips the ball: a firm one leaves it rolling, a graze barely turns it")
    func surfacesGripTheBall() {
        let r = BallState.nominalRadius
        let floor = SIMD2(0.0, 1.0)
        // Skidding right into the deck, it comes off rolling clockwise, with
        // 2/7 of its run along the floor gone into the turn.
        let skid = BallState.gripped(.init(1, 0.78), from: .init(1, -1), spin: 0, radius: r, normal: floor)
        #expect(skid.spin < -1)
        #expect(abs(skid.velocity.x + skid.spin * r) < 1e-12)
        #expect(abs(skid.velocity.x - 5.0 / 7) < 1e-12)
        #expect(skid.velocity.y == 0.78)
        // Backspin dropped straight down kicks the ball back the way it turns.
        let back = BallState.gripped(.init(0, 0.78), from: .init(0, -1), spin: 20, radius: r, normal: floor)
        #expect(back.velocity.x < -0.1)
        #expect(back.spin < 20)
        // A graze: the floor barely pushed, so it can barely turn the ball.
        let graze = BallState.gripped(.init(1, 0.0078), from: .init(1, -0.01), spin: 0, radius: r, normal: floor)
        #expect(abs(graze.spin) <= BallState.contactFriction * 0.0178 * 2.5 / r + 1e-9)
        #expect(abs(graze.velocity.x + graze.spin * r) > 0.9)
        // No push, no grip.
        let untouched = BallState.gripped(.init(1, 0.5), from: .init(1, 0.5), spin: 3, radius: r, normal: floor)
        #expect(untouched.velocity == SIMD2(1, 0.5))
        #expect(untouched.spin == 3)
        // A surface moving under a still ball drags it along and turns it.
        let dragged = BallState.gripped(
            .init(0, 0.95), from: .init(0, -1), spin: 0, radius: r, normal: floor, surfaceVelocity: .init(1, 0)
        )
        #expect(dragged.velocity.x > 0.2)
        #expect(dragged.spin > 1)
    }

    @Test("A ball glancing off a hull goes away turning; a square hit does not")
    func hullGlanceSpinsTheBall() {
        func struck(offset: Double) -> BallState {
            var engine = playing()
            var ship = engine.state.ships[.cyan]!
            ship.position = .init(-0.4, 0.1)
            ship.velocity = .zero
            engine.state.ships[.cyan] = ship
            engine.state.ball = BallState(position: .init(-0.62, 0.1 + offset), velocity: .init(1.5, 0))
            for _ in 0 ..< 60 {
                engine.step(inputs: [:])
                if abs(engine.state.ball.velocity.x - 1.5) > 0.1 { break }
            }
            #expect(abs(engine.state.ball.velocity.x - 1.5) > 0.1, "the ball never reached the hull")
            return engine.state.ball
        }
        #expect(abs(struck(offset: 0).spin) < 0.5)
        // Passing over the hull it rolls over the top, clockwise; under it,
        // the other way.
        #expect(struck(offset: 0.07).spin < -1)
        #expect(struck(offset: -0.07).spin > 1)
    }

    @Test("A bolt passing just wide of the ball misses it")
    func thinBoltMissesJustWide() {
        // Thin enough to clip the very edge on purpose, so a bolt a centimetre
        // outside the ball goes by without touching it.
        for side in [1.0, -1.0] {
            #expect(boltImpulse(side: side, offset: BallState.nominalRadius + 0.010) == .zero)
        }
    }

    @Test("A bolt from the back wall reaches the far wall before it fizzles")
    func boltReachesTheFarWall() {
        let configuration = SimulationConfiguration()
        let arena = ArenaGeometry()
        #expect(configuration.boltSpeed * configuration.boltLifetime >= 2 * arena.halfWidth)
    }

    @Test("The trigger is dead once the ship is past the base of the hump")
    func noFiringFromTheOpponentsHalf() {
        // The reach is home plus a short push over the line, out to where the
        // hump starts. Past that the nose still rams but the cannon is
        // holstered.
        let arena = ArenaGeometry()
        var engine = playing()
        engine.state.ball.position = .init(0.8, 0.4)
        engine.state.ships[.cyan]!.position = .init(arena.humpBaseX + 0.05, 0)
        engine.state.ships[.cyan]!.angle = 0
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.isEmpty)
        #expect(engine.state.nextBoltID == 0)
        // A short way over the line is still inside the reach.
        engine.state.ships[.cyan]!.position = .init(0.2, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 1, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.count == 1)
    }

    @Test("Exhaust shoves a ball sitting behind a thrusting ship, and it is not a touch")
    func washPushesBallDownThePlume() {
        var thrusting = playing()
        var coasting = playing()
        for engine in [0, 1] {
            var e = engine == 0 ? thrusting : coasting
            e.state.ships[.cyan]!.position = .init(-0.3, 0.1)
            e.state.ships[.cyan]!.angle = .pi / 2
            e.state.ball.position = .init(-0.3, -0.1)
            e.state.ball.velocity = .zero
            if engine == 0 { thrusting = e } else { coasting = e }
        }
        for tick in 0 ..< 30 {
            thrusting.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: true)])
            coasting.step(inputs: [.cyan: .idle(tick: UInt64(tick))])
        }
        #expect(thrusting.state.ball.velocity.y < coasting.state.ball.velocity.y - 0.01)
        #expect(thrusting.state.match.shipTouches[.cyan] == 0)
    }

    @Test("A ball beside the ship, outside the exhaust cone, feels nothing")
    func washIgnoresBallOutsideCone() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(-0.3, 0.1)
        engine.state.ships[.cyan]!.angle = .pi / 2
        engine.state.ball.position = .init(-0.1, 0.1)
        engine.state.ball.velocity = .zero
        for tick in 0 ..< 30 {
            engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: true)])
        }
        #expect(abs(engine.state.ball.velocity.x) < 0.000_1)
    }

    @Test("Space held on the keyboard reaches the engine as fire")
    func keyboardFireReachesInput() {
        #expect(KeyboardControlMapping.input(tick: 3, held: [.fire]).fire)
        #expect(!KeyboardControlMapping.input(tick: 3, held: [.thrust]).fire)
    }
}
