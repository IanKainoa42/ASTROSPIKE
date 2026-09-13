import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Volleyball court")
struct VolleyballCourtTests {
    private func engine() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.updateArena(.volleyball)
        engine.updateConfiguration(.volleyball(from: SimulationConfiguration()))
        return engine
    }

    @Test("The net stands out of the floor and has no roof hump or lips")
    func shape() {
        let arena = ArenaGeometry.volleyball
        #expect(arena.netStyle == .floorWall)
        #expect(!arena.hasHump)
        #expect(!arena.hasLips)
        #expect(arena.hoop == nil)
        #expect(arena.netTopY == 0)
        // Bottom half means exactly that: floor to the midline.
        #expect(arena.netTopY > arena.floorY)
        #expect(arena.netTopY < arena.ceilingY)
    }

    @Test("A ball driven at the net below the tape comes back, never through")
    func ballCannotCrossLow() {
        var engine = engine()
        engine.beginPlay()
        engine.state.ball = BallState(position: SIMD2(-0.30, -0.30), velocity: SIMD2(2.4, 0))
        for _ in 0 ..< 240 {
            engine.step(inputs: [:])
            let ball = engine.state.ball
            // Anywhere below the tape, the far side is off limits.
            if ball.position.y < ArenaGeometry.volleyball.netTopY {
                #expect(ball.position.x < ArenaGeometry.volleyball.netHalfWidth + 0.05)
            }
            if engine.state.match.phase != .playing { break }
        }
    }

    @Test("A hull cannot drive through the standing net either")
    func hullIsBlocked() {
        let arena = ArenaGeometry.volleyball
        let radius = 0.05
        let contact = arena.floorNetContact(
            position: SIMD2(-0.001, -0.30),
            radius: radius,
            preferredSide: -1
        )
        #expect(contact != nil)
        if let contact {
            #expect(contact.normal.x < 0)
            #expect(contact.position.x <= -arena.netHalfWidth)
        }
    }

    @Test("Above the tape the net is not there")
    func openOverTheTop() {
        let arena = ArenaGeometry.volleyball
        #expect(arena.floorNetContact(
            position: SIMD2(0, arena.netTopY + 0.25),
            radius: 0.04,
            preferredSide: 1
        ) == nil)
    }

    @Test("The first touch of the floor ends the rally")
    func firstBounceScores() {
        let configuration = SimulationConfiguration.volleyball(from: SimulationConfiguration())
        #expect(configuration.allowedFloorBounces == 0)
        #expect(configuration.allowedShipTouches == 3)

        var rules = MatchRules(state: MatchRuleState(phase: .playing), allowedFloorBounces: 0)
        let events = rules.resolve([.ballTouchedFloor(side: .cyan)])
        #expect(events.contains { if case .point = $0 { true } else { false } })
    }
}

@Suite("Basketball court")
struct BasketballCourtTests {
    private func engine() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.updateArena(.basketball)
        engine.updateConfiguration(.basketball(from: SimulationConfiguration()))
        return engine
    }

    @Test("The middle is cleared and a rim hangs in it")
    func shape() {
        let arena = ArenaGeometry.basketball
        #expect(arena.netStyle == .none)
        #expect(!arena.hasHump)
        #expect(!arena.hasLips)
        #expect(arena.hoop != nil)
        #expect(arena.lipContact(position: .zero, radius: 0.04) == nil)
        #expect(arena.humpContact(position: SIMD2(0, 0.6), radius: 0.04) == nil)
    }

    @Test("Only a downward pass through the window scores")
    func scoresDownwardOnly() throws {
        let arena = ArenaGeometry.basketball
        let hoop = try #require(arena.hoop)
        let above = SIMD2(0.0, hoop.centerY + 0.05)
        let below = SIMD2(0.0, hoop.centerY - 0.05)
        #expect(arena.hoopScored(from: above, to: below))
        #expect(!arena.hoopScored(from: below, to: above))
        // Outside the window, past the rim, is a miss.
        let wideAbove = SIMD2(hoop.innerHalfWidth + 0.03, hoop.centerY + 0.05)
        let wideBelow = SIMD2(hoop.innerHalfWidth + 0.03, hoop.centerY - 0.05)
        #expect(!arena.hoopScored(from: wideAbove, to: wideBelow))
    }

    @Test("The rim posts are solid")
    func rimRebounds() throws {
        let arena = ArenaGeometry.basketball
        let hoop = try #require(arena.hoop)
        // Just outside the post, on the far side from the window: close
        // enough to be touching it, not so close that "away" has no
        // direction.
        let post = hoop.postCenter(sign: 1)
        let contact = arena.hoopRimContact(position: post + SIMD2(0.02, 0), radius: 0.04)
        #expect(contact != nil)
        if let contact {
            #expect(contact.normal.x > 0)
            #expect(contact.position.x > post.x)
        }
        #expect(arena.hoopRimContact(position: SIMD2(0, hoop.centerY), radius: 0.02) == nil)
    }

    @Test("The last ship to touch the ball takes the match when it drops through")
    func lastToucherWins() {
        var engine = engine()
        engine.beginPlay()
        let hoop = ArenaGeometry.basketball.hoop!
        engine.state.lastBallToucher = .orange
        engine.state.ball = BallState(
            position: SIMD2(0, hoop.centerY + 0.06),
            velocity: SIMD2(0, -1.6)
        )

        var finished = false
        for _ in 0 ..< 120 {
            engine.step(inputs: [:])
            if engine.state.match.phase == .finished { finished = true; break }
        }
        #expect(finished)
        #expect(engine.state.match.winner == .orange)
    }

    @Test("A ball nobody has touched scores for nobody")
    func untouchedBallDoesNotScore() {
        var engine = engine()
        engine.beginPlay()
        let hoop = ArenaGeometry.basketball.hoop!
        engine.state.lastBallToucher = nil
        engine.state.ball = BallState(
            position: SIMD2(0, hoop.centerY + 0.06),
            velocity: SIMD2(0, -1.6)
        )
        for _ in 0 ..< 30 { engine.step(inputs: [:]) }
        #expect(engine.state.match.phase != .finished)
    }
}

@Suite("Basketball bots")
struct BasketballBotTests {
    private static let config = SimulationConfiguration.basketball(from: SimulationConfiguration())

    /// Drops a ship onto a resting ball exactly as the bot's plan asks, then
    /// reads where the ball's flight would cross the rim's height. The gap is
    /// small on purpose: the plan is solved for the ball where it is, so any
    /// fall before contact is the harness lying to the bot, not the bot missing.
    private func rimCrossing(from point: SIMD2<Double>, homeSign: Double) -> Double? {
        let hoop = ArenaGeometry.basketball.hoop!
        let gravity = 1.9
        let bot = AIController(
            difficulty: .ace,
            configuration: Self.config,
            arena: .basketball
        )
        let plan = bot.shotPlan(from: point, ballVelocity: .zero, homeSign: homeSign)

        var engine = SimulationEngine.testing()
        engine.updateArena(.basketball)
        engine.updateConfiguration(Self.config)
        engine.configureRoster([.cyan, .orange])
        engine.beginPlay()
        for _ in 0 ..< 200 { engine.step(inputs: [:]) }   // let the serve delay run out

        engine.state.ball = BallState(position: point, velocity: .zero)
        let shooter: Seat = homeSign < 0 ? .cyan : .orange
        engine.state.ships[shooter] = ShipState(
            position: point - plan.shot * (AIController.strikeStandoff + 0.015),
            velocity: plan.shot * plan.strike,
            angle: atan2(plan.shot.y, plan.shot.x)
        )
        engine.state.ships[shooter == .cyan ? .orange : .cyan]?.position
            = SIMD2(homeSign * -0.9, 0.5)

        var velocity = engine.state.ball.velocity
        for _ in 0 ..< 10 {
            engine.step(inputs: [:])
            if simd_length(engine.state.ball.velocity - velocity) > 0.3 { break }
            velocity = engine.state.ball.velocity
        }
        velocity = engine.state.ball.velocity
        let ball = engine.state.ball.position
        let discriminant = velocity.y * velocity.y - 2 * gravity * (hoop.centerY - ball.y)
        guard discriminant >= 0 else { return nil }       // never gets up to the rim
        let time = (velocity.y + discriminant.squareRoot()) / gravity
        guard time > 0 else { return nil }                // already past it, going away
        return ball.x + velocity.x * time
    }

    @Test("From anywhere in the shooting pocket the bot's shot comes down through the rim")
    func shotsFallThroughTheRim() throws {
        let hoop = try #require(ArenaGeometry.basketball.hoop)
        for homeSign in [-1.0, 1.0] {
            for step in 0 ..< 8 {
                let point = SIMD2(
                    homeSign * (0.16 + Double(step) * 0.045),
                    hoop.centerY - 0.30 + Double(step % 4) * 0.14
                )
                let crossing = try #require(
                    rimCrossing(from: point, homeSign: homeSign),
                    "no shot at all from \(point)"
                )
                #expect(
                    abs(crossing) <= hoop.innerHalfWidth,
                    "from \(point) the ball crosses the rim at \(crossing)"
                )
            }
        }
    }

    @Test("Two bots left alone on the hoop court never let the ball die on the floor")
    func botsKeepTheHoopBallAlive() {
        // Without the dribble the ball rolls dead, nobody can get under it, and
        // the match deadlocks. How long a match takes is not the measure: the
        // first basket lands anywhere from 3 to 197 seconds in, from ship starts
        // two millimetres apart. A dead ball is: with the dribble it never rolls
        // flat for more than 9 ticks from these starts, without it 369 to 3,904.
        for nudge in 0 ..< 4 {
            var engine = SimulationEngine.testing()
            engine.updateArena(.basketball)
            engine.updateConfiguration(Self.config)
            engine.configureRoster([.cyan, .orange])
            engine.beginPlay()
            engine.state.ships[.cyan]!.position.x += Double(nudge) * 0.002
            var bots: [Seat: AIController] = [
                .cyan: AIController(difficulty: .pilot, configuration: Self.config, arena: .basketball),
                .orange: AIController(difficulty: .pilot, configuration: Self.config, arena: .basketball),
            ]

            var flat = 0
            var longestFlat = 0
            // Forty seconds at 120Hz.
            for tick in 0 ..< 4_800 {
                var inputs: [Seat: PlayerInput] = [:]
                for seat in [Seat.cyan, .orange] {
                    inputs[seat] = bots[seat]!.input(for: engine.state, seat: seat, tick: UInt64(tick))
                }
                engine.step(inputs: inputs)
                flat = abs(engine.state.ball.velocity.y) < 0.05 ? flat + 1 : 0
                longestFlat = max(longestFlat, flat)
                if engine.state.match.phase == .finished {
                    #expect(engine.state.match.winner != nil)
                    break
                }
            }
            // Half a second rolling flat is a dead ball.
            #expect(longestFlat < 60, "start \(nudge): the ball rolled flat for \(longestFlat) ticks")
        }
    }
}
