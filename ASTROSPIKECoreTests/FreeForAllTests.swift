import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Free-for-all: three or four pilots in a round arena, a net each standing
/// round the open middle with its mouth turned in, gravity out to the rim,
/// five lives, last pilot flying wins.
@Suite("Free-for-all")
struct FreeForAllTests {
    private func field(pilots: Int) -> (engine: SimulationEngine, arena: ArenaGeometry) {
        let configuration = SimulationConfiguration.online
        let arena = ArenaGeometry.freeForAll(pilots: pilots, ballRadius: configuration.ballRadius)
        var engine = SimulationEngine.testing()
        engine.updateConfiguration(configuration)
        engine.updateArena(arena)
        engine.configureFreeForAll(FreeForAllState.seats(pilots: pilots))
        engine.beginPlay()
        return (engine, arena)
    }

    /// Net `net`'s frame direction `local` in the world.
    private func worldVector(_ local: SIMD2<Double>, ring: RingField, net: Int) -> SIMD2<Double> {
        ring.toWorld(local, net: net) - ring.toWorld(.zero, net: net)
    }

    /// Drives the ball straight at net `net` -- into the mouth from the
    /// middle, or at the back from the rim side -- `across` off its centre
    /// line, and steps until the rally ends or a second has gone.
    private func shoot(
        _ engine: inout SimulationEngine,
        arena: ArenaGeometry,
        net: Int,
        fromBehind: Bool = false,
        across: Double = 0,
        speed: Double = 1.2
    ) -> [SimulationEvent] {
        let ring = arena.ring!
        let start = SIMD2(across, fromBehind ? -0.15 : ring.netDepth + 0.2)
        engine.state.ball = BallState(
            position: ring.toWorld(start, net: net),
            velocity: worldVector(SIMD2(0, fromBehind ? speed : -speed), ring: ring, net: net),
            radius: ring.ballRadius
        )
        engine.state.serveTicksRemaining = 0
        var events: [SimulationEvent] = []
        for _ in 0 ..< 120 {
            engine.step(inputs: [:])
            events += engine.lastEvents
            if engine.state.match.phase != .playing { break }
        }
        return events
    }

    private func livesLost(_ events: [SimulationEvent]) -> [Seat] {
        events.compactMap { if case let .lifeLost(seat, _, _) = $0 { seat } else { nil } }
    }

    @Test("The field is a ring: a net per pilot evenly round the open middle, mouths turned in, 0.6-0.8 of the radius in from the rim")
    func fieldLayout() {
        let ballRadius = SimulationConfiguration.online.ballRadius
        let biggestBall = BallState.nominalRadius * ArenaGeometry.maximumRadiusScale
        for pilots in [3, 4] {
            let arena = ArenaGeometry.freeForAll(pilots: pilots, ballRadius: ballRadius)
            let ring = arena.ring!
            #expect(arena.goalCount == pilots)
            #expect(abs(ring.spokeAngles[0] + .pi / 2) < 1e-9, "net 0 at the bottom")
            for (a, b) in zip(ring.spokeAngles, ring.spokeAngles.dropFirst()) {
                #expect(abs(b - a - 2 * .pi / Double(pilots)) < 1e-9, "evenly spaced")
            }
            let inFromRim = (ring.rimRadius - RingField.mouthRadius) / ring.rimRadius
            #expect((0.6 ... 0.8).contains(inFromRim), "mouths \(inFromRim) of the radius in from the rim")
            for net in ring.spokeAngles.indices {
                let point = SIMD2(0.3, -0.2)
                #expect(simd_length(ring.toLocal(ring.toWorld(point, net: net), net: net) - point) < 1e-9)
                #expect(abs(simd_length(ring.mouthCentre(net)) - RingField.mouthRadius) < 1e-9)
                #expect(ring.toLocal(.zero, net: net).y > ring.netDepth, "the middle is in front of every mouth")
                #expect(ring.spokeIndex(nearest: ring.mouthCentre(net)) == net)
            }
            // The biggest ball still fits between neighbouring nets, and
            // between a net's back and the fins and rim behind it.
            let big = RingField(pilots: pilots, ballRadius: biggestBall)
            func gap(_ a: ArenaObstacle, _ b: ArenaObstacle) -> Double {
                let samples = (0 ... 20).map { Double($0) / 20 }
                return samples.flatMap { s in
                    samples.map { t in
                        simd_distance(a.start + (a.end - a.start) * s, b.start + (b.end - b.start) * t)
                    }
                }.min()! - a.radius - b.radius
            }
            for net in big.spokeAngles.indices {
                let next = (net + 1) % pilots
                let between = gap(big.posts[2 * net + 1], big.posts[2 * next])
                #expect(between > 2 * biggestBall, "\(pilots) pilots: \(between) between nets \(net) and \(next)")
            }
            #expect(big.rimRadius - RingField.finHeight - big.netBackRadius > 2 * biggestBall, "room behind the nets")
        }
        #expect(ArenaGeometry.standard.ring == nil, "the duel court stays a rectangle")
    }

    @Test("Gravity pulls out to the rim: a ball let go behind any net lands on the rim behind it")
    func gravityPullsOut() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let ring = arena.ring!
            for net in ring.spokeAngles.indices {
                var engine = start
                for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                engine.state.ball = BallState(position: ring.toWorld(SIMD2(0, -0.1), net: net), velocity: .zero, radius: ring.ballRadius)
                engine.state.serveTicksRemaining = 0
                // Gravity is light by default and the rim gives most of a
                // bounce back, so the ball takes about a minute to settle.
                var events: [SimulationEvent] = []
                for _ in 0 ..< 120 * 60 {
                    engine.step(inputs: [:])
                    events += engine.lastEvents
                }
                let ball = engine.state.ball.position
                #expect(livesLost(events).isEmpty)
                #expect(abs(simd_length(ball) - (ring.rimRadius - ring.ballRadius)) < 0.01, "\(pilots) pilots, net \(net)")
                #expect(ring.spokeIndex(nearest: ball) == net, "straight out behind its net")
            }
        }
    }

    @Test("Ring gravity is spin gravity: it grows with the distance out, the Ring gravity share of the duel's at the rim, and the setting scales it")
    func gravityGrowsOutward() {
        let (start, arena) = field(pilots: 4)
        let ring = arena.ring!
        #expect(start.configuration.ringGravity == SimulationConfiguration.ringGravityDefault)
        #expect(SimulationConfiguration.ringGravityDefault == 0.3)
        func pull(at radius: Double, bearing: Double, setting: Double? = nil) -> Double {
            let out = SIMD2(cos(bearing), sin(bearing))
            var engine = start
            for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
            if let setting {
                var configuration = engine.configuration
                configuration.ringGravity = setting
                engine.updateConfiguration(configuration)
            }
            engine.state.ball = BallState(position: out * radius, velocity: .zero)
            engine.state.serveTicksRemaining = 0
            engine.step(inputs: [:])
            return simd_dot(engine.state.ball.velocity, out)
        }
        // Down a fin's line, clear of every net; the rim spot is between a
        // fin and a net, clear of both.
        let fin = ring.finBearings[0]
        let near = pull(at: 0.4, bearing: fin), far = pull(at: 0.8, bearing: fin)
        #expect(near > 0)
        #expect(abs(far / near - 2) < 0.02, "twice as far out pulls twice as hard: \(far / near)")
        let duel = simd_length(start.configuration.gravity) * start.configuration.ballGravityMultiplier
            * start.configuration.stepDuration
        let rimSpot = ring.rimRadius - ring.ballRadius - 0.01
        let rimPull = pull(at: rimSpot, bearing: (ring.spokeAngles[0] + fin) / 2)
        #expect(abs(rimPull / (0.3 * duel * rimSpot / ring.rimRadius) - 1) < 0.02, "the default share of the duel's weight at the rim")
        #expect(abs(pull(at: 0.8, bearing: fin, setting: 0.15) / far - 0.5) < 0.02, "the setting scales it")
    }

    @Test("Three pilots take the ends and one wing; four take every seat; everyone starts behind their own net, facing in")
    func seats() {
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 3)).bays == [.cyan, .cyanWing, .orange])
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 4)).bays == [.cyan, .cyanWing, .orangeWing, .orange])
        let (engine, arena) = field(pilots: 4)
        let ring = arena.ring!
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() {
            let ship = engine.state.ships[seat]!
            let local = ring.toLocal(ship.position, net: bay)
            #expect(local.y < 0 && abs(local.x) < 1e-9, "\(seat) starts behind its own net")
            #expect(simd_length(ship.position) < ring.rimRadius)
            #expect(cos(ship.angle - ring.spokeAngles[bay] - .pi) > 0.999, "\(seat) points in at the middle")
            #expect(engine.state.freeForAll!.lives[seat] == FreeForAllState.startingLives)
        }
    }

    @Test("A ball into a mouth costs the net's owner one life, and the ball is served again")
    func mouthCostsALife() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let bays = start.state.freeForAll!.bays
            for net in 0 ..< arena.goalCount {
                for across in [-0.06, 0, 0.06] {
                    var engine = start
                    let events = shoot(&engine, arena: arena, net: net, across: across)
                    #expect(livesLost(events) == [bays[net]], "\(pilots) pilots, net \(net), \(across) across")
                    #expect(engine.state.freeForAll!.lives[bays[net]] == FreeForAllState.startingLives - 1)
                    #expect(engine.state.match.phase == .serve)
                    #expect(engine.state.freeForAll!.serveBay == net, "served beside the net that conceded")
                }
            }
        }
    }

    /// The slow ones are the case the rule is for: at 0.09-0.10 the ball
    /// climbs past the goal line from behind, stalls short of the mouth and
    /// falls back across the line the way a shot comes in.
    @Test("A ball through the back of a net never scores: it rolls out the mouth or drops back out the back")
    func backDoorNeverScores() {
        var fellBackAcross = 0
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let ring = arena.ring!
            for net in ring.spokeAngles.indices {
                for speed in [0.07, 0.09, 0.10, 0.3, 1.0, 2.4] {
                    for across in [-0.06, 0, 0.06] {
                        var engine = start
                        for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                        let from = ring.toWorld(SIMD2(across, -0.15), net: net)
                        engine.state.ball = BallState(
                            position: from,
                            velocity: worldVector(SIMD2(0, speed), ring: ring, net: net),
                            radius: ring.ballRadius
                        )
                        engine.state.serveTicksRemaining = 0
                        var entered = false
                        var crested = false
                        var events: [SimulationEvent] = []
                        // The slowest hang in the light middle for up to
                        // 22 seconds before they drop back out.
                        for _ in 0 ..< 120 * 40 {
                            engine.step(inputs: [:])
                            events += engine.lastEvents
                            let ball = engine.state.ball.position
                            if ring.backPocket(holding: ball) == net { entered = true }
                            if ring.toLocal(ball, net: net).y > ring.goalLineY { crested = true }
                            if entered, ring.isClear(of: net, ball) { break }
                        }
                        if crested, ring.toLocal(engine.state.ball.position, net: net).y < 0 { fellBackAcross += 1 }
                        #expect(entered, "\(pilots) pilots, net \(net), speed \(speed): came in the back")
                        #expect(livesLost(events).isEmpty, "\(pilots) pilots, net \(net), speed \(speed), \(across) across")
                        #expect(ring.isClear(of: net, engine.state.ball.position), "left the net again")
                    }
                }
            }
        }
        #expect(fellBackAcross > 0, "some balls crossed the goal line from behind and fell back out")
    }

    @Test("A knocked-out pilot's net is shut: the ball bounces off its mouth and its back")
    func solidNet() {
        let (start, arena) = field(pilots: 3)
        let ring = arena.ring!
        for fromBehind in [false, true] {
            var engine = start
            engine.state.freeForAll!.lives[.cyanWing] = 0
            engine.state.ships[.cyanWing] = nil
            var pocketed = false
            let events = shoot(&engine, arena: arena, net: 1, fromBehind: fromBehind)
            #expect(livesLost(events).isEmpty)
            #expect(engine.state.match.phase == .playing)
            for _ in 0 ..< 60 {
                engine.step(inputs: [:])
                if ring.backPocket(holding: engine.state.ball.position) == 1 { pocketed = true }
            }
            #expect(!pocketed, "never inside")
            let local = ring.toLocal(engine.state.ball.position, net: 1)
            #expect(fromBehind ? local.y < 0 : local.y > ring.netDepth, "came back off the \(fromBehind ? "back" : "mouth")")
        }
    }

    @Test("Hulls fly through a live net, front or back, and a knocked-out pilot's net stops them")
    func shipsFlyThroughLiveNets() {
        for knockedOut in [false, true] {
            for fromBehind in [true, false] {
                var (engine, arena) = field(pilots: 4)
                let ring = arena.ring!
                let owner = engine.state.freeForAll!.bays[0]
                if knockedOut {
                    engine.state.freeForAll!.lives[owner] = 0
                    engine.state.ships[owner] = nil
                }
                let seat = engine.state.freeForAll!.bays[2]
                for other in Array(engine.state.ships.keys) where other != seat { engine.state.ships[other] = nil }
                engine.state.ball.position = SIMD2(0.9, 0.9)
                engine.state.ball.velocity = .zero
                engine.state.serveTicksRemaining = 0
                let start = ring.toWorld(SIMD2(0, fromBehind ? -0.15 : ring.netDepth + 0.2), net: 0)
                let target = ring.toWorld(SIMD2(0, fromBehind ? ring.netDepth + 0.2 : -0.15), net: 0)
                engine.state.ships[seat]!.position = start
                engine.state.ships[seat]!.velocity = simd_normalize(target - start) * 1.2
                var furthest = -Double.infinity
                for _ in 0 ..< 60 {
                    engine.step(inputs: [:])
                    let y = ring.toLocal(engine.state.ships[seat]!.position, net: 0).y
                    furthest = max(furthest, fromBehind ? y : -y)
                }
                let through = furthest >= (fromBehind ? ring.netDepth + 0.1 : 0.05)
                #expect(through == !knockedOut, "knocked out \(knockedOut), from behind \(fromBehind): got to \(furthest)")
            }
        }
    }

    @Test("The face-off drops in the middle and drifts out a gap: untouched, it never scores")
    func faceOffNeverScoresUntouched() {
        for pilots in [3, 4] {
            for bay in 0 ..< pilots {
                for delay in [0, 7, 19] {
                    var (engine, _) = field(pilots: pilots)
                    for _ in 0 ..< delay { engine.step(inputs: [:]) }
                    engine.state.freeForAll!.serveBay = bay
                    engine.prepareNextRally(mirrored: false)
                    engine.beginPlay()
                    for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                    #expect(simd_length(engine.state.ball.position) < 0.1, "dropped in the middle")
                    var events: [SimulationEvent] = []
                    for _ in 0 ..< 120 * 30 {
                        engine.step(inputs: [:])
                        events += engine.lastEvents
                    }
                    #expect(livesLost(events).isEmpty, "\(pilots) pilots, serve \(bay), delay \(delay)")
                }
            }
        }
    }

    @Test("The last life knocks a pilot out; the next serve goes beside the nearest net still open")
    func knockout() {
        var (engine, arena) = field(pilots: 4)
        engine.state.freeForAll!.lives[.cyan] = 1
        let events = shoot(&engine, arena: arena, net: 0)
        #expect(events.contains { if case .pilotOut(.cyan) = $0 { true } else { false } })
        #expect(engine.state.ships[.cyan] == nil, "the ship leaves the field")
        #expect(engine.state.match.phase == .serve)
        #expect(engine.state.freeForAll!.serveBay == 1)
        #expect(engine.state.freeForAll!.isSolid(goal: 0))
        #expect(engine.state.freeForAll!.winner == nil)
    }

    @Test("The last pilot flying wins, and Play Again brings everyone back on full lives")
    func lastPilotStandingAndRestart() {
        var (engine, arena) = field(pilots: 3)
        engine.state.freeForAll!.lives[.cyan] = 1
        engine.state.freeForAll!.lives[.cyanWing] = 0
        engine.state.ships[.cyanWing] = nil
        let events = shoot(&engine, arena: arena, net: 0)
        #expect(events.contains { if case .lastPilotStanding(.orange) = $0 { true } else { false } })
        #expect(engine.state.match.phase == .finished)
        #expect(engine.state.freeForAll!.winner == .orange)
        #expect(Set(engine.state.ships.keys) == [.orange])

        engine.restartMatch()
        engine.beginPlay()
        let field = engine.state.freeForAll!
        #expect(Set(engine.state.ships.keys) == [.cyan, .cyanWing, .orange])
        #expect(field.lives.values.allSatisfy { $0 == FreeForAllState.startingLives })
        #expect(field.winner == nil)
        #expect(engine.state.match.phase == .playing)
    }

    @Test("Restart drop from the pause menu keeps the field: nobody comes back, everyone behind their own net, the ball in the middle")
    func restartDropKeepsTheField() {
        var (engine, arena) = field(pilots: 4)
        let ring = arena.ring!
        engine.state.freeForAll!.lives[.cyan] = 1
        _ = shoot(&engine, arena: arena, net: 0)
        let lives = engine.state.freeForAll!.lives
        engine.prepareNextRally(mirrored: false)
        #expect(Set(engine.state.ships.keys) == [.cyanWing, .orangeWing, .orange], "the knocked-out pilot stays out")
        #expect(engine.state.freeForAll!.lives == lives)
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() where seat != .cyan {
            #expect(ring.toLocal(engine.state.ships[seat]!.position, net: bay).y < 0, "\(seat) behind its own net")
        }
        #expect(simd_length(engine.state.ball.position) < 0.1, "the face-off is in the middle")
    }

    @Test("Every other hull is a rival: a lead's bolt hits the seat that is its wing in doubles")
    func boltHitsFormerTeammate() {
        var (engine, arena) = field(pilots: 3)
        let wing = engine.state.ships[.cyanWing]!
        // Fired straight out at the wing from the middle side, the ball
        // across the ring out of the way.
        let out = arena.ring!.outward(at: wing.position)
        engine.state.ball.position = -out * 1.0
        engine.state.ball.velocity = .zero
        engine.state.bolts = [BoltState(id: 900, owner: .cyan, seat: .cyan, position: wing.position - out * 0.15,
                                        velocity: out * 2.6, ticksRemaining: 60)]
        var events: [SimulationEvent] = []
        for _ in 0 ..< 10 {
            engine.step(inputs: [:])
            events += engine.lastEvents
        }
        #expect(events.contains { if case .shipZapped(.cyanWing, _) = $0 { true } else { false } })
        #expect(engine.state.bolts.isEmpty, "the bolt dies on the hull")
    }

    @Test("A duel never carries a free-for-all book")
    func duelHasNoBook() throws {
        let engine = SimulationEngine.testing()
        #expect(engine.state.freeForAll == nil)
        #expect(!engine.isFreeForAll)
        let data = try JSONEncoder().encode(engine.state)
        #expect(!String(decoding: data, as: UTF8.self).contains("freeForAll"))
    }

    /// The bot is chaotic, so judge it over several starts rather than one:
    /// ten two-minute games alone against idle hulls (the step is 1/120 s).
    /// Over 80-minute samples it takes about 25 rival lives in 20 minutes and
    /// gives up 12 at three pilots, and takes 44 and gives up 9 at four; the
    /// floors sit about 30% under those, and an idle bot takes none -- an
    /// untouched face-off never scores.
    @Test("The bot takes rivals' lives more often than it gives up its own", arguments: [3, 4])
    func botScores(pilots: Int) {
        var rival = 0
        var own = 0
        for offset in [0, 37, 91, 150, 233, 311, 389, 467, 541, 613] {
            var (engine, arena) = field(pilots: pilots)
            for _ in 0 ..< offset { engine.step(inputs: [:]) }
            var bot = FreeForAllPilot(difficulty: .ace, configuration: .online)
            for _ in 0 ..< 120 * 120 {
                let input = bot.input(for: engine.state, seat: .cyanWing, arena: arena, tick: engine.state.tick)
                engine.step(inputs: [.cyanWing: input])
                for case let .lifeLost(seat, _, _) in engine.lastEvents {
                    if seat == .cyanWing { own += 1 } else { rival += 1 }
                }
                if engine.state.match.phase == .finished { break }
            }
        }
        #expect(rival >= (pilots == 3 ? 17 : 30), "only \(rival) rival lives in 20 minutes")
        #expect(Double(rival) > 1.3 * Double(own), "rival \(rival), own \(own)")
    }
}
