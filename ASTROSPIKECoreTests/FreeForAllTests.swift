import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Free-for-all: three or four pilots on a round air-hockey table, a net
/// each sunk in the top of a bell-curve bump off the rim with its mouth to
/// the middle, a MAX CROSS line round every pilot's ground, five
/// lives, last pilot flying wins.
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

    /// Drives the ball straight into net `net`'s mouth from in front of it,
    /// `across` off its centre line, and steps until the rally ends or a
    /// second has gone.
    private func shoot(
        _ engine: inout SimulationEngine,
        arena: ArenaGeometry,
        net: Int,
        across: Double = 0,
        speed: Double = 1.2,
        lastPlay: BallPlay? = nil
    ) -> [SimulationEvent] {
        let ring = arena.ring!
        let start = SIMD2(across, ring.netDepth + 0.2)
        engine.state.ball = BallState(
            position: ring.toWorld(start, net: net),
            velocity: worldVector(SIMD2(0, -speed), ring: ring, net: net),
            radius: ring.ballRadius,
            lastPlay: lastPlay
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

    /// The narrowest gap there is between a pair of capsule lists.
    private func gap(_ a: [ArenaObstacle], _ b: [ArenaObstacle]) -> Double {
        let samples = (0 ... 20).map { Double($0) / 20 }
        return a.flatMap { a in
            b.map { b in
                samples.flatMap { s in
                    samples.map { t in
                        simd_distance(a.start + (a.end - a.start) * s, b.start + (b.end - b.start) * t)
                    }
                }.min()! - a.radius - b.radius
            }
        }.min()!
    }

    @Test("The field is a ring: a net per pilot evenly round it, each sunk in the top of a bell-curve bump rising off the rim, posts on the curve, flanks down to the rim in the valleys")
    func fieldLayout() {
        let ballRadius = SimulationConfiguration.online.ballRadius
        let smallestBall = BallState.nominalRadius
        let biggestBall = BallState.nominalRadius * ArenaGeometry.maximumRadiusScale
        var bumperUp = RingTuning()
        bumperUp.centreBumper = true
        var tallWide = RingTuning()
        tallWide.bumpHeight = 0.40
        tallWide.bumpWidth = 0.70
        var tallNarrow = RingTuning()
        tallNarrow.bumpHeight = 0.40
        tallNarrow.bumpWidth = 0.15
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
                #expect(ring.toLocal(.zero, net: net).y > ring.netDepth, "the middle is out in front of every mouth")
                #expect(ring.spokeIndex(nearest: ring.mouthCentre(net)) == net)
            }
            // The default bell peaks a quarter of the radius in off the rim,
            // and the whole pocket is walled inside it.
            #expect(abs(ring.cornerDepth - 0.25 * ring.rimRadius) < 1e-9)
            #expect(abs(ring.bumpHeight(at: 0) - ring.cornerDepth) < 1e-9, "the peak is on the goal's line")
            #expect(!ring.pocketsPastRim && ring.netBackRadius + RingField.netWall < ring.rimRadius, "pocket inside the bump")
            #expect(!ring.admitsThroughRim(RingField.outward(ring.spokeAngles[0]) * (ring.rimRadius - 0.01)) { _ in true }, "the rim stays shut behind a sunk pocket")
            #expect(ring.centre.isEmpty, "the centre bumper is off unless asked")
            #expect(!ring.corners.isEmpty)

            // Bump height 0: the goals sit flush in a plain round rim.
            var flat = RingTuning()
            flat.bumpHeight = 0
            let plain = RingField(pilots: pilots, ballRadius: ballRadius, tuning: flat)
            #expect(plain.corners.isEmpty && !plain.hasBumps, "Bump height 0 is a plain rim")
            #expect(plain.netBackRadius > plain.rimRadius, "flush pockets hang outside the rim")
            for net in plain.spokeAngles.indices {
                let post = plain.toWorld(SIMD2(plain.netHalfWidth, plain.netDepth), net: net)
                #expect(abs(simd_length(post) - plain.rimRadius) < 1e-6, "flush mouth ends sit on the rim")
            }

            for tuning in [RingTuning(), bumperUp, tallWide, tallNarrow] {
                for radius in [smallestBall, ballRadius, biggestBall] {
                    let sized = RingField(pilots: pilots, ballRadius: radius, tuning: tuning)
                    let label = "\(pilots) pilots, ball \(radius), height \(tuning.bumpHeight), width \(tuning.bumpWidth)"
                    #expect(abs(sized.cornerDepth - tuning.bumpHeight * sized.rimRadius) < 1e-9, "\(label)")
                    // The MAX CROSS line well short of every mouth.
                    #expect(sized.mouthRadius - sized.maxCrossRadius > 0.25, "\(label): line at \(sized.maxCrossRadius)")
                    #expect(sized.mouthRadius < sized.rimRadius - 0.1, "\(label): the mouth stands in on its bump")
                    for net in sized.spokeAngles.indices {
                        for side in [-1.0, 1.0] {
                            let flank = sized.bumpFlank(net, side: side)
                            // From the post's mouth end, which sits on the bell...
                            let post = sized.toWorld(SIMD2(side * sized.netHalfWidth, sized.netDepth), net: net)
                            #expect(simd_distance(flank.first!, post) < 1e-9, "\(label)")
                            #expect(abs(sized.rimRadius - simd_length(post) - sized.bumpHeight(at: sized.flankStartAngle)) < 1e-6, "\(label): post on the bell")
                            // ...down to the rim in the valley, half way to the next goal...
                            let valley = sized.spokeAngles[net] + side * Double.pi / Double(pilots)
                            #expect(abs(simd_length(flank.last!) - sized.rimRadius) < 1e-9, "\(label): the flank lands on the rim")
                            #expect(abs(remainder(atan2(flank.last!.y, flank.last!.x) - valley, 2 * .pi)) < 1e-9, "\(label)")
                            // ...falling all the way: never turning back in.
                            for (a, b) in zip(flank, flank.dropFirst()) {
                                #expect(simd_length(b) >= simd_length(a) - 1e-12, "\(label): the bell falls away")
                            }
                        }
                    }
                    // Every pilot starts clear of the bumps, out in front of their mouth.
                    for bay in sized.spokeAngles.indices {
                        let spawn = sized.spawnPoint(bay: bay)
                        let offset = remainder(atan2(spawn.y, spawn.x) - sized.spokeAngles[bay], 2 * .pi)
                        #expect(simd_length(spawn) < sized.rimRadius - sized.bumpHeight(at: offset) - 0.08, "\(label): bay \(bay) spawns in the bump")
                    }
                    if tuning.centreBumper {
                        #expect(sized.centre.count == 1)
                        #expect(simd_length(sized.centre[0].start) == 0)
                    } else {
                        #expect(sized.centre.isEmpty)
                    }
                }
            }
        }
        #expect(ArenaGeometry.standard.ring == nil, "the duel court stays a rectangle")
    }

    @Test("The table is flat by default: a ball let go stays put; tilt it with Ring gravity and the ball rolls out into the valley between two bumps")
    func gravityPullsOut() {
        for pilots in [3, 4] {
            for width in [RingTuning().bumpWidth, 0.70] {
            var (start, arena) = field(pilots: pilots)
            var tuning = start.configuration.ring
            tuning.bumpWidth = width
            arena = ArenaGeometry.freeForAll(pilots: pilots, ballRadius: start.configuration.ballRadius, tuning: tuning)
            start.updateArena(arena)
            let ring = arena.ring!
            #expect(start.configuration.ring.gravity == 0)
            for setting in [0.0, 0.3] {
                for net in ring.spokeAngles.indices {
                    var engine = start
                    var configuration = engine.configuration
                    configuration.ring = tuning
                    configuration.ring.gravity = setting
                    engine.updateConfiguration(configuration)
                    for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                    // Out in the gap between a net and the next, clear of both.
                    let bearing = ring.gapBearings[net]
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
                        // Straight out into the valley, it comes to rest down on the rim.
                        let rest = ring.rimRadius - ring.ballRadius
                        #expect(simd_length(ball) < rest + 1e-6 && simd_length(ball) > rest - 0.04, "\(pilots) pilots, width \(width), net \(net): \(simd_length(ball))")
                        #expect(abs(remainder(atan2(ball.y, ball.x) - bearing, 2 * .pi)) < 0.05, "straight out")
                    }
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
        // Down a valley's line, clear of every net and bump; the rim spot is
        // in the valley, where the rim is bare.
        let fin = ring.gapBearings[0]
        let near = pull(at: 0.4, bearing: fin), far = pull(at: 0.8, bearing: fin)
        #expect(near > 0)
        #expect(abs(far / near - 2) < 0.02, "twice as far out pulls twice as hard: \(far / near)")
        let duel = simd_length(start.configuration.gravity) * start.configuration.ballGravityMultiplier
            * start.configuration.stepDuration
        let rimSpot = ring.rimRadius - ring.ballRadius - 0.01
        let rimPull = pull(at: rimSpot, bearing: fin)
        #expect(abs(rimPull / (0.3 * duel * rimSpot / ring.rimRadius) - 1) < 0.02, "the setting's share of the duel's weight at the rim")
        #expect(abs(pull(at: 0.8, bearing: fin, setting: 0.15) / far - 0.5) < 0.02, "the setting scales it")
    }

    @Test("Three pilots take the ends and one wing; four take every seat; everyone starts beside their own mouth, facing in")
    func seats() {
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 3)).bays == [.cyan, .cyanWing, .orange])
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 4)).bays == [.cyan, .cyanWing, .orangeWing, .orange])
        let (engine, arena) = field(pilots: 4)
        let ring = arena.ring!
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() {
            let ship = engine.state.ships[seat]!
            let local = ring.toLocal(ship.position, net: bay)
            #expect(local.x > ring.netHalfWidth + 0.1 && local.y > ring.netDepth, "\(seat) starts beside its own mouth")
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

    /// A shot that misses the mouth glances off the bell's flank beside the
    /// post and is sent on round toward the neighbour on that side, never
    /// costing the net's owner a life; straight down the mouth still scores.
    @Test("A miss off a bump goes on round to a neighbour: wide of a post, the bell's flank turns the ball away along the rim; straight down the mouth it scores")
    func missesDeflectToANeighbour() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let ring = arena.ring!
            for net in ring.spokeAngles.indices {
                let owner = start.state.freeForAll!.bays[net]
                for side in [1.0, -1.0] {
                    var engine = start
                    for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                    // Square at the bump, just wide of the post, as a shot at the mouth would come.
                    let aim = SIMD2(side * (ring.netHalfWidth + ring.ballRadius + 0.04), ring.netDepth + 0.35)
                    engine.state.ball = BallState(
                        position: ring.toWorld(aim, net: net),
                        velocity: worldVector(SIMD2(0, -1.2), ring: ring, net: net),
                        radius: ring.ballRadius
                    )
                    engine.state.serveTicksRemaining = 0
                    var events: [SimulationEvent] = []
                    var turned = false
                    for _ in 0 ..< 60 {
                        engine.step(inputs: [:])
                        events += engine.lastEvents
                        let ball = engine.state.ball
                        let tangent = RingField.outward(atan2(ball.position.y, ball.position.x) + side * .pi / 2)
                        // Headed on round, away from the mouth, faster than it comes back in.
                        if simd_dot(ball.velocity, tangent) > 0.6 { turned = true }
                    }
                    #expect(livesLost(events).isEmpty, "\(pilots) pilots, net \(net), side \(side): a miss costs nothing")
                    #expect(turned, "\(pilots) pilots, net \(net), side \(side): sent on round toward the neighbour")
                    let ball = engine.state.ball.position
                    let round = remainder(atan2(ball.y, ball.x) - ring.spokeAngles[net], 2 * .pi) * side
                    #expect(round > ring.flankStartAngle + 0.15, "\(pilots) pilots, net \(net), side \(side): \(round) round from the goal")
                }
                var engine = start
                for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                let events = shoot(&engine, arena: arena, net: net)
                #expect(livesLost(events) == [owner], "\(pilots) pilots, net \(net): straight in")
            }
        }
    }

    @Test("A knocked-out pilot's net is shut: the ball bounces off its mouth")
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
    }

    @Test("A hull flies up to the mouth but never in, live net or knocked out")
    func shipsStopAtTheMouth() {
        for knockedOut in [false, true] {
            var (engine, arena) = field(pilots: 4)
            let ring = arena.ring!
            let owner = engine.state.freeForAll!.bays[0]
            if knockedOut {
                engine.state.freeForAll!.lives[owner] = 0
                engine.state.ships[owner] = nil
            }
            // A live net's own pilot flies it (a rival would be shoved back
            // at the MAX CROSS line first); a knocked-out net's ground is
            // open, so a rival tries that one.
            let seat = knockedOut ? engine.state.freeForAll!.bays[2] : owner
            for other in Array(engine.state.ships.keys) where other != seat { engine.state.ships[other] = nil }
            engine.state.ball.position = SIMD2(0.3, 0.3)
            engine.state.ball.velocity = .zero
            engine.state.serveTicksRemaining = 0
            let start = ring.toWorld(SIMD2(0, ring.netDepth + 0.2), net: 0)
            let target = ring.toWorld(SIMD2(0, 0.02), net: 0)
            engine.state.ships[seat]!.position = start
            engine.state.ships[seat]!.velocity = simd_normalize(target - start) * 1.2
            var deepest = Double.infinity
            for _ in 0 ..< 120 {
                engine.step(inputs: [:])
                deepest = min(deepest, ring.toLocal(engine.state.ships[seat]!.position, net: 0).y)
            }
            #expect(deepest > ring.netDepth, "knocked out \(knockedOut): got to \(deepest)")
            #expect(deepest < ring.netDepth + 0.12, "knocked out \(knockedOut): stopped at \(deepest), short of the mouth")
        }
    }

    @Test("The face-off clears the optional bumper and drifts out a gap: untouched, it never scores", arguments: [false, true])
    func faceOffNeverScoresUntouched(bumper: Bool) {
        for pilots in [3, 4] {
            for bay in 0 ..< pilots {
                for delay in [0, 7, 19] {
                    var (engine, _) = field(pilots: pilots)
                    var configuration = engine.configuration
                    configuration.ring.centreBumper = bumper
                    engine.updateConfiguration(configuration)
                    engine.updateArena(.freeForAll(pilots: pilots, ballRadius: configuration.ballRadius, tuning: configuration.ring))
                    for _ in 0 ..< delay { engine.step(inputs: [:]) }
                    engine.state.freeForAll!.serveBay = bay
                    engine.prepareNextRally(mirrored: false)
                    engine.beginPlay()
                    for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
                    let drop = simd_length(engine.state.ball.position)
                    if bumper {
                        #expect(drop > RingField.centreBumperRadius + engine.state.ball.radius, "serve clears the bumper")
                        #expect(drop < 0.3)
                    } else {
                        #expect(drop < 0.1, "dropped in the middle")
                    }
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

    @Test("The ring sliders reach the field: the line moves with them, the centre bumper toggles, a slack line lets a rival through, and stored settings clamp to their sliders")
    func ringTuning() {
        var tuning = RingTuning()
        let ballRadius = SimulationConfiguration.online.ballRadius
        let base = RingField(pilots: 4, ballRadius: ballRadius)
        tuning.lineShare = 0.9
        tuning.centreBumper = true
        let moved = RingField(pilots: 4, ballRadius: ballRadius, tuning: tuning)
        #expect(abs(moved.maxCrossRadius / moved.mouthRadius - 0.9) < 1e-9)
        #expect(base.centre.isEmpty && moved.centre.count == 1, "the bumper stands only when asked")
        #expect(moved.netBackRadius == base.netBackRadius, "the line leaves the nets where they are")
        tuning.bumpHeight = 0.35
        let taller = RingField(pilots: 4, ballRadius: ballRadius, tuning: tuning)
        #expect(abs(taller.cornerDepth - 0.35 * taller.rimRadius) < 1e-9 && taller.mouthRadius < base.mouthRadius, "the bumps stand further in, mouths with them")
        tuning.bumpHeight = 0.9
        #expect(abs(RingField(pilots: 4, ballRadius: ballRadius, tuning: tuning).cornerDepth - 0.40 * base.rimRadius) < 1e-9, "held to the cap")
        tuning.bumpWidth = 0.6
        let wider = RingField(pilots: 4, ballRadius: ballRadius, tuning: tuning)
        let offset = wider.flankEndAngle / 2
        #expect(wider.bumpHeight(at: offset) / wider.cornerDepth > taller.bumpHeight(at: offset) / taller.cornerDepth, "a wider bell stands taller half way down")
        #expect(abs(base.cornerDepth - RingTuning().bumpHeight * base.rimRadius) < 1e-9)

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
        defaults.set(true, forKey: RingTuning.centreBumperKey)
        defaults.set(true, forKey: RingTuning.puckKey)
        defaults.set(0.1, forKey: "ring.fireCooldown")
        var stored = RingTuning.stored(in: defaults)
        #expect(stored.puck, "the puck is stored")
        #expect(stored.fireCooldown == 0.45, "fire rate clamped to its slider")
        #expect(stored.linePush == 30, "clamped to the slider")
        #expect(stored.centreBumper, "the toggle is stored")
        #expect(stored.gravity == 0.25, "Ring gravity keeps its old key")
        stored = RingTuning()
        stored.store(in: defaults)
        #expect(defaults.object(forKey: "ring.linePush") == nil, "a default is cleared, not written")
        #expect(defaults.object(forKey: RingTuning.centreBumperKey) == nil)
        #expect(defaults.object(forKey: RingTuning.puckKey) == nil)
        #expect(RingTuning.stored(in: defaults) == RingTuning())
    }

    @Test("The puck slides dead straight: the spin a hit leaves on it never bends its path, where the ball's curves")
    func puckSlidesStraight() {
        for puck in [false, true] {
            var (engine, _) = field(pilots: 3)
            var configuration = engine.configuration
            configuration.ring.puck = puck
            engine.updateConfiguration(configuration)
            for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
            engine.state.ball = BallState(position: SIMD2(-0.3, 0), velocity: SIMD2(0.8, 0), radius: engine.configuration.ballRadius)
            engine.state.ball.spin = BoltState.spinKick
            engine.state.serveTicksRemaining = 0
            for _ in 0 ..< 60 { engine.step(inputs: [:]) }
            let drift = abs(engine.state.ball.velocity.y)
            if puck {
                #expect(drift < 1e-9, "puck bent by \(drift)")
            } else {
                #expect(drift > 0.01, "ball curved only \(drift)")
            }
        }
    }

    @Test("The ring keeps its own fire rate: a bolt holds the gun for Fire rate seconds, not the duel's")
    func ringFireRate() {
        for cooldown in [RingTuning().fireCooldown, 3.0] {
            var (engine, _) = field(pilots: 3)
            var configuration = engine.configuration
            configuration.ring.fireCooldown = cooldown
            engine.updateConfiguration(configuration)
            let seat = engine.state.freeForAll!.bays[0]
            var held: UInt64 = 0
            for _ in 0 ..< 1200 where held == 0 {
                engine.step(inputs: [seat: PlayerInput(tick: engine.state.tick, torque: 0, thrust: false, fire: true)])
                held = engine.state.ships[seat]!.fireCooldownTicks
            }
            let expected = UInt64((cooldown / engine.configuration.stepDuration).rounded())
            #expect(held == expected, "held \(held) ticks, want \(expected)")
            #expect(Double(held) * engine.configuration.stepDuration > engine.configuration.boltCooldown * 2, "much slower than the duel")
        }
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
                let mouth = ring.mouthCentre(0)
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
            let radius = (ring.maxCrossRadius + ring.rimRadius) / 2
            let start = RingField.outward(border + 0.3) * radius
            let side = run(&engine, seat: seat, from: start, at: RingField.outward(border - 0.4) * radius)
            #expect(side.offside > 0 && side.offside < 0.3, "\(pilots)p: \(side.offside) over the border")
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

    // MARK: - The stat book on the ring

    private func goalScored(_ events: [SimulationEvent]) -> (seat: Seat, style: GoalStyle)? {
        for event in events { if case let .goalScored(seat, style) = event { return (seat, style) } }
        return nil
    }

    @Test("A goal on the ring is booked to the last play on the ball, by kind, and called after the life it took", arguments: [3, 4])
    func ringGoalsAreBooked(pilots: Int) {
        for (kind, style) in [(BallPlay.Kind.hull, GoalStyle.hull), (.bolt, .bolt), (.slamDunk, .slamDunk)] {
            var (engine, arena) = field(pilots: pilots)
            let field = engine.state.freeForAll!
            let owner = field.bays[0]
            let scorer = field.bays[1]
            let ring = arena.ring!
            engine.state.ball = BallState(
                position: ring.toWorld(SIMD2(0, ring.netDepth + 0.2), net: 0),
                velocity: worldVector(SIMD2(0, -1.2), ring: ring, net: 0),
                radius: ring.ballRadius,
                lastPlay: BallPlay(seat: scorer, kind: kind)
            )
            engine.state.serveTicksRemaining = 0
            var events: [SimulationEvent] = []
            for _ in 0 ..< 120 {
                engine.step(inputs: [:])
                events += engine.lastEvents
                if engine.state.match.phase != .playing { break }
            }
            #expect(livesLost(events) == [owner], "\(kind)")
            let credit = goalScored(events)
            #expect(credit?.seat == scorer && credit?.style == style, "\(kind): \(String(describing: credit))")
            let lifeIndex = events.firstIndex { if case .lifeLost = $0 { true } else { false } }
            let goalIndex = events.firstIndex { if case .goalScored = $0 { true } else { false } }
            #expect(lifeIndex != nil && goalIndex != nil && lifeIndex! < goalIndex!, "the call follows the life")
            let expected = PilotStats(
                goals: 1,
                boltGoals: kind == .hull ? 0 : 1,
                slamDunks: kind == .slamDunk ? 1 : 0
            )
            #expect(engine.state.stats[scorer] == expected, "\(kind)")
            #expect(engine.state.stats[owner] == PilotStats())
            // No halves on the ring: nothing crosses, so no rally is measured.
            #expect(engine.state.stats.longestRally == 0)
        }
    }

    @Test("The net's owner putting it in is an own goal; a rival's beam pulling it in is that rival's slam dunk")
    func ringOwnGoalAndBeamSlam() {
        var (engine, arena) = field(pilots: 3)
        let ring = arena.ring!
        let owner = engine.state.freeForAll!.bays[0]
        let puller = engine.state.freeForAll!.bays[2]
        var own = engine
        let events = shoot(&own, arena: arena, net: 0)
        #expect(goalScored(events) == nil, "a face-off ball nobody played is nobody's goal")
        #expect(own.state.stats == MatchStats())

        own = engine
        let ownGoal = shoot(&own, arena: arena, net: 0, lastPlay: BallPlay(seat: owner, kind: .hull))
        #expect(goalScored(ownGoal)?.style == .ownGoal)
        #expect(own.state.stats[owner] == PilotStats(ownGoals: 1))

        engine.state.ball = BallState(
            position: ring.toWorld(SIMD2(0, ring.netDepth + 0.2), net: 0),
            velocity: worldVector(SIMD2(0, -1.2), ring: ring, net: 0),
            radius: ring.ballRadius,
            lastPlay: BallPlay(seat: owner, kind: .hull),
            beamHold: BeamHold(seat: puller, tick: engine.state.tick)
        )
        engine.state.serveTicksRemaining = 0
        var pulled: [SimulationEvent] = []
        for _ in 0 ..< 120 {
            // Keep the hold fresh: the slam grace is a fraction of a second.
            engine.state.ball.beamHold = BeamHold(seat: puller, tick: engine.state.tick)
            engine.step(inputs: [:])
            pulled += engine.lastEvents
            if engine.state.match.phase != .playing { break }
        }
        #expect(livesLost(pulled) == [owner])
        #expect(goalScored(pulled)?.seat == puller)
        #expect(goalScored(pulled)?.style == .slamDunk)
        #expect(engine.state.stats[puller] == PilotStats(goals: 1, slamDunks: 1))
        #expect(engine.state.stats[owner].ownGoals == 0)
    }

    @Test("Hull touches and zaps on the ring go in the book; a guest's board keeps none of it")
    func ringPlaysAreBooked() {
        var (engine, _) = field(pilots: 3)
        // Not `field`: that name is the helper, called again below.
        let book = engine.state.freeForAll!
        let hitter = book.bays[1]
        // Park the ball dead in front of the hull and knock it.
        let ship = engine.state.ships[hitter]!
        let nose = SIMD2(cos(ship.angle), sin(ship.angle))
        engine.state.ball = BallState(position: ship.position + nose * 0.09, velocity: -nose * 0.8, radius: engine.state.ball.radius)
        engine.state.serveTicksRemaining = 0
        var guest = engine
        guest.followsHost = true
        for _ in 0 ..< 20 {
            engine.step(inputs: [:])
            guest.step(inputs: [:])
        }
        #expect(engine.state.stats[hitter].hits >= 1)
        #expect(engine.state.ball.lastPlay?.seat == hitter)
        #expect(guest.state.stats == MatchStats(), "a guest flies the physics and writes nothing")

        // A bolt into a rival hull is a zap.
        var (zapper, _) = field(pilots: 3)
        let shooter = zapper.state.freeForAll!.bays[1]
        let victim = zapper.state.freeForAll!.bays[2]
        zapper.state.serveTicksRemaining = 0
        zapper.state.ships[shooter]!.position = SIMD2(-0.3, 0)
        zapper.state.ships[shooter]!.velocity = .zero
        zapper.state.ships[shooter]!.angle = 0
        zapper.state.ships[victim]!.position = SIMD2(0.3, 0)
        zapper.state.ships[victim]!.velocity = .zero
        // The ball parked in the open middle, off the bolt's line.
        zapper.state.ball = BallState(position: SIMD2(0, 0.5), velocity: .zero, radius: zapper.state.ball.radius)
        var events: [SimulationEvent] = []
        for tick in 0 ..< 90 {
            zapper.state.ships[victim]!.position = SIMD2(0.3, 0)
            zapper.state.ships[victim]!.velocity = .zero
            zapper.step(inputs: [shooter: PlayerInput(tick: zapper.state.tick, torque: 0, thrust: false, fire: tick == 0, tractor: false)])
            events += zapper.lastEvents
        }
        #expect(zapper.state.stats[shooter].zaps == 1)
        #expect(events.contains(.play(seat: shooter, call: .zap(victim: victim))))
    }

    // MARK: - Online seating

    @Test("A ring plan seats the duel's order and cuts a ring of three or four from the plan alone")
    func ringSeating() {
        let plan = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:2"], format: .freeForAll)
        #expect(plan == ["G:1": .cyan, "G:2": .orange])
        #expect(OnlineSeating.roster(filled: Set(plan.values), format: .freeForAll) == FreeForAllState.seats(pilots: 3))
        let three = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:3", "G:2"], format: .freeForAll)
        #expect(Set(three.values) == FreeForAllState.seats(pilots: 3), "three pilots fill the three-net ring exactly")
        #expect(OnlineSeating.roster(filled: Set(three.values), format: .freeForAll) == FreeForAllState.seats(pilots: 3))
        let four = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:4", "G:2", "G:3"], format: .freeForAll)
        #expect(OnlineSeating.roster(filled: Set(four.values), format: .freeForAll) == Seat.doubles)
        #expect(OnlineSeating.roster(filled: [.cyan, .orange], format: .freeForAll4) == Seat.doubles,
                "a four-pilot invite keeps four nets even while bots fill two chairs")
        #expect(OnlineSeating.roster(filled: [.cyan, .orange], format: .doublesVersus) == Seat.doubles,
                "a versus invite keeps both wings even before more friends join")
        // A duel's roster is untouched.
        #expect(OnlineSeating.roster(filled: [.cyan, .orange], format: .duel) == Seat.singles)
        #expect(OnlineSeating.roster(filled: [.cyan, .cyanWing], format: .teamUp) == Seat.doubles)
    }

    @Test("A late arrival takes a bot's chair on the ring only when their board would cut the same ring")
    func ringLateSeat() {
        let three = Array(FreeForAllState.seats(pilots: 3))
        // Two on a three-net ring: the bot's chair is theirs.
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange], format: .freeForAll, ring: three) == .cyanWing)
        // Three on a three-net ring: full. A fourth would build a four-net ring.
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange, .cyanWing], format: .freeForAll, ring: three) == nil)
        // A four-net ring down to three pilots takes one back.
        let four = Seat.allCases
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange, .cyanWing], format: .freeForAll, ring: four) == .orangeWing)
        // Down to two it does not: a newcomer's plan of three would cut three nets.
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange], format: .freeForAll, ring: four) == nil)
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange], format: .freeForAll4, ring: four) == .cyanWing,
                "a four-pilot invite keeps that bot chair available")
        // No snapshot out yet: the ring is the one the plan cuts.
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange], format: .freeForAll, ring: nil) == .cyanWing)
        // Off the ring the first empty chair in the order, as before.
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .orange], format: .duel, ring: nil) == .cyanWing)
        #expect(OnlineSeating.lateSeat(filled: [.cyan, .cyanWing], format: .teamUp, ring: nil) == .orange)
    }

    @Test("On the ring a dropped pilot's chair always goes to a bot: nobody forfeits a field")
    func ringHoldExpiry() {
        let three: [String: Seat] = ["G:1": .cyan, "G:2": .orange, "G:3": .cyanWing]
        #expect(OnlineSeating.seatingAfterHold(seating: three, dropped: ["G:2"], format: .freeForAll) == ["G:1": .cyan, "G:3": .cyanWing])
        #expect(OnlineSeating.seatingAfterHold(seating: three, dropped: ["G:2"], format: .freeForAll4) == ["G:1": .cyan, "G:3": .cyanWing],
                "a four-pilot ring carries on with a bot after a disconnect")
        #expect(OnlineSeating.seatingAfterHold(seating: three, dropped: ["G:2", "G:3"], format: .freeForAll) == ["G:1": .cyan])
        #expect(OnlineSeating.seatingAfterHold(seating: three, dropped: [], format: .freeForAll) == nil)
        #expect(OnlineSeating.benchesDropped(["G:2"], seating: three, plan: ["G:1": .cyan, "G:3": .cyanWing], format: .freeForAll))
        // The duel still forfeits a side left with nobody.
        #expect(OnlineSeating.seatingAfterHold(seating: ["G:1": .cyan, "G:2": .orange], dropped: ["G:2"]) == nil)
    }

    @Test("The host's ring settings ride the wire in its tuning")
    func ringTuningOnTheWire() throws {
        var tuning = FlightTuningSnapshot.defaults
        tuning.ring.speed = 0.6
        tuning.ring.centreBumper = true
        let data = try JSONEncoder().encode(tuning)
        let decoded = try JSONDecoder().decode(FlightTuningSnapshot.self, from: data)
        #expect(decoded == tuning)
        #expect(decoded.configuration.ring == tuning.ring)
        #expect(decoded.configuration.ringThrust == decoded.configuration.maximumThrustAcceleration * 0.6)
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
    /// a ball it cannot reach. With the flush slots these starts give
    /// 46 rival lives at three pilots and 27 at four, none of its own (over
    /// 100 minutes of lone play, about 1.6 a minute at either size); the
    /// floors sit about 30% under, and an idle bot takes none -- an
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
        #expect(rival >= (pilots == 3 ? 32 : 19), "only \(rival) rival lives in 20 minutes")
        #expect(Double(rival) > 1.3 * Double(own), "rival \(rival), own \(own)")
    }
}
