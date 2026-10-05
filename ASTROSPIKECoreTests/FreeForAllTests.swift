import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Free-for-all: three or four pilots on the round field, one goal each
/// hanging from the hub, gravity out to the rim, five lives, last pilot
/// flying wins.
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

    /// Drives the ball flat into goal `goal` through the face on the `sign`
    /// side of its own frame, mid-mouth, and steps until the rally ends or it
    /// plainly missed.
    private func shoot(_ engine: inout SimulationEngine, arena: ArenaGeometry, goal: Int, from sign: Double) -> [SimulationEvent] {
        let ring = arena.ring!
        let y = (ring.spoke.netBottomY + ring.spoke.portalMouthTopY) / 2
        engine.state.ball = BallState(
            position: ring.toWorld(SIMD2(sign * 0.2, y), spoke: goal),
            velocity: ring.vectorToWorld(SIMD2(-sign * 1.6, 0.4), spoke: goal)
        )
        var events: [SimulationEvent] = []
        for _ in 0 ..< 40 {
            engine.step(inputs: [:])
            events += engine.lastEvents
            if engine.state.match.phase != .playing { break }
        }
        return events
    }

    private func livesLost(_ events: [SimulationEvent]) -> [Seat] {
        events.compactMap { if case let .lifeLost(seat, _, _) = $0 { seat } else { nil } }
    }

    @Test("The field is a ring: one goal per pilot evenly round the hub, the duel's drop under each")
    func fieldLayout() {
        let ballRadius = SimulationConfiguration.online.ballRadius
        let duel = ArenaGeometry.standard(ballRadius: ballRadius)
        for pilots in [3, 4] {
            let arena = ArenaGeometry.freeForAll(pilots: pilots, ballRadius: ballRadius)
            let ring = arena.ring!
            #expect(arena.goalCount == pilots)
            #expect(abs(ring.spokeAngles[0] + .pi / 2) < 1e-9, "goal 0 hangs straight down")
            for (a, b) in zip(ring.spokeAngles, ring.spokeAngles.dropFirst()) {
                #expect(abs(b - a - 2 * .pi / Double(pilots)) < 1e-9, "evenly spaced")
            }
            #expect(abs(ring.rimRadius - ring.hubRadius - (duel.humpUndersideY - duel.floorY)) < 1e-9)
            for goal in ring.spokeAngles.indices {
                // Every goal's own frame is the duel court round its net.
                let point = SIMD2(0.3, -0.2)
                #expect(simd_length(ring.toLocal(ring.toWorld(point, spoke: goal), spoke: goal) - point) < 1e-9)
                let floor = ring.toWorld(SIMD2(0, duel.floorY), spoke: goal)
                #expect(abs(simd_length(floor) - ring.rimRadius) < 1e-9, "the duel floor is the rim")
                #expect(ring.spokeIndex(nearest: ring.mouthCentre(goal)) == goal)
            }
        }
        #expect(ArenaGeometry.standard.ring == nil, "the duel court stays a rectangle")
    }

    @Test("Gravity pulls out to the rim: a ball let go anywhere lands on it")
    func gravityPullsOut() {
        let (start, arena) = field(pilots: 4)
        let ring = arena.ring!
        // Between the goals, so the drop misses every lip and cap.
        for bearing in stride(from: Double.pi / 8, to: 2 * .pi, by: .pi / 4) {
            var engine = start
            for seat in Array(engine.state.ships.keys) { engine.state.ships[seat] = nil }
            let out = SIMD2(cos(bearing), sin(bearing))
            engine.state.ball = BallState(position: out * (ring.hubRadius + 0.3), velocity: .zero)
            engine.state.serveTicksRemaining = 0
            for _ in 0 ..< 1200 { engine.step(inputs: [:]) }
            #expect(abs(simd_length(engine.state.ball.position) - (ring.rimRadius - ring.ballRadius)) < 0.01, "bearing \(bearing)")
        }
    }

    @Test("Three pilots take the ends and one wing; four take every seat; everyone starts under their own goal")
    func seats() {
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 3)).bays == [.cyan, .cyanWing, .orange])
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 4)).bays == [.cyan, .cyanWing, .orangeWing, .orange])
        let (engine, arena) = field(pilots: 4)
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() {
            let ship = engine.state.ships[seat]!
            #expect(arena.ring!.spokeIndex(nearest: ship.position) == bay, "\(seat) starts by its own goal")
            #expect(engine.state.freeForAll!.lives[seat] == FreeForAllState.startingLives)
        }
    }

    @Test("Either face of a goal costs its owner one life, and the ball is served again")
    func eitherFaceCostsALife() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let bays = start.state.freeForAll!.bays
            for goal in 0 ..< arena.goalCount {
                for sign in [-1.0, 1.0] {
                    var engine = start
                    let events = shoot(&engine, arena: arena, goal: goal, from: sign)
                    #expect(livesLost(events) == [bays[goal]], "\(pilots) pilots, goal \(goal), face \(sign)")
                    #expect(engine.state.freeForAll!.lives[bays[goal]] == FreeForAllState.startingLives - 1)
                    #expect(engine.state.match.phase == .serve)
                    #expect(engine.state.freeForAll!.serveBay == goal, "served from the goal that conceded")
                }
            }
        }
    }

    @Test("A knocked-out pilot's goal is solid: the ball bounces off it")
    func solidGoal() {
        var (engine, arena) = field(pilots: 3)
        engine.state.freeForAll!.lives[.cyanWing] = 0
        engine.state.ships[.cyanWing] = nil
        let events = shoot(&engine, arena: arena, goal: 1, from: -1)
        #expect(livesLost(events).isEmpty)
        #expect(engine.state.match.phase == .playing)
        let ring = arena.ring!
        #expect(ring.vectorToLocal(engine.state.ball.velocity, spoke: 1).x < 0, "came back off the face")
        #expect(ring.toLocal(engine.state.ball.position, spoke: 1).x < 0)
    }

    @Test("The last life knocks a pilot out; the next serve drops from the nearest goal still open")
    func knockout() {
        var (engine, arena) = field(pilots: 4)
        engine.state.freeForAll!.lives[.cyan] = 1
        let events = shoot(&engine, arena: arena, goal: 0, from: 1)
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
        let events = shoot(&engine, arena: arena, goal: 0, from: 1)
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

    @Test("Restart drop from the pause menu keeps the field: nobody comes back, everyone by their own goal")
    func restartDropKeepsTheField() {
        var (engine, arena) = field(pilots: 4)
        engine.state.freeForAll!.lives[.cyan] = 1
        _ = shoot(&engine, arena: arena, goal: 0, from: 1)
        let lives = engine.state.freeForAll!.lives
        engine.prepareNextRally(mirrored: false)
        #expect(Set(engine.state.ships.keys) == [.cyanWing, .orangeWing, .orange], "the knocked-out pilot stays out")
        #expect(engine.state.freeForAll!.lives == lives)
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() where seat != .cyan {
            #expect(arena.ring!.spokeIndex(nearest: engine.state.ships[seat]!.position) == bay, "\(seat) by its own goal")
        }
        let serveBay = engine.state.freeForAll!.serveBay
        #expect(abs(arena.ring!.toLocal(engine.state.ball.position, spoke: serveBay).x) < 0.05, "drops from the serving goal")
    }

    @Test("Every other hull is a rival: a lead's bolt hits the seat that is its wing in doubles")
    func boltHitsFormerTeammate() {
        var (engine, arena) = field(pilots: 3)
        let wing = engine.state.ships[.cyanWing]!
        // Fired straight out at the wing from the hub side, the ball across
        // the ring out of the way.
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

    /// The bot is chaotic, so judge it over several starts rather than one.
    /// Alone against idle hulls it averages about 0.4 lives a minute at three
    /// pilots and 0.7 at four (200-minute samples): on the ring it carries the
    /// ball a third of the way round to the next goal on its own.
    @Test("The bot takes rivals' lives far more often than it gives up its own", arguments: [3, 4])
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
        #expect(rival >= 5, "only \(rival) rival lives in 20 minutes")
        #expect(rival >= 2 * own, "rival \(rival), own \(own)")
    }
}
