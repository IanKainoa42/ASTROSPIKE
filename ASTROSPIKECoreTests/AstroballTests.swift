import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("ASTROBALL")
struct AstroballTests {
    private func rules(solo: Int = 3, inARow: Int = 2, cyanPilots: Int = 1, orangePilots: Int = 1) -> MatchRules {
        var tuning = AstroballTuning()
        tuning.soloTouches = solo
        tuning.inARow = inARow
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

    @Test("A solo side gets three touches, and may play them all itself when in a row allows it")
    func soloThreeTouches() {
        var rules = rules(solo: 3, inARow: 3)
        for _ in 0 ..< 3 { #expect(rules.resolve([.ballPlayed(seat: .orange)]).isEmpty) }
        #expect(pointReason(rules.resolve([.ballPlayed(seat: .orange)])) == .touchLimit)
        #expect(rules.state.score.cyan == 1)
    }

    @Test("A side of two gets three whatever the solo setting")
    func teamThreeTouches() {
        var rules = rules(solo: 1, cyanPilots: 2)
        for seat in [Seat.cyan, .cyanWing, .cyan] { #expect(rules.resolve([.ballPlayed(seat: seat)]).isEmpty) }
        #expect(pointReason(rules.resolve([.ballPlayed(seat: .cyanWing)])) == .touchLimit)
    }

    @Test("A guest's touch lights the meter and does not award the point")
    func guestNotesTheTouchWithoutScoring() {
        var rules = rules(solo: 1)
        rules.noteRally([.ballPlayed(seat: .cyan)])
        #expect(rules.state.shipTouches.cyan == 1)
        #expect(rules.state.lastTouch == .cyan)
        #expect(rules.state.phase == .playing)
        #expect(rules.state.score == Score())
        // The touch that spends the allowance still shows, and the rally stays.
        rules.noteRally([.ballPlayed(seat: .cyan)])
        #expect(rules.state.shipTouches.cyan == 2)
        #expect(rules.state.phase == .playing)
        #expect(rules.state.score == Score())
        rules.noteRally([.ballTouchedFloor(side: .orange)])
        #expect(rules.state.floorContacts.orange == 1)
        rules.noteRally([.ballTouchedFloor(side: .orange)])
        #expect(rules.state.floorContacts.orange == 2)
        #expect(rules.state.phase == .playing)
        // A goal is the host's. The touch beside it is not booked either:
        // the host returns before the touch loop.
        var clean = self.rules(solo: 3)
        clean.noteRally([.ballEnteredGoal(defending: .cyan), .ballPlayed(seat: .orange)])
        #expect(clean.state.shipTouches == SideCounts())
        #expect(clean.state.score == Score())
    }

    @Test("A guest engine counts the touch it played and does not take the point")
    func guestEngineCountsItsOwnTouch() {
        var guest = astroballEngine()
        guest.followsHost = true
        let home = SIMD2(-0.4, 0.2)
        guest.state.ball = BallState(position: home + SIMD2(0, 0.16), velocity: .init(0, -2))
        var waited = 0
        while guest.state.match.shipTouches.cyan == 0, waited < 40 {
            guest.state.ships[.cyan]!.position = home
            guest.state.ships[.cyan]!.velocity = .zero
            let tick = guest.state.tick
            guest.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            waited += 1
        }
        #expect(guest.state.match.shipTouches.cyan == 1)
        #expect(guest.state.match.lastTouch == .cyan)
        #expect(guest.state.match.phase == .playing)
        #expect(guest.state.match.score == Score())
    }

    @Test("Two in a row is fine by default; a triple gives the point away")
    func noTriples() {
        var rules = rules(cyanPilots: 2)
        #expect(rules.resolve([.ballPlayed(seat: .cyanWing)]).isEmpty)
        #expect(rules.resolve([.ballPlayed(seat: .cyanWing)]).isEmpty)
        #expect(pointReason(rules.resolve([.ballPlayed(seat: .cyanWing)])) == .doubleTouch)
        #expect(rules.state.score.orange == 1)

        // A solo side is held to it too, under its touch count.
        var solo = self.rules(solo: 3)
        _ = solo.resolve([.ballPlayed(seat: .orange)])
        _ = solo.resolve([.ballPlayed(seat: .orange)])
        #expect(pointReason(solo.resolve([.ballPlayed(seat: .orange)])) == .doubleTouch)
    }

    @Test("In a row is a setting: one is the old no-doubles rule, three lets a pilot play the side's three")
    func inARowSetting() {
        var strict = rules(inARow: 1, cyanPilots: 2)
        _ = strict.resolve([.ballPlayed(seat: .cyan)])
        #expect(pointReason(strict.resolve([.ballPlayed(seat: .cyan)])) == .doubleTouch)

        var loose = rules(inARow: 3, cyanPilots: 2)
        for _ in 0 ..< 3 { #expect(loose.resolve([.ballPlayed(seat: .cyan)]).isEmpty) }
        #expect(pointReason(loose.resolve([.ballPlayed(seat: .cyan)])) == .touchLimit)

        // A partner's touch breaks the run.
        var run = rules(cyanPilots: 2)
        for seat in [Seat.cyan, .cyan, .cyanWing] { #expect(run.resolve([.ballPlayed(seat: seat)]).isEmpty) }
        #expect(run.state.lastTouchRun == 1)
    }

    @Test("The other side playing it, or the ball crossing, starts the count again")
    func countResets() {
        var rules = rules(solo: 2)
        _ = rules.resolve([.ballPlayed(seat: .cyan)])
        _ = rules.resolve([.ballPlayed(seat: .cyan)])
        #expect(rules.state.score == Score())
        _ = rules.resolve([.ballPlayed(seat: .orange)])
        #expect(rules.state.shipTouches.cyan == 0)
        #expect(rules.resolve([.ballPlayed(seat: .cyan)]).isEmpty)

        var crossing = self.rules(cyanPilots: 2)
        _ = crossing.resolve([.ballPlayed(seat: .cyan)])
        _ = crossing.resolve([.ballCrossedCenter(into: .orange)])
        #expect(crossing.state.lastTouch == nil)
        #expect(crossing.state.shipTouches == SideCounts())
        // Back over: cyan plays first again with no run held against it.
        #expect(crossing.resolve([.ballPlayed(seat: .cyan)]).isEmpty)
        #expect(crossing.state.lastTouchRun == 1)
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
        #expect(!tuning.zoneContains(0.02))
        tuning.zoneEnd = .nan
        #expect(tuning.zoneRange == nil)
    }

    @Test("Default zones: the floor nearest the net to 28%, and a small target 7% to 13% up the back wall")
    func defaultZone() {
        let court = ArenaGeometry.astroball(doubles: false)
        let tuning = AstroballTuning()
        let floor = court.floorCornerTangentX - court.netHalfWidth
        let near = court.wallPathFraction(at: SIMD2(court.netHalfWidth + floor * 0.2, court.floorY))!
        let mid = court.wallPathFraction(at: SIMD2(-(court.netHalfWidth + floor * 0.6), court.floorY))!
        #expect(tuning.zoneContains(near))
        #expect(!tuning.zoneContains(mid))
        // Measured up the straight wall, above the corner arc, as the zone is.
        let lowWall = court.wallPathFraction(ofWall: 0.1)
        let highWall = court.wallPathFraction(at: SIMD2(court.halfWidth, (court.floorY + court.ceilingY) / 2))!
        #expect(tuning.zoneContains(lowWall))
        #expect(!tuning.zoneContains(highWall))
        let target = court.wallPathFraction(at: court.wallPathPoint(at: tuning.zone2Start + 0.002))!
        #expect(tuning.zoneContains(target))
        #expect(!tuning.zoneContains(court.wallPathFraction(ofFloor: 1)), "the floor corner is clear")
        #expect(!tuning.zoneContains(court.wallPathFraction(ofWall: 0.2)), "the target stops at 13% of the wall")
    }

    @Test("The net stops the beam; either side of it is clear")
    func netBlocksBeam() {
        let court = ArenaGeometry.volleyball
        #expect(court.netBlocks(from: SIMD2(-0.3, court.floorY + 0.1), to: SIMD2(0.3, court.floorY + 0.1)))
        #expect(!court.netBlocks(from: SIMD2(-0.3, 0.2), to: SIMD2(0.3, 0.2)))
        #expect(!court.netBlocks(from: SIMD2(0.2, court.floorY + 0.1), to: SIMD2(0.5, court.floorY + 0.1)))
        #expect(!ArenaGeometry.standard.netBlocks(from: SIMD2(-0.3, 0), to: SIMD2(0.3, 0)))
    }

    @Test("The wall path runs floor, corner, wall, corner; the roof's flat is off it")
    func wallPathMapping() {
        let court = ArenaGeometry.astroball(doubles: false)
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
        engine.updateArena(.astroball(doubles: false))
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

    @Test("A hull touching the net's upper half costs what Net touch says; the lower half is fair; the duel's net is only a wall")
    func netTouch() {
        let court = ArenaGeometry.astroball(doubles: false)
        let netHeight = court.netTopY - court.floorY
        // nil: the duel. Otherwise each Net touch setting.
        let modes: [NetTouch?] = [nil, .off, .stun, .point]
        for mode in modes {
            for (share, high) in [(0.85, true), (0.2, false)] {
                var tuning = AstroballTuning()
                if let mode { tuning.netTouch = mode }
                var engine = astroballEngine(mode == nil ? nil : tuning)
                engine.state.ships[.orange]!.position = .init(0.9, 0.4)
                engine.state.ships[.cyan]!.position = .init(-(court.netHalfWidth + 0.02), court.floorY + netHeight * share)
                engine.state.ships[.cyan]!.velocity = .init(0.5, 0)
                engine.state.ball = BallState(position: .init(0.7, 0.4), velocity: .zero)
                for tick in UInt64(0) ..< 5 { engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)]) }
                let label = "\(String(describing: mode)), height \(share)"
                #expect(engine.state.match.score.orange == (mode == .point && high ? 1 : 0), "\(label)")
                let stunned = engine.state.ships[.cyan]!.stunTicks > 0
                #expect(stunned == (mode == .stun && high), "\(label)")
                if mode == .stun && high {
                    let left = Double(engine.state.ships[.cyan]!.stunTicks) * engine.configuration.stepDuration
                    #expect(left > 0.9 && left <= 1.0, "about a second stunned, \(left) left")
                }
            }
        }
    }

    @Test("Net touch defaults to stun and rides the wire; an older host's payload reads the default")
    func netTouchSetting() throws {
        #expect(AstroballTuning().netTouch == .stun)
        for mode in NetTouch.allCases {
            var tuning = AstroballTuning()
            tuning.netTouch = mode
            #expect(try JSONDecoder().decode(AstroballTuning.self, from: JSONEncoder().encode(tuning)).netTouch == mode)
        }
        #expect(try JSONDecoder().decode(AstroballTuning.self, from: Data("{}".utf8)).netTouch == .stun)
    }

    @Test("The ball landing in the zone gives the other side the point")
    func zoneLandingScores() {
        let court = ArenaGeometry.astroball(doubles: false)
        let floor = court.floorCornerTangentX - court.netHalfWidth
        // The default zone is the quarter of the floor nearest the net, so
        // a landing well inside it scores and one past it, short of the
        // corner zone, does not.
        for (share, scores) in [(0.1, true), (0.5, false), (0.8, false)] {
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

    @Test("ASTROBALL's floor is deader than its walls, and never livelier")
    func floorBounce() {
        // A drop onto the flat floor past the net-side zone and short of the
        // corner, so it scores nothing and meets no arc.
        func kept(_ tuning: AstroballTuning?) -> Double {
            var engine = astroballEngine(tuning)
            let court = engine.arena
            let floor = court.floorCornerTangentX - court.netHalfWidth
            engine.state.ships[.cyan]!.position = .init(-0.9, 0.4)
            engine.state.ships[.orange]!.position = .init(0.9, 0.4)
            let x = -(court.netHalfWidth + floor * 0.6)
            engine.state.ball = BallState(position: .init(x, court.floorY + engine.state.ball.radius + 0.02), velocity: .init(0, -1.5))
            var falling = 0.0
            for tick in UInt64(0) ..< 30 {
                if engine.state.ball.velocity.y < 0 { falling = -engine.state.ball.velocity.y }
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
                if engine.state.ball.velocity.y > 0 { return engine.state.ball.velocity.y / falling }
            }
            return .nan
        }
        let standard = kept(AstroballTuning())
        #expect(abs(standard - 0.3) < 0.06, "kept \(standard)")
        #expect(standard < AstroballTuning().clampedWallBounce)
        var lively = AstroballTuning()
        lively.floorBounce = 0.8
        lively.wallBounce = 0.4
        let capped = kept(lively)
        #expect(abs(capped - 0.4) < 0.06, "a floor above the walls plays at the walls' bounce: kept \(capped)")
        #expect(lively.clampedFloorBounce == lively.clampedWallBounce)
    }

    @Test("ASTROBALL's side walls lean out as they rise; every other court's stand plumb")
    func wallsLeanOut() {
        for court in [ArenaGeometry.astroball(doubles: false), .astroball(doubles: true)] {
            let span = court.sideWallSpan
            #expect(court.wallInset > 0)
            #expect(abs(court.sideWallX(atY: span.high) - court.halfWidth) < 1e-12, "the top of the wall is the court's width")
            #expect(abs(court.sideWallX(atY: span.low) - (court.halfWidth - court.wallInset)) < 1e-12)
            let lean = atan(court.wallInset / (span.high - span.low))
            #expect(abs(lean - ArenaGeometry.astroballWallLean) < 1e-9)
            // The floor corner meets the foot of the wall rather than the old plumb line.
            #expect(abs(court.floorCornerTangentX + court.cornerRadiusX - (court.halfWidth - court.wallInset)) < 1e-12)
            // A ball resting on the wall mid-height is pushed in and up, never down.
            let mid = (span.low + span.high) / 2
            let contact = court.sideWallContact(position: SIMD2(court.sideWallX(atY: mid) - 0.03, mid), radius: 0.042)
            #expect(contact != nil && contact!.normal.x < 0 && contact!.normal.y > 0)
        }
        for court in [ArenaGeometry.standard, .volleyball, .doubles(ballRadius: BallState.nominalRadius)] {
            #expect(court.wallInset == 0)
            #expect(court.sideWallX(atY: 0) == court.halfWidth)
            #expect(court.sideWallContact(position: SIMD2(court.halfWidth - 0.01, 0), radius: 0.042) == nil)
        }
    }

    @Test("A flat shot into ASTROBALL's wall comes off climbing; into a plumb wall it does not")
    func leaningWallLifts() {
        func lift(_ arena: ArenaGeometry) -> Double {
            var engine = astroballEngine()
            engine.updateArena(arena)
            engine.state.ships[.cyan]!.position = .init(-0.9, 0.4)
            engine.state.ships[.orange]!.position = .init(0.3, 0.5)
            let y = (arena.sideWallSpan.low + arena.sideWallSpan.high) / 2
            engine.state.ball = BallState(position: .init(arena.sideWallX(atY: y) - 0.2, y), velocity: .init(1.5, 0))
            for tick in UInt64(0) ..< 60 {
                let before = engine.state.ball.velocity.y
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
                if engine.state.ball.velocity.x < 0 { return engine.state.ball.velocity.y - before }
            }
            return .nan
        }
        let leaning = lift(.astroball(doubles: false))
        var plumb = ArenaGeometry.astroball(doubles: false)
        plumb.wallInset = 0
        let flat = lift(plumb)
        // A plumb wall lifts a little too: its grip takes back some of the
        // fall the ball picked up on the way over. The lean adds the climb.
        #expect(leaning > flat + 0.12, "lean lifted \(leaning), plumb \(flat)")
    }

    @Test("A floor corner blends from the wall's bounce to the floor's")
    func cornerBlend() {
        #expect(ArenaGeometry.cornerRestitution(normal: SIMD2(-1, 0), wall: 0.5, floor: 0.3) == 0.5)
        #expect(ArenaGeometry.cornerRestitution(normal: SIMD2(0, 1), wall: 0.5, floor: 0.3) == 0.3)
        #expect(ArenaGeometry.cornerRestitution(normal: SIMD2(0, -1), wall: 0.5, floor: 0.3) == 0.5, "a roof corner is all wall")
        let half = ArenaGeometry.cornerRestitution(normal: SIMD2(-0.6, 0.8), wall: 0.5, floor: 0.3)
        #expect(half > 0.3 && half < 0.5)
    }

    // MARK: Setup

    @Test("Two a side is one ball on the big court behind a standing net")
    func doublesSetup() {
        let configuration = SimulationConfiguration.astroball(from: SimulationConfiguration(), tuning: AstroballTuning())
        #expect(configuration.ballCount == 1)
        #expect(configuration.astroball == AstroballTuning())
        let court = ArenaGeometry.astroball(doubles: true)
        #expect(court.netStyle == .floorWall)
        let singles = ArenaGeometry.astroball(doubles: false)
        #expect(court.halfWidth > singles.halfWidth)
        #expect(abs(singles.halfWidth - ArenaGeometry.volleyball.halfWidth * ArenaGeometry.astroballWidthScale) < 1e-9)
        #expect(singles.netStyle == .floorWall)
    }

    @Test("Online ASTROBALL seats like a duel: three or four pilots play two a side")
    func onlineRoster() {
        #expect(OnlineSeating.roster(filled: [.cyan, .orange], format: .astroball) == Seat.singles)
        #expect(OnlineSeating.roster(filled: [.cyan, .orange, .cyanWing], format: .astroball) == Seat.doubles)
        #expect(OnlineSeating.order(format: .astroball) == OnlineSeating.order(format: .duel))
    }

    @Test("Settings round-trip through defaults, clamped, defaults leaving no key")
    @MainActor func storedRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "astroball-tests-\(UUID().uuidString)"))
        AstroballTuning().store(in: defaults)
        #expect(defaults.object(forKey: AstroballTuning.zoneEndKey) == nil)
        var tuning = AstroballTuning()
        tuning.soloTouches = 1
        tuning.zoneStart = 0.6
        tuning.zoneEnd = 0.9
        tuning.wallBounce = 0.4
        tuning.inARow = 3
        tuning.crossLean = 0.5
        tuning.store(in: defaults)
        #expect(AstroballTuning.stored(in: defaults) == tuning)
        #expect(FlightTuningStore(defaults: defaults).snapshot.astroball == tuning)
        defaults.set(9, forKey: AstroballTuning.soloTouchesKey)
        defaults.set(0, forKey: AstroballTuning.inARowKey)
        defaults.set(5.0, forKey: AstroballTuning.crossLeanKey)
        let clamped = AstroballTuning.stored(in: defaults)
        #expect(clamped.soloTouches == 3)
        #expect(clamped.inARow == 1)
        #expect(clamped.crossLean == AstroballTuning.crossLeanRange.upperBound)
    }

    // MARK: MAX CROSS

    @Test("The MAX CROSS line rises from the top of the net and leans over the far half")
    func crossLineLeans() {
        let court = ArenaGeometry.astroball(doubles: false)
        let tuning = AstroballTuning()
        #expect(court.crossingLimit(atY: court.netTopY, astroball: tuning) == 0)
        #expect(court.crossingLimit(atY: court.floorY, astroball: tuning) == 0)
        let top = court.crossingLimit(atY: court.ceilingY, astroball: tuning)
        #expect(abs(top - tuning.crossLean * court.halfWidth) < 1e-9)
        let mid = court.crossingLimit(atY: (court.netTopY + court.ceilingY) / 2, astroball: tuning)
        #expect(abs(mid - top / 2) < 1e-9)
        // The duel keeps its fixed line.
        #expect(court.crossingLimit(atY: court.ceilingY, astroball: nil) == court.opponentCrossingLimit)
    }

    @Test("MAX CROSS slings a hull back, and one that drops over the net cannot sink there")
    func crossLineSlingshots() {
        var engine = astroballEngine()
        let court = engine.arena
        // Cyan defends the left. Flat out at the line, high up: it crosses,
        // then is flung back to its own side of the line.
        let y = court.netTopY + (court.ceilingY - court.netTopY) * 0.5
        let limit = court.crossingLimit(atY: y, astroball: AstroballTuning())
        engine.state.ships[.cyan]!.position = .init(limit - 0.02, y)
        engine.state.ships[.cyan]!.velocity = .init(3, 0)
        engine.state.ships[.orange]!.position = .init(court.halfWidth - 0.1, court.floorY + 0.1)
        engine.state.ball = BallState(position: .init(-court.halfWidth + 0.15, court.floorY + 0.1), velocity: .zero)
        var crossed = false
        for tick in UInt64(0) ..< 90 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            let ship = engine.state.ships[.cyan]!
            if ship.position.x > court.crossingLimit(atY: ship.position.y, astroball: AstroballTuning()) { crossed = true }
        }
        #expect(crossed, "the line should give")
        var ship = engine.state.ships[.cyan]!
        #expect(ship.position.x <= court.crossingLimit(atY: ship.position.y, astroball: AstroballTuning()), "not slung back: \(ship.position)")
        #expect(ship.velocity.x < 0, "the spring should throw it home")
        // Dropped over the net, below its top on the far side and falling:
        // it never reaches the far floor and comes back over to its own side.
        engine.state.ships[.cyan]!.position = .init(0.15, court.netTopY - 0.05)
        engine.state.ships[.cyan]!.velocity = .init(0, -1)
        var lowest = Double.infinity
        for tick in UInt64(90) ..< 330 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            let s = engine.state.ships[.cyan]!
            if s.position.x > 0 { lowest = min(lowest, s.position.y) }
        }
        ship = engine.state.ships[.cyan]!
        #expect(lowest > court.floorY + 0.15, "sank to \(lowest) on the far side")
        #expect(ship.position.x < 0, "still on the far side at \(ship.position)")
    }

    @Test("A ball that hits a hull again within the debounce is still one touch")
    func astroballDebounceIsLonger() {
        var engine = astroballEngine()
        let home = SIMD2(-0.4, 0.2)
        func drop() {
            engine.state.ball = BallState(position: home + SIMD2(0, 0.16), velocity: .init(0, -2))
        }
        func step(_ ticks: Int) {
            for _ in 0 ..< ticks {
                engine.state.ships[.cyan]!.position = home
                engine.state.ships[.cyan]!.velocity = .zero
                let tick = engine.state.tick
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            }
        }
        drop()
        var waited = 0
        while engine.state.match.shipTouches.cyan == 0, waited < 40 { step(1); waited += 1 }
        #expect(engine.state.match.shipTouches.cyan == 1)
        // Past the duel's tenth of a second, inside ASTROBALL's window.
        step(18)
        drop()
        step(8)
        #expect(engine.state.match.shipTouches.cyan == 1, "re-hit counted: \(engine.state.match.shipTouches.cyan)")
        #expect(engine.state.match.lastTouchRun == 1)
        // Long after, it is a second touch.
        step(40)
        drop()
        step(10)
        #expect(engine.state.match.shipTouches.cyan == 2)
    }

    @Test("The ring marks whose ball it is: the side under it, less a pilot whose run is spent")
    func upIsWhoseBall() {
        let tuning = AstroballTuning()
        var state = astroballEngine().state
        state.ships[.cyanWing] = state.ships[.cyan]
        state.ships[.orangeWing] = state.ships[.orange]
        state.ball.position = .init(-0.4, 0.2)
        #expect(state.astroballUp(tuning: tuning) == [.cyan, .cyanWing])
        state.ball.position = .init(0.4, 0.2)
        #expect(state.astroballUp(tuning: tuning) == [.orange, .orangeWing])
        state.sidesSwapped = true
        #expect(state.astroballUp(tuning: tuning) == [.cyan, .cyanWing], "ends changed: the right half is cyan's")
        state.sidesSwapped = false
        state.ball.position = .init(-0.4, 0.2)
        state.match.shipTouches.cyan = 2
        state.match.lastTouch = .cyan
        state.match.lastTouchRun = 2
        #expect(state.astroballUp(tuning: tuning) == [.cyanWing], "two in a row: only the partner may play it")
        state.match.shipTouches.cyan = 3
        #expect(state.astroballUp(tuning: tuning).isEmpty, "three spent: nobody on the side may play it")
        state.ships[.cyanWing]?.isDestroyed = true
        state.match.shipTouches.cyan = 0
        state.match.lastTouchRun = 1
        #expect(state.astroballUp(tuning: tuning) == [.cyan], "a downed partner is never up")
    }

    @Test("Each match draws two different side colours from all four")
    func huesAreDistinct() {
        var generator = SystemRandomNumberGenerator()
        var seen = Set<TeamHue>()
        for _ in 0 ..< 200 {
            let hues = TeamHues.random(using: &generator)
            #expect(hues.cyan != hues.orange)
            seen.insert(hues.cyan)
            seen.insert(hues.orange)
        }
        #expect(seen == Set(TeamHue.allCases))
        #expect(TeamHues()[.cyan] == .cyan && TeamHues()[.orange] == .orange, "the duel keeps cyan and orange")
        var tuning = AstroballTuning()
        tuning.hues = TeamHues(cyan: .green, orange: .pink)
        tuning.inARow = 3
        tuning.crossLean = 0.45
        tuning.floorBounce = 0.22
        let wire = try? JSONDecoder().decode(AstroballTuning.self, from: JSONEncoder().encode(tuning))
        #expect(wire?.hues == tuning.hues, "the host's colours ride the seating plan")
        #expect(wire?.inARow == 3 && wire?.crossLean == 0.45 && wire?.floorBounce == 0.22, "every host setting rides the wire")
    }

    @Test("ASTROBALL 2 V 2 puts one friend across the net and keeps both wings for bots")
    func twoASideOnline() throws {
        #expect(OnlineFormat.astroballDoubles.isAstroball)
        let plan = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:2"], format: .astroballDoubles)
        #expect(plan == ["G:1": .cyan, "G:2": .orange], "the friend is a rival, not a teammate")
        #expect(OnlineSeating.roster(filled: Set(plan.values), format: .astroballDoubles) == Seat.doubles,
                "both wings are seated, so each pilot gets a bot beside them")
        #expect(OnlineSeating.roster(filled: Set(plan.values), format: .astroball) == Seat.singles,
                "plain ASTROBALL with one friend stays a duel")
        #expect(OnlineSeating.lateSeat(filled: Set(plan.values), format: .astroballDoubles, ring: nil) == .cyanWing)
        let codec = WireCodec()
        let seating = WireEnvelope(sequence: 1, payload: .seating(plan: plan, tuning: FlightTuningSnapshot.defaults, format: .astroballDoubles))
        #expect(try codec.decode(codec.encode(seating)) == seating)
    }

    @Test("ASTROBALL team-up online: one friend flies on your side, two bots across")
    func teamUpOnline() throws {
        #expect(OnlineFormat.astroballTeamUp.isAstroball)
        let plan = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:2"], format: .astroballTeamUp)
        #expect(plan == ["G:1": .cyan, "G:2": .cyanWing], "the friend is a teammate")
        #expect(OnlineSeating.roster(filled: Set(plan.values), format: .astroballTeamUp) == Seat.doubles,
                "the far side is seated, so two bots fly against you")
        #expect(OnlineSeating.lateSeat(filled: Set(plan.values), format: .astroballTeamUp, ring: nil) == .orange)
        let codec = WireCodec()
        let seating = WireEnvelope(sequence: 1, payload: .seating(plan: plan, tuning: FlightTuningSnapshot.defaults, format: .astroballTeamUp))
        #expect(try codec.decode(codec.encode(seating)) == seating)
    }
}
