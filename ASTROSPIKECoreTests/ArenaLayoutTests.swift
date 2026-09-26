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

    /// `shoved` counts a sprung peg as reaching the whole of its travel in
    /// every direction, for room that has to stay clear however hard the
    /// pegs have been knocked about.
    private static func deepestPenetration(
        _ arena: ArenaGeometry,
        _ position: SIMD2<Double>,
        _ radius: Double,
        shoved: Bool = false
    ) -> Double {
        arena.obstacles.map { obstacle in
            let reach = obstacle.radius + (shoved && obstacle.isSprung ? arena.bumperTravel : 0)
            return reach + radius - simd_distance(position, obstacle.closestPoint(to: position))
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
                    #expect(Self.deepestPenetration(court, SIMD2(sign * depth * w, -0.45 * h), hull + 0.02, shoved: true) < 0)
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
                for end in [obstacle.start, obstacle.end] {
                    // An end either sits in a wall, floor or roof, or is at
                    // least a ball's width clear of all of them.
                    // A sprung peg keeps the gap even shoved hard at the wall.
                    let reach = obstacle.radius + (obstacle.isSprung ? court.bumperTravel : 0)
                    let clearX = court.halfWidth - abs(end.x) - reach
                    let clearY = min(court.ceilingY - end.y, end.y - court.floorY) - reach
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
        let peg = engine.arena.obstacles.first { $0.start == $0.end && $0.start.x > 0 && $0.start.y > 0 }!
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
        #expect(ArenaGeometry.standard.laidOut(.bumpers).obstacles.count == 4)
    }

    @Test("A hull shoves a peg off its anchor, never past its travel, and it swings home and settles")
    func shipShovesPeg() {
        var engine = Self.engine(.bumpers)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        let index = engine.arena.obstacles.firstIndex { $0.isSprung && $0.start.x > 0 && $0.start.y < 0 }!
        let peg = engine.arena.obstacles[index]
        let reach = ShipHitbox.shared.reach
        let travel = engine.arena.bumperTravel
        engine.state.ships[.orange]?.position = peg.start + SIMD2(-(reach + peg.radius + 0.01), 0)
        engine.state.ships[.orange]?.velocity = SIMD2(1.5, 0)
        engine.state.ships[.cyan]?.position = SIMD2(-0.6, engine.arena.floorY + 0.1)
        var furthest = 0.0
        for _ in 0 ..< 12 {
            engine.step(inputs: [:])
            furthest = max(furthest, simd_length(engine.state.bumpers[index].offset))
        }
        #expect(furthest > 0.02)
        #expect(engine.state.bumpers[index].offset.x > 0)
        // Get the hull out of the way and let it swing home.
        engine.state.ships[.orange]?.position = SIMD2(0.6, engine.arena.floorY + 0.1)
        engine.state.ships[.orange]?.velocity = .zero
        for _ in 0 ..< 120 {
            engine.step(inputs: [:])
            furthest = max(furthest, simd_length(engine.state.bumpers[index].offset))
        }
        #expect(furthest <= travel + 1e-9)
        #expect(simd_length(engine.state.bumpers[index].offset) < 0.005)
        #expect(simd_length(engine.state.bumpers[index].velocity) < 0.05)
    }

    @Test("The tractor beam draws a peg off its anchor, and it swings home when let go")
    func tractorDrawsPeg() {
        var engine = Self.engine(.bumpers)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        let index = engine.arena.obstacles.firstIndex { $0.isSprung && $0.start.x > 0 && $0.start.y < 0 }!
        let peg = engine.arena.obstacles[index]
        let travel = engine.arena.bumperTravel
        let spot = peg.start + SIMD2(-0.3, 0)
        engine.state.balls[0].position = SIMD2(-0.6, 0.6)
        engine.state.ships[.cyan]?.position = SIMD2(-0.6, engine.arena.floorY + 0.1)
        var furthest = 0.0
        for tick in 0 ..< 90 {
            // Hold the hull still, nose on the peg: only the beam acts.
            engine.state.ships[.orange]?.position = spot
            engine.state.ships[.orange]?.velocity = .zero
            engine.state.ships[.orange]?.angle = 0
            engine.state.ships[.orange]?.angularVelocity = 0
            engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false, tractor: true)])
            furthest = max(furthest, simd_length(engine.state.bumpers[index].offset))
        }
        // Drawn toward the nose, which is toward the net.
        #expect(engine.state.bumpers[index].offset.x < -0.03)
        #expect(furthest <= travel + 1e-9)
        for tick in 90 ..< 210 {
            engine.state.ships[.orange]?.position = spot
            engine.state.ships[.orange]?.velocity = .zero
            engine.step(inputs: [.orange: PlayerInput(tick: UInt64(tick), torque: 0, thrust: false)])
        }
        #expect(simd_length(engine.state.bumpers[index].offset) < 0.005)
    }

    @Test("A peg swinging home kicks a ball sitting in its way")
    func pegKicksBall() {
        var engine = Self.engine(.bumpers)
        for _ in 0 ..< 600 where engine.state.match.phase != .playing { engine.step(inputs: [:]) }
        let index = engine.arena.obstacles.firstIndex { $0.isSprung && $0.start.x > 0 && $0.start.y > 0 }!
        let peg = engine.arena.obstacles[index]
        let r = engine.configuration.ballRadius
        let travel = engine.arena.bumperTravel
        // Peg held back toward the net, ball at rest half a swing ahead of
        // it: the peg is at full speed when it arrives. (Resting on the
        // anchor itself the damped peg barely creeps into it.)
        engine.state.bumpers[index] = BumperState(offset: SIMD2(-travel, 0))
        engine.state.balls[0] = BallState(
            position: peg.start + SIMD2(-travel / 2 + peg.radius + r + 0.002, 0),
            velocity: .zero,
            radius: r
        )
        var kicked = 0.0
        for _ in 0 ..< 40 {
            engine.step(inputs: [:])
            kicked = max(kicked, engine.state.balls[0].velocity.x)
        }
        #expect(kicked > 0.3, "kicked \(kicked)")
    }

    @Test("Every peg is back on its anchor for the next rally, and the wire carries where they are")
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
