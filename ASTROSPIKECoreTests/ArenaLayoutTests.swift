import Foundation
import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Arena layouts")
struct ArenaLayoutTests {
    private static let alternates = ArenaLayout.allCases.filter { $0 != .standard }

    /// Every court a layout can be laid into: the duel court on its shipped
    /// ball, and the doubles court on its small one.
    private static func courts(_ layout: ArenaLayout) -> [(ArenaGeometry, Double)] {
        let duelBall = FlightTuningSnapshot.defaults.ballRadius
        let doublesBall = BallState.nominalRadius
        return [
            (ArenaGeometry.standard(ballRadius: duelBall).laidOut(layout), duelBall),
            (ArenaGeometry.doubles(ballRadius: doublesBall).laidOut(layout), doublesBall),
        ]
    }

    private static func engine(_ layout: ArenaLayout, doubles: Bool = false) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        var configuration = FlightTuningSnapshot.defaults.configuration
        configuration.arenaLayout = layout
        if doubles { configuration = .doubles(from: configuration) }
        engine.updateConfiguration(configuration)
        let court = doubles ? ArenaGeometry.doubles(ballRadius: configuration.ballRadius)
            : ArenaGeometry.standard(ballRadius: configuration.ballRadius)
        engine.updateArena(court.laidOut(layout))
        engine.configureRoster(doubles ? Seat.doubles : Seat.singles)
        engine.beginPlay()
        return engine
    }

    /// `shoved` counts a sprung peg as anywhere on its track, for room that
    /// has to stay clear however the pegs have been left.
    private static func deepestPenetration(
        _ arena: ArenaGeometry,
        _ position: SIMD2<Double>,
        _ radius: Double,
        shoved: Bool = false
    ) -> Double {
        arena.obstacles.map { obstacle in
            var obstacle = obstacle
            if shoved && obstacle.isSprung {
                obstacle.start.y -= arena.bumperTravel
                obstacle.end.y += arena.bumperTravel
            }
            return obstacle.radius + radius - simd_distance(position, obstacle.closestPoint(to: position))
        }.max() ?? -.infinity
    }

    @Test("The standard layout leaves the shipped court exactly as it was")
    func standardIsUntouched() {
        #expect(ArenaGeometry.standard.laidOut(.standard) == ArenaGeometry.standard)
        #expect(ArenaGeometry.standard.obstacles.isEmpty)
        #expect(FlightTuningSnapshot.defaults.arenaLayout == .standard)
    }

    @Test("Every layout is mirrored across the net", arguments: ArenaLayout.allCases)
    func mirrored(_ layout: ArenaLayout) {
        for (court, _) in Self.courts(layout) {
            for obstacle in court.obstacles {
                #expect(court.obstacles.contains(obstacle.mirrored))
            }
        }
    }

    @Test("Doubles stretches a layout with its court", arguments: alternates)
    func stretchesWithDoubles(_ layout: ArenaLayout) {
        let duel = ArenaGeometry.standard.laidOut(layout).obstacles
        let doubles = ArenaGeometry.doubles(ballRadius: BallState.nominalRadius).laidOut(layout).obstacles
        #expect(duel.count == doubles.count)
        for (small, big) in zip(duel, doubles) {
            #expect(abs(big.start.x - small.start.x * 1.25) < 1e-9)
            #expect(abs(big.end.y - small.end.y * 1.25) < 1e-9)
        }
    }

    @Test("Nothing stands where the game needs room", arguments: alternates)
    func clearance(_ layout: ArenaLayout) {
        let hull = ShipHitbox.shared.reach
        for (court, ball) in Self.courts(layout) {
            let w = court.widthScale, h = court.heightScale
            for sign in [-1.0, 1.0] {
                // Spawns, lead and wing, with a hull's worth of room.
                for depth in [0.55, 0.80] {
                    #expect(Self.deepestPenetration(court, SIMD2(sign * depth * w, -0.45 * h), hull + 0.02, shoved: true) < 0, "hull \(hull) depth \(depth)")
                }
                // Where the AI parks to strike and to defend -- with the pegs
                // at rest: a hull parking there just shoves one aside.
                #expect(Self.deepestPenetration(court, SIMD2(sign * 0.34, court.humpUndersideY - 0.34), hull) < 0)
                #expect(Self.deepestPenetration(court, SIMD2(sign * 0.76 * w, court.floorY + 0.34 * h), hull) < 0)
                // The whole goal: mouth, cap and lips, a ball's width out.
                var y = court.netBottomY - court.lipLength
                while y <= court.portalMouthTopY {
                    for x in stride(from: 0.0, through: court.netHalfWidth + court.lipLength + ball, by: 0.01) {
                        #expect(Self.deepestPenetration(court, SIMD2(sign * x, y), ball, shoved: true) < 0)
                    }
                    y += 0.01
                }
            }
            // The serve and the re-drop fall from centre court to the floor,
            // drifting a little either way.
            var y = FlightTuningSnapshot.defaults.ballDropHeight
            while y >= court.floorY {
                for x in stride(from: -0.2, through: 0.2, by: 0.02) {
                    #expect(Self.deepestPenetration(court, SIMD2(x, y), ball, shoved: true) < 0)
                }
                y -= 0.02
            }
        }
    }

    @Test("A cut against the wall leaves no pocket behind it", arguments: alternates)
    func noPockets(_ layout: ArenaLayout) {
        for (court, ball) in Self.courts(layout) {
            for obstacle in court.obstacles {
                if obstacle.isSprung {
                    // Well off the side wall, and run to either end of its
                    // track it shuts the gap to every size of ball.
                    #expect(court.halfWidth - abs(obstacle.start.x) - obstacle.radius > ball * 2)
                    let top = court.ceilingY - (obstacle.start.y + court.bumperTravel) - obstacle.radius
                    let bottom = (obstacle.start.y - court.bumperTravel) - court.floorY - obstacle.radius
                    for gap in [top, bottom] {
                        #expect(gap > 0 && gap < BallState.nominalRadius * 2, "gap \(gap)")
                    }
                    continue
                }
                for end in [obstacle.start, obstacle.end] {
                    // An end either sits in a wall, floor or roof, or is at
                    // least a ball's width clear of all of them.
                    let clearX = court.halfWidth - abs(end.x) - obstacle.radius
                    let clearY = min(court.ceilingY - end.y, end.y - court.floorY) - obstacle.radius
                    let buried = clearX < 0 || clearY < 0
                    #expect(buried || (clearX > ball * 2 && clearY > ball * 2))
                }
            }
            // And between any two obstacles a ball either fits or is shut out.
            for (i, a) in court.obstacles.enumerated() {
                for b in court.obstacles[(i + 1)...] {
                    var gap = Double.infinity
                    for t in stride(from: 0.0, through: 1.0, by: 0.05) {
                        let p = a.start + (a.end - a.start) * t
                        gap = min(gap, simd_distance(p, b.closestPoint(to: p)) - a.radius - b.radius)
                    }
                    #expect(gap > ball * 2.2)
                }
            }
        }
    }

    @Test("A driven ball never ends a step inside an obstacle", arguments: alternates)
    func noTunnelling(_ layout: ArenaLayout) {
        var engine = Self.engine(layout)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        let arena = engine.arena
        let r = engine.configuration.ballRadius
        var worst = -Double.infinity
        for obstacle in arena.obstacles {
            let middle = (obstacle.start + obstacle.end) / 2
            for step in 0 ..< 24 {
                let angle = Double(step) / 24 * 2 * .pi
                let from = SIMD2(cos(angle), sin(angle))
                var start = middle + from * (obstacle.radius + r + 0.10)
                start.x = min(arena.halfWidth - r, max(-arena.halfWidth + r, start.x))
                start.y = min(arena.ceilingY - r, max(arena.floorY + r, start.y))
                guard Self.deepestPenetration(arena, start, r) < 0 else { continue }
                var probe = engine
                for seat in probe.state.ships.keys {
                    probe.state.ships[seat]?.position = SIMD2(0, arena.floorY + 0.1)
                }
                probe.state.balls[0] = BallState(position: start, velocity: (middle - start) / simd_length(middle - start) * 6, radius: r)
                for _ in 0 ..< 8 {
                    probe.step(inputs: [:])
                    // Against where the pegs are now: the ball knocks a sprung one back.
                    worst = max(worst, Self.deepestPenetration(
                        arena.displaced(by: probe.state.bumpers), probe.state.balls[0].position, r
                    ))
                }
            }
        }
        #expect(worst < r * 0.25)
    }

    @Test("A ball dropped on a peg bounces off it, and the peg is not floor")
    func pegBounces() {
        var engine = Self.engine(.bumpers)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        let peg = engine.arena.obstacles.first { $0.start == $0.end && $0.start.x > 0 }!
        let r = engine.configuration.ballRadius
        engine.state.balls[0] = BallState(position: peg.start + SIMD2(0, peg.radius + r + 0.01), velocity: SIMD2(0, -1.5), radius: r)
        let floorBefore = engine.state.match.floorContacts
        var bounced = false
        for _ in 0 ..< 10 {
            engine.step(inputs: [:])
            bounced = bounced || engine.state.balls[0].velocity.y > 0
        }
        #expect(bounced)
        #expect(engine.state.match.floorContacts == floorBefore)
    }

    @Test("Landing on a floor cut is a bounce, like a corner")
    func floorCutIsFloor() {
        var engine = Self.engine(.diamond)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        let cut = engine.arena.obstacles.first { $0.isGround && $0.start.x > 0 }!
        let r = engine.configuration.ballRadius
        let middle = (cut.start + cut.end) / 2
        let normal = simd_normalize(SIMD2(-(cut.end - cut.start).y, (cut.end - cut.start).x))
        let up = normal.y > 0 ? normal : -normal
        engine.state.balls[0] = BallState(position: middle + up * (cut.radius + r + 0.01), velocity: -up * 1.5, radius: r)
        var touched = false
        for _ in 0 ..< 10 {
            engine.step(inputs: [:])
            // Counted up on the cut, not after falling through it into the
            // corner arc behind.
            let depth = cut.radius + r - simd_distance(engine.state.balls[0].position, cut.closestPoint(to: engine.state.balls[0].position))
            #expect(depth < r * 0.25)
            touched = touched || engine.state.match.floorContacts[.orange] > 0
        }
        #expect(touched)
    }

    @Test("Only the bumpers are sprung, and the drawn court keeps the flag through mirror and stretch")
    func sprungSurvivesLayout() {
        for layout in ArenaLayout.allCases {
            for (court, _) in Self.courts(layout) {
                #expect(court.obstacles.allSatisfy { $0.isSprung == (layout == .bumpers) })
            }
        }
        #expect(ArenaGeometry.standard.laidOut(.bumpers).obstacles.count == 2)
    }

    /// A Bumpers match in play, with the ball and cyan parked out of the way.
    private static func pegCourt(pegPull: Double = 1) -> SimulationEngine {
        var engine = Self.engine(.bumpers)
        var configuration = engine.configuration
        configuration.pegPull = pegPull
        engine.updateConfiguration(configuration)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        engine.state.balls[0].position = SIMD2(-0.85, 0.55)
        engine.state.balls[0].velocity = .zero
        engine.state.ships[.cyan]?.position = SIMD2(-0.6, engine.arena.floorY + 0.1)
        return engine
    }

    private static func rightPeg(_ engine: SimulationEngine) -> Int {
        engine.arena.obstacles.firstIndex { $0.isSprung && $0.start.x > 0 }!
    }

    @Test("A hull shoves a peg along its track, never off it or past its end, and it stays where it stops")
    func shipShovesPeg() {
        var engine = Self.pegCourt()
        let index = Self.rightPeg(engine)
        let peg = engine.arena.obstacles[index]
        let reach = ShipHitbox.shared.reach
        let travel = engine.arena.bumperTravel
        // Up into it from underneath.
        engine.state.ships[.orange]?.position = peg.start + SIMD2(0, -(reach + peg.radius + 0.01))
        engine.state.ships[.orange]?.velocity = SIMD2(0, 1.5)
        engine.state.ships[.orange]?.angle = .pi / 2
        var furthest = 0.0
        for _ in 0 ..< 12 {
            engine.step(inputs: [:])
            furthest = max(furthest, abs(engine.state.bumpers[index].offset.y))
            #expect(engine.state.bumpers[index].offset.x == 0)
        }
        #expect(engine.state.bumpers[index].offset.y > 0.02)
        // Get the hull out of the way: the peg glides to a stop and stays.
        engine.state.ships[.orange]?.position = SIMD2(0.6, engine.arena.floorY + 0.1)
        engine.state.ships[.orange]?.velocity = .zero
        for _ in 0 ..< 360 { engine.step(inputs: [:]) }
        let parked = engine.state.bumpers[index].offset.y
        for _ in 0 ..< 240 {
            engine.step(inputs: [:])
            furthest = max(furthest, abs(engine.state.bumpers[index].offset.y))
        }
        #expect(furthest <= travel + 1e-9)
        // One solid shove carries it a good way down a floor-to-roof track.
        #expect(parked > 0.3, "parked \(parked)")
        #expect(engine.state.bumpers[index].offset.y == parked, "parked \(parked) now \(engine.state.bumpers[index].offset.y)")
        #expect(engine.state.bumpers[index].velocity == .zero)
    }

    @Test("A hull flying square into a peg's side meets a post: the track has no sideways give")
    func pegHasNoSidewaysGive() {
        var engine = Self.pegCourt()
        let index = Self.rightPeg(engine)
        let peg = engine.arena.obstacles[index]
        let reach = ShipHitbox.shared.reach
        engine.state.ships[.orange]?.position = peg.start + SIMD2(-(reach + peg.radius + 0.01), 0)
        engine.state.ships[.orange]?.velocity = SIMD2(1.5, 0)
        for _ in 0 ..< 12 { engine.step(inputs: [:]) }
        #expect(engine.state.bumpers[index].offset.x == 0)
        #expect(abs(engine.state.bumpers[index].offset.y) < 0.01)
        #expect((engine.state.ships[.orange]?.velocity.x ?? 1) < 0.5)
    }

    /// How far the beam hauls the right peg in `ticks`, held from
    /// below with the nose straight up at it.
    private static func beamHaul(pegPull: Double, ticks: Int) -> (engine: SimulationEngine, index: Int) {
        var engine = Self.pegCourt(pegPull: pegPull)
        let index = Self.rightPeg(engine)
        let spot = engine.arena.obstacles[index].start + SIMD2(0, -0.3)
        for tick in 0 ..< ticks {
            // Hold the hull still, nose on the peg: only the beam acts.
            engine.state.ships[.orange]?.position = spot
            engine.state.ships[.orange]?.velocity = .zero
            engine.state.ships[.orange]?.angle = .pi / 2
            engine.state.ships[.orange]?.angularVelocity = 0
            engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, tractor: true)])
        }
        return (engine, index)
    }

    @Test("The tractor beam draws a peg along its track toward the nose, and it stays when let go")
    func tractorDrawsPeg() {
        var (engine, index) = Self.beamHaul(pegPull: 1, ticks: 90)
        let travel = engine.arena.bumperTravel
        // Drawn down toward the nose.
        #expect(engine.state.bumpers[index].offset.y < -0.03)
        #expect(engine.state.bumpers[index].offset.y >= -travel - 1e-9)
        #expect(engine.state.bumpers[index].offset.x == 0)
        engine.state.ships[.orange]?.position = SIMD2(0.6, engine.arena.floorY + 0.1)
        for tick in 90 ..< 150 {
            engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false)])
        }
        let parked = engine.state.bumpers[index].offset.y
        for tick in 150 ..< 270 {
            engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false)])
        }
        #expect(parked < -0.03)
        #expect(engine.state.bumpers[index].offset.y == parked)
    }

    @Test("A hull runs a peg all the way up its track and all the way back down, and the beam hauls it most of the way from the floor")
    func pegRunsFullTrack() {
        var engine = Self.pegCourt()
        let index = Self.rightPeg(engine)
        let peg = engine.arena.obstacles[index]
        let travel = engine.arena.bumperTravel
        let reach = ShipHitbox.shared.reach
        #expect(travel > 0.5)
        // Push from underneath, then from on top, keeping the hull on it.
        for direction in [1.0, -1.0] {
            for tick in 0 ..< 600 {
                let side = peg.start + engine.state.bumpers[index].offset
                engine.state.ships[.orange]?.position = side + SIMD2(0, -direction * (reach + peg.radius - 0.005))
                engine.state.ships[.orange]?.velocity = SIMD2(0, direction * 1.2)
                engine.state.ships[.orange]?.angle = direction * .pi / 2
                engine.state.ships[.orange]?.angularVelocity = 0
                engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false)])
                if engine.state.bumpers[index].offset.y * direction >= travel - 1e-9 { break }
            }
            #expect(abs(engine.state.bumpers[index].offset.y - direction * travel) < 1e-9, "\(direction): \(engine.state.bumpers[index].offset.y) of \(travel)")
        }
        // Back on its anchor, then hauled down by a ship skimming the floor
        // beside it, nose on the peg.
        engine.state.bumpers[index] = BumperState()
        let low = SIMD2(peg.start.x + 0.25, engine.arena.floorY + reach + 0.01)
        for tick in 0 ..< 720 {
            let toward = peg.start + engine.state.bumpers[index].offset - low
            engine.state.ships[.orange]?.position = low
            engine.state.ships[.orange]?.velocity = .zero
            engine.state.ships[.orange]?.angle = atan2(toward.y, toward.x)
            engine.state.ships[.orange]?.angularVelocity = 0
            engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, tractor: true)])
        }
        #expect(engine.state.bumpers[index].offset.y < -travel * 0.8, "hauled to \(engine.state.bumpers[index].offset.y) of \(-travel)")
    }

    @Test("Peg pull scales the beam's haul on a peg")
    func pegPullScales() {
        let soft = Self.beamHaul(pegPull: 0.5, ticks: 20)
        let hard = Self.beamHaul(pegPull: 2, ticks: 20)
        let softMoved = -soft.engine.state.bumpers[soft.index].offset.y
        let hardMoved = -hard.engine.state.bumpers[hard.index].offset.y
        #expect(softMoved > 0)
        #expect(hardMoved > softMoved * 2, "soft \(softMoved) hard \(hardMoved)")
    }

    @Test("A bolt knocks a peg along its track: from below it lifts, clipping the underside lifts, dead centre from the side does nothing")
    func boltKnocksPeg() {
        let speed = FlightTuningSnapshot.defaults.configuration.boltSpeed
        func shoot(from offset: SIMD2<Double>, heading: SIMD2<Double>) -> (velocity: Double, bolts: Int) {
            var engine = Self.pegCourt()
            let index = Self.rightPeg(engine)
            let peg = engine.arena.obstacles[index]
            engine.state.ships[.orange]?.position = SIMD2(0.6, engine.arena.floorY + 0.1)
            engine.state.bolts = [BoltState(
                id: 1, owner: .orange,
                position: peg.start + offset,
                velocity: heading * speed,
                ticksRemaining: 60
            )]
            var fastest = 0.0
            for _ in 0 ..< 20 {
                engine.step(inputs: [:])
                let v = engine.state.bumpers[index].velocity.y
                if abs(v) > abs(fastest) { fastest = v }
            }
            return (fastest, engine.state.bolts.count)
        }
        let below = shoot(from: SIMD2(0, -0.2), heading: SIMD2(0, 1))
        #expect(below.velocity > 0.2, "below \(below.velocity)")
        #expect(below.bolts == 0)
        let clip = shoot(from: SIMD2(-0.2, -0.04), heading: SIMD2(1, 0))
        #expect(clip.velocity > 0.05, "clip \(clip.velocity)")
        let side = shoot(from: SIMD2(-0.2, 0), heading: SIMD2(1, 0))
        #expect(abs(side.velocity) < 1e-9)
        #expect(side.bolts == 0)
    }

    @Test("A peg sent along its track kicks a ball in its way")
    func pegKicksBall() {
        var engine = Self.pegCourt()
        let index = Self.rightPeg(engine)
        let peg = engine.arena.obstacles[index]
        let r = engine.configuration.ballRadius
        // Peg driven upward along its track, ball resting just above it.
        engine.state.bumpers[index] = BumperState(velocity: SIMD2(0, 1.0))
        engine.state.balls[0] = BallState(
            position: peg.start + SIMD2(0, peg.radius + r + 0.02),
            velocity: .zero,
            radius: r
        )
        var kicked = 0.0
        for _ in 0 ..< 20 {
            engine.step(inputs: [:])
            kicked = max(kicked, engine.state.balls[0].velocity.y)
        }
        #expect(kicked > 0.3, "kicked \(kicked)")
    }

    @Test("Every peg is back on the middle of its track for the next rally, and the wire carries where they are")
    func pegsResetAndTravel() throws {
        var engine = Self.engine(.bumpers)
        #expect(engine.state.bumpers.count == engine.arena.obstacles.count)
        engine.state.bumpers[0] = BumperState(offset: SIMD2(0.05, 0.02), velocity: SIMD2(1, 0))
        let data = try JSONEncoder().encode(engine.state)
        #expect(try JSONDecoder().decode(WorldState.self, from: data).bumpers == engine.state.bumpers)
        engine.prepareNextRally(mirrored: false)
        #expect(engine.state.bumpers.allSatisfy { $0 == BumperState() })
        // A court with nothing sprung carries nothing.
        #expect(Self.engine(.diamond).state.bumpers.isEmpty)
    }

    @Test("A point puts every peg back on the middle of its track")
    func pegsResetOnAPoint() {
        var engine = Self.engine(.bumpers)
        let radius = engine.state.balls[0].radius
        engine.state.balls[0] = BallState(
            position: SIMD2(-(engine.arena.netHalfWidth + radius + 0.004), 0.30),
            velocity: SIMD2(2, 0),
            radius: radius
        )
        engine.state.bumpers[0] = BumperState(offset: SIMD2(0, 0.3), velocity: .zero)
        var scored = false
        for _ in 0 ..< 60 where !scored {
            engine.step(inputs: [:])
            scored = engine.lastEvents.contains { if case .point = $0 { true } else { false } }
        }
        #expect(scored)
        #expect(engine.state.bumpers.allSatisfy { $0 == BumperState() }, "\(engine.state.bumpers)")
    }

    // Bot rallies run long even on the standard court -- 1,500 to 6,000
    // ticks between points -- so this is a deadlock check, not a pace one:
    // a ball wedged somewhere would stop the score for good.
    @Test("Bots still score on every layout", arguments: ArenaLayout.allCases)
    func botsStillScore(_ layout: ArenaLayout) {
        var engine = Self.engine(layout)
        var pilots: [Seat: AIController] = [:]
        for seat in Seat.singles { pilots[seat] = AIController(difficulty: .pilot) }
        for _ in 0 ..< 30_000 {
            let tick = engine.state.tick
            var inputs: [Seat: PlayerInput] = [:]
            for seat in Seat.singles {
                inputs[seat] = pilots[seat]!.input(for: engine.state, seat: seat, tick: tick)
            }
            engine.step(inputs: inputs)
            let score = engine.state.match.score
            if score.cyan + score.orange >= 4 { break }
        }
        let score = engine.state.match.score
        #expect(score.cyan + score.orange >= 4, "\(layout): \(score) at tick \(engine.state.tick)")
    }
}
