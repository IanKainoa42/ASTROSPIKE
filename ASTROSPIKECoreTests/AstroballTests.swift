import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("ASTROBALL")
struct AstroballTests {
    private func rules(solo: Int = 3, cyanPilots: Int = 1, orangePilots: Int = 1) -> MatchRules {
        var tuning = AstroballTuning()
        tuning.soloTouches = solo
        var rules = MatchRules(state: MatchRuleState(phase: .playing), allowedFloorBounces: 1)
        rules.volley = VolleyRules(tuning: tuning, pilots: SideCounts(cyan: cyanPilots, orange: orangePilots))
        return rules
    }

    private func pointReason(_ events: [SimulationEvent]) -> PointReason? {
        events.lazy.compactMap { event -> PointReason? in
            guard case let .point(_, reason) = event else { return nil }
            return reason
        }.first
    }

    // MARK: Touches

    @Test("One touch and over: a solo side's second touch is the other side's point")
    func soloOneTouch() {
        var rules = rules(solo: 1)
        #expect(rules.resolve([.ballPlayed(seat: .cyan)]).isEmpty)
        let events = rules.resolve([.ballPlayed(seat: .cyan)])
        #expect(pointReason(events) == .touchLimit)
        #expect(rules.state.score.orange == 1)
    }

    @Test("A solo side gets three touches, and may play them all itself")
    func soloThreeTouches() {
        var rules = rules(solo: 3)
        for _ in 0 ..< 3 { #expect(rules.resolve([.ballPlayed(seat: .orange)]).isEmpty) }
        #expect(pointReason(rules.resolve([.ballPlayed(seat: .orange)])) == .touchLimit)
        #expect(rules.state.score.cyan == 1)
    }

    @Test("A side of two gets three whatever the solo setting, alternating")
    func teamThreeTouches() {
        var rules = rules(solo: 1, cyanPilots: 2)
        for seat in [Seat.cyan, .cyanWing, .cyan] { #expect(rules.resolve([.ballPlayed(seat: seat)]).isEmpty) }
        #expect(pointReason(rules.resolve([.ballPlayed(seat: .cyanWing)])) == .touchLimit)
    }

    @Test("On a side of two the same pilot cannot play it twice running")
    func noDoubles() {
        var rules = rules(cyanPilots: 2)
        _ = rules.resolve([.ballPlayed(seat: .cyanWing)])
        #expect(pointReason(rules.resolve([.ballPlayed(seat: .cyanWing)])) == .doubleTouch)
        #expect(rules.state.score.orange == 1)
    }

    @Test("The other side playing it, or the ball crossing, starts the count again")
    func countResets() {
        var rules = rules(solo: 2)
        _ = rules.resolve([.ballPlayed(seat: .cyan)])
        _ = rules.resolve([.ballPlayed(seat: .cyan)])
        _ = rules.resolve([.ballPlayed(seat: .orange)])
        #expect(rules.state.shipTouches.cyan == 0)
        #expect(rules.resolve([.ballPlayed(seat: .cyan)]).isEmpty)

        var crossing = self.rules(cyanPilots: 2)
        _ = crossing.resolve([.ballPlayed(seat: .cyan)])
        _ = crossing.resolve([.ballCrossedCenter(into: .orange)])
        #expect(crossing.state.lastTouch == nil)
        #expect(crossing.state.shipTouches == SideCounts())
        // Back over: cyan plays first again with no double held against it.
        #expect(crossing.resolve([.ballPlayed(seat: .cyan)]).isEmpty)
    }

    @Test("Outside ASTROBALL a played ball is never a fault")
    func duelHasNoTouchBook() {
        var rules = MatchRules(state: MatchRuleState(phase: .playing), allowedFloorBounces: 1)
        for _ in 0 ..< 6 { #expect(rules.resolve([.ballPlayed(seat: .cyan)]).isEmpty) }
        #expect(rules.resolve([.ballTouchedZone(side: .cyan)]).isEmpty)
        #expect(rules.state.score == Score())
    }

    // MARK: Zone

    @Test("A zone touch is the zone's point even with a floor bounce the same step")
    func zoneBeatsFloor() {
        var rules = MatchRules(state: MatchRuleState(phase: .playing), allowedFloorBounces: 0)
        rules.volley = VolleyRules(tuning: AstroballTuning(), pilots: SideCounts(cyan: 1, orange: 1))
        let events = rules.resolve([.ballTouchedFloor(side: .cyan), .ballTouchedZone(side: .cyan)])
        #expect(pointReason(events) == .zone)
        #expect(rules.state.score.orange == 1)
    }

    @Test("A host's zone off the wire is clamped to the path; a non-finite end is no zone")
    func zoneSanitized() {
        var tuning = AstroballTuning()
        tuning.zoneStart = -4
        tuning.zoneEnd = 9
        #expect(tuning.zoneRange == 0 ... 1)
        tuning.zoneEnd = .infinity
        #expect(tuning.zoneRange == nil)
        #expect(!tuning.zoneContains(0.5))
        tuning.zoneEnd = .nan
        #expect(tuning.zoneRange == nil)
    }

    @Test("The default zone is the half of the floor nearest the net")
    func defaultZone() {
        let court = ArenaGeometry.volleyball
        let tuning = AstroballTuning()
        let floor = court.cornerTangentX - court.netHalfWidth
        let near = court.wallPathFraction(at: SIMD2(court.netHalfWidth + floor * 0.3, court.floorY))!
        let far = court.wallPathFraction(at: SIMD2(-(court.netHalfWidth + floor * 0.7), court.floorY))!
        #expect(tuning.zoneContains(near))
        #expect(!tuning.zoneContains(far))
        let wall = court.wallPathFraction(at: SIMD2(court.halfWidth, (court.floorY + court.ceilingY) / 2))!
        #expect(!tuning.zoneContains(wall))
    }

    @Test("The wall path runs floor, corner, wall, corner; the roof's flat is off it")
    func wallPathMapping() {
        let court = ArenaGeometry.volleyball
        #expect(court.wallPathFraction(at: SIMD2(court.netHalfWidth, court.floorY)) == 0)
        #expect(court.wallPathFraction(at: SIMD2(0.1, court.ceilingY)) == nil)
        var previous = -1.0
        for step in 0 ... 20 {
            let fraction = Double(step) / 20
            let point = court.wallPathPoint(at: fraction)
            let back = court.wallPathFraction(at: point)
            #expect(back != nil)
            #expect(abs((back ?? -1) - fraction) < 0.002, "fraction \(fraction) came back \(back ?? -1)")
            // Mirrored onto the left half it is the same place.
            #expect(court.wallPathFraction(at: SIMD2(-point.x, point.y)) == back)
            #expect(fraction > previous)
            previous = fraction
        }
        #expect(court.wallPathPlace(at: 0.0) == "FLOOR 0%")
        #expect(court.wallPathPlace(at: 1.0) == "ROOF")
    }

    // MARK: Engine

    private func astroballEngine(_ tuning: AstroballTuning? = AstroballTuning()) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        if let tuning {
            engine.updateConfiguration(.astroball(from: engine.configuration, tuning: tuning))
        }
        engine.updateArena(.volleyball)
        engine.beginPlay()
        return engine
    }

    @Test("A bolt into the ball is a touch in ASTROBALL and nowhere else")
    func boltIsATouch() {
        for astroball in [true, false] {
            var engine = astroballEngine(astroball ? AstroballTuning() : nil)
            engine.state.ball.position = .init(-0.55, -0.25)
            engine.state.ball.velocity = .zero
            engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
            var hit = false
            for tick in 1 ..< 12 {
                engine.step(inputs: [.cyan: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, fire: false)])
                if engine.state.lastBallToucher == .cyan { hit = true; break }
            }
            #expect(hit, "the bolt never reached the ball")
            #expect(engine.state.match.lastTouch == (astroball ? .cyan : nil))
            #expect(engine.state.match.shipTouches.cyan == (astroball ? 1 : 0))
        }
    }

    @Test("A hull hit is a touch, with the seat that played it")
    func hullIsATouch() {
        var engine = astroballEngine()
        let ship = engine.state.ships[.cyan]!
        engine.state.ball = BallState(position: ship.position + SIMD2(0, 0.2), velocity: SIMD2(0, -1))
        var touched = false
        for tick in UInt64(0) ..< 30 {
            engine.step(inputs: [.cyan: .idle(tick: tick)])
            if engine.state.match.lastTouch == .cyan { touched = true; break }
        }
        #expect(touched)
        #expect(engine.state.match.shipTouches.cyan == 1)
    }

    @Test("The ball landing in the zone gives the other side the point")
    func zoneLandingScores() {
        let court = ArenaGeometry.volleyball
        let floor = court.cornerTangentX - court.netHalfWidth
        for (share, scores) in [(0.25, true), (0.8, false)] {
            var engine = astroballEngine()
            engine.state.ships[.cyan]!.position = .init(-0.9, 0.4)
            engine.state.ships[.orange]!.position = .init(0.9, 0.4)
            let x = -(court.netHalfWidth + floor * share)
            engine.state.ball = BallState(position: .init(x, court.floorY + 0.15), velocity: .init(0, -1))
            for tick in UInt64(0) ..< 40 { engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)]) }
            #expect(engine.state.match.score.orange == (scores ? 1 : 0), "floor share \(share)")
        }
    }

    @Test("ASTROBALL's walls soak the ball up; the duel's keep their bounce")
    func wallBounce() {
        func kept(_ tuning: AstroballTuning?) -> Double {
            var engine = astroballEngine(tuning)
            engine.state.ships[.cyan]!.position = .init(-0.5, 0.4)
            engine.state.ships[.orange]!.position = .init(0.3, 0.5)
            let court = engine.arena
            engine.state.ball = BallState(position: .init(court.halfWidth - 0.15, 0.1), velocity: .init(1.5, 0))
            for tick in UInt64(0) ..< 60 {
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
                if engine.state.ball.velocity.x < 0 { return -engine.state.ball.velocity.x / 1.5 }
            }
            return .nan
        }
        var soft = AstroballTuning()
        soft.wallBounce = 0.3
        let astroball = kept(soft)
        let duel = kept(nil)
        #expect(abs(astroball - 0.3) < 0.06, "kept \(astroball)")
        #expect(duel > 0.7, "kept \(duel)")
    }

    // MARK: Setup

    @Test("Two a side is one ball on the big court behind a standing net")
    func doublesSetup() {
        let configuration = SimulationConfiguration.astroball(from: SimulationConfiguration(), tuning: AstroballTuning())
        #expect(configuration.ballCount == 1)
        #expect(configuration.astroball == AstroballTuning())
        let court = ArenaGeometry.astroball(doubles: true)
        #expect(court.netStyle == .floorWall)
        #expect(court.halfWidth > ArenaGeometry.volleyball.halfWidth)
        #expect(ArenaGeometry.astroball(doubles: false) == .volleyball)
    }

    @Test("Online ASTROBALL seats like a duel: three or four pilots play two a side")
    func onlineRoster() {
        #expect(OnlineSeating.roster(filled: [.cyan, .orange], format: .astroball) == Seat.singles)
        #expect(OnlineSeating.roster(filled: [.cyan, .orange, .cyanWing], format: .astroball) == Seat.doubles)
        #expect(OnlineSeating.order(format: .astroball) == OnlineSeating.order(format: .duel))
    }

    @Test("Settings round-trip through defaults, clamped, defaults leaving no key")
    func storedRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "astroball-tests-\(UUID().uuidString)"))
        AstroballTuning().store(in: defaults)
        #expect(defaults.object(forKey: AstroballTuning.zoneEndKey) == nil)
        var tuning = AstroballTuning()
        tuning.soloTouches = 1
        tuning.zoneStart = 0.6
        tuning.zoneEnd = 0.9
        tuning.wallBounce = 0.4
        tuning.store(in: defaults)
        #expect(AstroballTuning.stored(in: defaults) == tuning)
        defaults.set(9, forKey: AstroballTuning.soloTouchesKey)
        #expect(AstroballTuning.stored(in: defaults).soloTouches == 3)
    }
}
