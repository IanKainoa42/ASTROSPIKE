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
