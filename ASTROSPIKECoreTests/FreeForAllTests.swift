import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Free-for-all: three or four pilots on a round air-hockey table, a net
/// each standing in from the rim with its mouth turned out to it, banked
/// goals, a MAX CROSS line round every pilot's ground, five lives, last
/// pilot flying wins.
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

    /// Drives the ball straight into net `net`'s mouth from the lane between
    /// it and the rim, `across` off its centre line, and steps until the rally ends or a
    /// second has gone.
    private func shoot(
        _ engine: inout SimulationEngine,
        arena: ArenaGeometry,
        net: Int,
        across: Double = 0,
        speed: Double = 1.2
    ) -> [SimulationEvent] {
        let ring = arena.ring!
        let start = SIMD2(across, ring.netDepth + 0.2)
        engine.state.ball = BallState(
            position: ring.toWorld(start, net: net),
            velocity: worldVector(SIMD2(0, -speed), ring: ring, net: net),
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

    @Test("The field is a ring: a net per pilot evenly round it, standing in from the rim with the mouth turned out to it, the fins clear between them")
    func fieldLayout() {
        let ballRadius = SimulationConfiguration.online.ballRadius
        let smallestBall = BallState.nominalRadius
        let biggestBall = BallState.nominalRadius * ArenaGeometry.maximumRadiusScale
        for pilots in [3, 4] {
            let arena = ArenaGeometry.freeForAll(pilots: pilots, ballRadius: ballRadius)
            let ring = arena.ring!
            #expect(arena.goalCount == pilots)
            #expect(abs(ring.spokeAngles[0] + .pi / 2) < 1e-9, "net 0 at the bottom")
            for (a, b) in zip(ring.spokeAngles, ring.spokeAngles.dropFirst()) {
                #expect(abs(b - a - 2 * .pi / Double(pilots)) < 1e-9, "evenly spaced")
            }
            for net in ring.spokeAngles.indices {
                let point = SIMD2(0.3, -0.2)
                #expect(simd_length(ring.toLocal(ring.toWorld(point, net: net), net: net) - point) < 1e-9)
                #expect(abs(simd_length(ring.mouthCentre(net)) - ring.mouthRadius) < 1e-9)
                #expect(ring.toLocal(.zero, net: net).y < 0, "the middle is behind every net")
                #expect(ring.rimLineY > ring.netDepth, "the mouth faces the rim")
                #expect(ring.spokeIndex(nearest: ring.mouthCentre(net)) == net)
            }
            // Every ball size: a wide lane between every mouth and the rim
            // for a banked ball to come back through; the nets pulled well
            // in from the rim but clear of the middle, and the MAX CROSS
            // line well short of them.
            for radius in [smallestBall, ballRadius, biggestBall] {
                let sized = RingField(pilots: pilots, ballRadius: radius)
                let lane = sized.rimRadius - sized.mouthRadius
                #expect(lane > 2 * radius + 0.3, "\(pilots) pilots, ball \(radius): \(lane) between mouth and rim")
                #expect(sized.mouthRadius < 0.72 * sized.rimRadius, "\(pilots) pilots, ball \(radius): mouth at \(sized.mouthRadius)")
                #expect(sized.netBackRadius > 0.3, "\(pilots) pilots, ball \(radius): back at \(sized.netBackRadius)")
                #expect(sized.netBackRadius - sized.maxCrossRadius > 0.15, "\(pilots) pilots, ball \(radius): line at \(sized.maxCrossRadius)")
            }
            // The biggest ball and a hull still pass between a net and the
            // fin beside it.
            let big = RingField(pilots: pilots, ballRadius: biggestBall)
            func gap(_ a: ArenaObstacle, _ b: ArenaObstacle) -> Double {
                let samples = (0 ... 20).map { Double($0) / 20 }
                return samples.flatMap { s in
                    samples.map { t in
                        simd_distance(a.start + (a.end - a.start) * s, b.start + (b.end - b.start) * t)
                    }
                }.min()! - a.radius - b.radius
            }
            let frames = big.posts + big.backs.flatMap { $0 } + big.spokeAngles.indices.map(big.mouthBar)
            let clearance = frames.flatMap { frame in big.fins.map { gap(frame, $0) } }.min()!
            #expect(clearance > 2 * biggestBall + 0.1, "\(pilots) pilots: \(clearance) between a net and a fin")
        }
        #expect(ArenaGeometry.standard.ring == nil, "the duel court stays a rectangle")
    }

    @Test("The table is flat by default: a ball let go stays put; tilt it with Ring gravity and the ball rolls out to the rim")
    func gravityPullsOut() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let ring = arena.ring!
            #expect(start.configuration.ring.gravity == 0)
            for setting in [0.0, 0.3] {
                for net in ring.spokeAngles.indices {
                    var engine = start
                    var configuration = engine.configuration
                    configuration.ring.gravity = setting
                    engine.updateConfiguration(configuration)
                    for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                    // Out between a net and the fin beside it, clear of both.
                    let bearing = ring.spokeAngles[net] + .pi / Double(2 * pilots)
                    let from = SIMD2(cos(bearing), sin(bearing)) * 0.6
                    engine.state.ball = BallState(position: from, velocity: .zero, radius: ring.ballRadius)
                    engine.state.serveTicksRemaining = 0
                    var events: [SimulationEvent] = []
                    for _ in 0 ..< 120 * 60 {
                        engine.step(inputs: [:])
                        events += engine.lastEvents
                    }
                    let ball = engine.state.ball.position
                    #expect(livesLost(events).isEmpty)
                    if setting == 0 {
                        #expect(simd_distance(ball, from) < 1e-9, "\(pilots) pilots, net \(net): flat")
                    } else {
                        #expect(abs(simd_length(ball) - (ring.rimRadius - ring.ballRadius)) < 0.01, "\(pilots) pilots, net \(net)")
                        #expect(abs(remainder(atan2(ball.y, ball.x) - bearing, 2 * .pi)) < 0.05, "straight out")
                    }
                }
            }
        }
    }

    @Test("Ring gravity is spin gravity: it grows with the distance out, the Ring gravity share of the duel's at the rim, and the setting scales it")
    func gravityGrowsOutward() {
        let (start, arena) = field(pilots: 4)
        let ring = arena.ring!
        #expect(RingTuning().gravity == 0, "flat, like an air-hockey table")
        #expect(RingTuning.knobs.first { $0.keyPath == \RingTuning.gravity }!.range.lowerBound == 0)
        func pull(at radius: Double, bearing: Double, setting: Double = 0.3) -> Double {
            let out = SIMD2(cos(bearing), sin(bearing))
            var engine = start
            for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
            var configuration = engine.configuration
            configuration.ring.gravity = setting
            engine.updateConfiguration(configuration)
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
        #expect(abs(rimPull / (0.3 * duel * rimSpot / ring.rimRadius) - 1) < 0.02, "the setting's share of the duel's weight at the rim")
        #expect(abs(pull(at: 0.8, bearing: fin, setting: 0.15) / far - 0.5) < 0.02, "the setting scales it")
    }

    @Test("Three pilots take the ends and one wing; four take every seat; everyone starts beside their own net, level with its back, facing in")
    func seats() {
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 3)).bays == [.cyan, .cyanWing, .orange])
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 4)).bays == [.cyan, .cyanWing, .orangeWing, .orange])
        let (engine, arena) = field(pilots: 4)
        let ring = arena.ring!
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() {
            let ship = engine.state.ships[seat]!
            let local = ring.toLocal(ship.position, net: bay)
            #expect(local.x > ring.netHalfWidth + 0.1 && abs(local.y) < 1e-9, "\(seat) starts beside its own net")
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

    @Test("A ring hull flies like slow-motion air hockey: held thrust builds speed along 1 - e^(-kt) toward a top speed, and let go it glides to a stop")
    func airHockeyFlight() {
        var (engine, _) = field(pilots: 4)
        let seat = engine.state.freeForAll!.bays[0]
        for other in Array(engine.state.ships.keys) where other != seat { engine.state.ships[other] = nil }
        // The side pilots are out, so their ground is open and no MAX CROSS
        // line bends the run.
        for bay in [1, 3] { engine.state.freeForAll!.lives[engine.state.freeForAll!.bays[bay]] = 0 }
        engine.state.ball = BallState(position: SIMD2(0, 1.0), velocity: .zero, radius: engine.configuration.ballRadius)
        engine.state.serveTicksRemaining = 0
        // Straight across, below the side nets, from near the left of the rim.
        engine.state.ships[seat]!.position = SIMD2(-1.3, -0.4)
        engine.state.ships[seat]!.velocity = .zero
        engine.state.ships[seat]!.angle = 0
        // The law holds at any setting; these keep the run inside the ring.
        var configuration = engine.configuration
        configuration.ring.speed = 0.3
        configuration.ring.hullDrag = 0.5
        engine.updateConfiguration(configuration)
        let top = engine.configuration.ringTopSpeed
        let k = configuration.ring.hullDrag
        func fly(_ seconds: Double, thrust: Bool) -> Double {
            for _ in 0 ..< Int(seconds * 120) {
                engine.step(inputs: [seat: PlayerInput(tick: engine.state.tick, torque: 0, thrust: thrust)])
            }
            return simd_length(engine.state.ships[seat]!.velocity)
        }
        let oneSecond = fly(1, thrust: true)
        #expect(abs(oneSecond / (top * (1 - exp(-k))) - 1) < 0.02, "one second in: \(oneSecond)")
        let released = fly(0.5, thrust: true)
        #expect(abs(released / (top * (1 - exp(-1.5 * k))) - 1) < 0.02, "a second and a half in: \(released)")
        let coasting = fly(3, thrust: false)
        #expect(abs(coasting / (released * exp(-3 * k)) - 1) < 0.02, "three seconds' glide: \(coasting)")
    }

    /// A live net is only netting: the ball flows through its back and its
    /// sides untouched. Run out through it from the middle, it crosses the
    /// goal line going the wrong way, which does not count -- but straight
    /// down the net's line it comes back off the rim, in the mouth, and that
    /// is a goal: the bank shot.
    @Test("A live net is see-through: in its back and out its mouth, or in one side and out the other, the ball never bends; run straight out it banks off the rim back into the mouth and scores")
    func netIsSeeThrough() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let ring = arena.ring!
            for net in ring.spokeAngles.indices {
                let owner = start.state.freeForAll!.bays[net]
                for across in [-0.08, 0.0, 0.08] {
                    for speed in [0.6, 1.4] {
                        var engine = start
                        for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                        let velocity = worldVector(SIMD2(0, speed), ring: ring, net: net)
                        engine.state.ball = BallState(position: ring.toWorld(SIMD2(across, -0.15), net: net), velocity: velocity, radius: ring.ballRadius)
                        engine.state.serveTicksRemaining = 0
                        var events: [SimulationEvent] = []
                        // Out through the back and the mouth, short of the rim.
                        for _ in 0 ..< 120 * 2 where ring.toLocal(engine.state.ball.position, net: net).y < ring.netDepth + ring.ballRadius {
                            engine.step(inputs: [:])
                            events += engine.lastEvents
                        }
                        #expect(livesLost(events).isEmpty, "\(pilots) pilots, net \(net): out the mouth is no goal")
                        #expect(simd_distance(simd_normalize(engine.state.ball.velocity), simd_normalize(velocity)) < 1e-6, "\(pilots) pilots, net \(net): bent going through")
                        for _ in 0 ..< 120 * 6 where engine.state.match.phase == .playing {
                            engine.step(inputs: [:])
                            events += engine.lastEvents
                        }
                        #expect(livesLost(events) == [owner], "\(pilots) pilots, net \(net), \(across) across, speed \(speed): banked back in")
                    }
                }
                // In one side and out the other, both ways, below the goal
                // line and across it.
                for side in [1.0, -1.0] {
                    for depth in [0.3, 0.9] {
                        var engine = start
                        for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                        let wide = ring.netHalfWidth + ring.ballRadius + 0.05
                        let velocity = worldVector(SIMD2(-side * 1.0, 0), ring: ring, net: net)
                        engine.state.ball = BallState(position: ring.toWorld(SIMD2(side * wide, ring.netDepth * depth), net: net), velocity: velocity, radius: ring.ballRadius)
                        engine.state.serveTicksRemaining = 0
                        var events: [SimulationEvent] = []
                        for _ in 0 ..< 120 * 2 where side * ring.toLocal(engine.state.ball.position, net: net).x > -wide {
                            engine.step(inputs: [:])
                            events += engine.lastEvents
                        }
                        #expect(livesLost(events).isEmpty, "\(pilots) pilots, net \(net), side \(side), depth \(depth)")
                        #expect(simd_distance(simd_normalize(engine.state.ball.velocity), simd_normalize(velocity)) < 1e-6, "\(pilots) pilots, net \(net): bent crossing")
                    }
                }
            }
        }
    }

    @Test("A knocked-out pilot's net is shut all round: the ball bounces off its mouth and off its back")
    func solidNet() {
        let (start, arena) = field(pilots: 3)
        let ring = arena.ring!
        var engine = start
        engine.state.freeForAll!.lives[.cyanWing] = 0
        engine.state.ships[.cyanWing] = nil
        let events = shoot(&engine, arena: arena, net: 1)
        #expect(livesLost(events).isEmpty)
        #expect(engine.state.match.phase == .playing)
        #expect(ring.toLocal(engine.state.ball.position, net: 1).y > ring.netDepth, "came back off the mouth")

        engine = start
        engine.state.freeForAll!.lives[.cyanWing] = 0
        for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
        engine.state.ball = BallState(position: ring.toWorld(SIMD2(0, -0.2), net: 1), velocity: worldVector(SIMD2(0, 1.0), ring: ring, net: 1), radius: ring.ballRadius)
        engine.state.serveTicksRemaining = 0
        for _ in 0 ..< 60 { engine.step(inputs: [:]) }
        #expect(ring.toLocal(engine.state.ball.position, net: 1).y < 0, "came back off the back")
    }

    @Test("Hulls fly through a live net, in the mouth or across it, and a knocked-out pilot's net stops them")
    func shipsFlyThroughLiveNets() {
        for knockedOut in [false, true] {
            for intoMouth in [true, false] {
                var (engine, arena) = field(pilots: 4)
                let ring = arena.ring!
                let owner = engine.state.freeForAll!.bays[0]
                if knockedOut {
                    engine.state.freeForAll!.lives[owner] = 0
                    engine.state.ships[owner] = nil
                }
                // A live net's own pilot flies it (a rival would be shoved
                // back at the MAX CROSS line first); a knocked-out net's
                // ground is open, so a rival tries that one.
                let seat = knockedOut ? engine.state.freeForAll!.bays[2] : owner
                for other in Array(engine.state.ships.keys) where other != seat { engine.state.ships[other] = nil }
                engine.state.ball.position = SIMD2(0.3, 0.3)
                engine.state.ball.velocity = .zero
                engine.state.serveTicksRemaining = 0
                // In the mouth and on toward the back, or in one side and
                // out the other.
                let wide = ring.netHalfWidth + 0.2
                let start = ring.toWorld(intoMouth ? SIMD2(0, ring.netDepth + 0.25) : SIMD2(-wide, ring.netDepth * 0.5), net: 0)
                let target = ring.toWorld(intoMouth ? SIMD2(0, 0.05) : SIMD2(wide, ring.netDepth * 0.5), net: 0)
                engine.state.ships[seat]!.position = start
                engine.state.ships[seat]!.velocity = simd_normalize(target - start) * 1.2
                var furthest = -Double.infinity
                for _ in 0 ..< 120 {
                    engine.step(inputs: [:])
                    let local = ring.toLocal(engine.state.ships[seat]!.position, net: 0)
                    furthest = max(furthest, intoMouth ? -local.y : local.x)
                }
                let through = furthest >= (intoMouth ? -ring.netDepth * 0.5 : ring.netHalfWidth)
                #expect(through == !knockedOut, "knocked out \(knockedOut), into the mouth \(intoMouth): got to \(furthest)")
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

    @Test("Restart drop from the pause menu keeps the field: nobody comes back, everyone beside their own net, the ball in the middle")
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
            #expect(ring.toLocal(engine.state.ships[seat]!.position, net: bay).x > ring.netHalfWidth, "\(seat) beside its own net")
        }
        #expect(simd_length(engine.state.ball.position) < 0.1, "the face-off is in the middle")
    }

    @Test("Every other hull is a rival: a lead's bolt hits the seat that is its wing in doubles")
    func boltHitsFormerTeammate() {
        var (engine, arena) = field(pilots: 3)
        // Out in the open middle, short of its own zone.
        let home = arena.ring!.spokeAngles[engine.state.freeForAll!.bay(of: .cyanWing)!]
        engine.state.ships[.cyanWing]!.position = RingField.outward(home) * arena.ring!.maxCrossRadius * 0.6
        let wing = engine.state.ships[.cyanWing]!
        #expect(!engine.ringInOwnZone(wing.position, seat: .cyanWing))
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

    @Test("Home in its own zone, past its MAX CROSS line, a hull is impervious: an enemy bolt breaks on it without a shove, a stun or a zap")
    func zoneIsBoltproof() {
        for boltHit in BoltHit.allCases {
            var (engine, arena) = field(pilots: 3)
            let ring = arena.ring!
            var configuration = engine.configuration
            configuration.boltHit = boltHit
            engine.updateConfiguration(configuration)
            let bay = engine.state.freeForAll!.bay(of: .cyanWing)!
            let home = RingField.outward(ring.spokeAngles[bay]) * (ring.maxCrossRadius + 0.15)
            engine.state.ships[.cyanWing]!.position = home
            engine.state.ships[.cyanWing]!.velocity = .zero
            #expect(engine.ringInOwnZone(home, seat: .cyanWing))
            let out = ring.outward(at: home)
            engine.state.ball.position = -out * 1.0
            engine.state.ball.velocity = .zero
            engine.state.bolts = [BoltState(id: 900, owner: .cyan, seat: .cyan, position: home - out * 0.15,
                                            velocity: out * 2.6, ticksRemaining: 60)]
            var events: [SimulationEvent] = []
            for _ in 0 ..< 10 {
                engine.step(inputs: [:])
                events += engine.lastEvents
            }
            let ship = engine.state.ships[.cyanWing]!
            #expect(!events.contains { if case .shipZapped = $0 { true } else { false } }, "\(boltHit)")
            #expect(events.contains { if case .collisionEffect = $0 { true } else { false } }, "it sparks where it breaks")
            #expect(engine.state.bolts.isEmpty, "the bolt breaks on the hull, not through it")
            #expect(ship.stunTicks == 0 && ship.knockSpin == 0)
            #expect(simd_length(ship.velocity) < 0.01, "\(boltHit): no shove")
        }
    }

    @Test("The ring sliders reach the field: the line and the nets move with them, a slack line lets a rival through, and stored settings clamp to their sliders")
    func ringTuning() {
        var tuning = RingTuning()
        let ballRadius = SimulationConfiguration.online.ballRadius
        let base = RingField(pilots: 4, ballRadius: ballRadius)
        tuning.lineShare = 0.9
        tuning.rimRoom = 0.53
        let moved = RingField(pilots: 4, ballRadius: ballRadius, tuning: tuning)
        #expect(abs(moved.maxCrossRadius / moved.netBackRadius - 0.9) < 1e-9)
        #expect(abs(moved.rimGap - base.rimGap - 0.13) < 1e-9)
        #expect(abs(base.netBackRadius - moved.netBackRadius - 0.13) < 1e-9, "the nets move in with the room")

        // No push and no brake: a rival flies straight up to the mouth.
        var (engine, arena) = field(pilots: 3)
        var configuration = engine.configuration
        configuration.ring.linePush = 0
        configuration.ring.lineBrake = 0
        engine.updateConfiguration(configuration)
        let slack = run(&engine, seat: engine.state.freeForAll!.bays[1], from: .zero, at: arena.ring!.mouthCentre(0))
        #expect(slack.nearest < 0.1, "\(slack.nearest) from the mouth")

        let defaults = UserDefaults(suiteName: "ringTuning-\(UUID())")!
        #expect(RingTuning.stored(in: defaults) == RingTuning())
        defaults.set(99.0, forKey: "ring.linePush")
        defaults.set(0.25, forKey: "ringGravity")
        var stored = RingTuning.stored(in: defaults)
        #expect(stored.linePush == 30, "clamped to the slider")
        #expect(stored.gravity == 0.25, "Ring gravity keeps its old key")
        stored = RingTuning()
        stored.store(in: defaults)
        #expect(defaults.object(forKey: "ring.linePush") == nil, "a default is cleared, not written")
    }

    /// Flies `seat` flat out from `start` toward `target` for three seconds,
    /// steering at it, and returns how far past its MAX CROSS line the
    /// hull ever got and how near the target it came.
    private func run(
        _ engine: inout SimulationEngine,
        seat: Seat,
        from start: SIMD2<Double>,
        at target: SIMD2<Double>
    ) -> (offside: Double, nearest: Double) {
        for other in Array(engine.state.ships.keys) where other != seat { engine.state.ships[other] = nil }
        engine.state.ball = BallState(position: -target, velocity: .zero, radius: engine.configuration.ballRadius)
        engine.state.serveTicksRemaining = 0
        engine.state.ships[seat]!.position = start
        engine.state.ships[seat]!.velocity = .zero
        engine.state.ships[seat]!.angle = atan2(target.y - start.y, target.x - start.x)
        var offside = 0.0
        var nearest = Double.infinity
        for _ in 0 ..< 360 {
            let ship = engine.state.ships[seat]!
            let way = target - ship.position
            let turn = remainder(atan2(way.y, way.x) - ship.angle, 2 * .pi)
            engine.step(inputs: [seat: PlayerInput(tick: engine.state.tick, torque: max(-1, min(1, turn * 4)), thrust: abs(turn) < 0.5)])
            let position = engine.state.ships[seat]!.position
            offside = max(offside, engine.ringOffside(position, seat: seat).map(simd_length) ?? 0)
            nearest = min(nearest, simd_distance(position, target))
        }
        return (offside, nearest)
    }

    @Test("MAX CROSS: a rival flown flat out at a pilot's mouth is shoved back at the line, along a border too; the owner, or anyone once the owner is out, flies right up to it")
    func maxCross() {
        for pilots in [3, 4] {
            for (owner, knockedOut) in [(false, false), (true, false), (false, true)] {
                var (engine, arena) = field(pilots: pilots)
                let ring = arena.ring!
                let field = engine.state.freeForAll!
                if knockedOut {
                    engine.state.freeForAll!.lives[field.bays[0]] = 0
                    engine.state.ships[field.bays[0]] = nil
                }
                let seat = owner ? field.bays[0] : field.bays[1]
                // A knocked-out net is solid to hulls and stands between the
                // middle and its mouth, so that run aims at its back.
                let mouth = knockedOut ? ring.toWorld(SIMD2(0, -0.15), net: 0) : ring.mouthCentre(0)
                let straight = run(&engine, seat: seat, from: .zero, at: mouth)
                if owner || knockedOut {
                    #expect(straight.offside == 0)
                    #expect(straight.nearest < 0.1, "\(pilots)p owner \(owner) out \(knockedOut): \(straight.nearest) from the target")
                } else {
                    #expect(straight.offside > 0, "the run reaches the line")
                    #expect(straight.offside < 0.36, "\(pilots)p: \(straight.offside) past the line")
                    #expect(straight.nearest > ring.mouthRadius - ring.maxCrossRadius - 0.36)
                }
            }
            // From the rival's own ground, out near the rim, straight across
            // the border onto net 0's ground.
            var (engine, arena) = field(pilots: pilots)
            let ring = arena.ring!
            let seat = engine.state.freeForAll!.bays[1]
            let border = ring.borders(of: 0).high
            let radius = (ring.maxCrossRadius + ring.rimRadius - RingField.finHeight) / 2
            let start = RingField.outward(border + 0.3) * radius
            let side = run(&engine, seat: seat, from: start, at: RingField.outward(border - 0.4) * radius)
            #expect(side.offside > 0 && side.offside < 0.25, "\(pilots)p: \(side.offside) over the border")
        }
    }

    @Test("Past the MAX CROSS line the trigger is dead; short of it, it fires")
    func triggerStopsAtTheLine() {
        for offside in [false, true] {
            var (engine, arena) = field(pilots: 3)
            let ring = arena.ring!
            let seat = engine.state.freeForAll!.bays[1]
            let radius = offside ? ring.maxCrossRadius + 0.1 : ring.maxCrossRadius - 0.1
            engine.state.ships[seat]!.position = ring.outward(at: ring.mouthCentre(0)) * radius
            engine.state.ships[seat]!.velocity = .zero
            engine.state.serveTicksRemaining = 0
            engine.step(inputs: [seat: PlayerInput(tick: engine.state.tick, torque: 0, thrust: false, fire: true, tractor: false)])
            #expect(engine.state.bolts.contains { $0.seat == seat } == !offside, "offside \(offside)")
        }
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
    /// Held short of every MAX CROSS line, it scores from the line, shooting
    /// a ball it cannot reach. At the build 137 flight (thrust 45%, drag
    /// 0.45) over 120 minutes it takes 14.8 rival lives per 20 minutes at
    /// three pilots and 22.6 at four, giving up about 2; the floors sit
    /// about 30% under the means, and an idle bot takes none -- an
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
        #expect(rival >= (pilots == 3 ? 18 : 26), "only \(rival) rival lives in 20 minutes")
        #expect(Double(rival) > 1.3 * Double(own), "rival \(rival), own \(own)")
    }
}
