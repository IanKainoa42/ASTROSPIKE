import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Free-for-all: three or four pilots, one goal each down a long field, five
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

    /// Drives the ball flat into goal `goal` through the face on the `sign`
    /// side, mid-mouth, and steps until the rally ends or it plainly missed.
    private func shoot(_ engine: inout SimulationEngine, arena: ArenaGeometry, goal: Int, from sign: Double) -> [SimulationEvent] {
        let centre = arena.goalCentres[goal]
        let y = (arena.netBottomY + arena.portalMouthTopY) / 2
        engine.state.ball = BallState(position: SIMD2(centre + sign * 0.2, y), velocity: SIMD2(-sign * 1.6, 0.4))
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

    @Test("The field is one goal per pilot, evenly spaced, centred, with room at the ends")
    func fieldLayout() {
        for pilots in [3, 4] {
            let arena = ArenaGeometry.freeForAll(pilots: pilots, ballRadius: SimulationConfiguration.online.ballRadius)
            #expect(arena.goalCentres.count == pilots)
            #expect(abs(arena.goalCentres.reduce(0, +)) < 1e-9, "centred")
            for (a, b) in zip(arena.goalCentres, arena.goalCentres.dropFirst()) {
                #expect(abs(b - a - ArenaGeometry.freeForAllGoalSpacing) < 1e-9)
                // Flat roof between neighbouring humps, so a ball can ride
                // from one goal toward the next.
                #expect(b - a > 2 * arena.humpBaseX, "humps overlap at \(pilots) pilots")
            }
            // The end humps meet the roof before the corner arc begins.
            #expect(arena.goalCentres.last! + arena.humpBaseX < arena.cornerTangentX)
            #expect(arena.goalCentres.first! - arena.humpBaseX > -arena.cornerTangentX)
        }
        // The duel court keeps its one goal in the middle.
        #expect(ArenaGeometry.standard.goalCentres == [0])
    }

    @Test("Three pilots take the ends and one wing; four take every seat")
    func seats() {
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 3)).bays == [.cyan, .cyanWing, .orange])
        #expect(FreeForAllState(seats: FreeForAllState.seats(pilots: 4)).bays == [.cyan, .cyanWing, .orangeWing, .orange])
        let (engine, arena) = field(pilots: 4)
        for (bay, seat) in engine.state.freeForAll!.bays.enumerated() {
            let ship = engine.state.ships[seat]!
            #expect(abs(ship.position.x - arena.goalCentres[bay]) < 0.5, "\(seat) starts by its own goal")
            #expect(engine.state.freeForAll!.lives[seat] == FreeForAllState.startingLives)
        }
    }

    @Test("Either face of a goal costs its owner one life, and the ball is served again")
    func eitherFaceCostsALife() {
        for pilots in [3, 4] {
            let (start, arena) = field(pilots: pilots)
            let bays = start.state.freeForAll!.bays
            for goal in arena.goalCentres.indices {
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
        #expect(engine.state.ball.velocity.x < 0, "came back off the face")
        #expect(engine.state.ball.position.x < arena.goalCentres[1])
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
            #expect(abs(engine.state.ships[seat]!.position.x - arena.goalCentres[bay]) < 0.5, "\(seat) by its own goal")
        }
        let serveBay = engine.state.freeForAll!.serveBay
        #expect(abs(engine.state.ball.position.x - arena.goalCentres[serveBay]) < 0.05, "drops from the serving goal")
    }

    @Test("Every other hull is a rival: a lead's bolt hits the seat that is its wing in doubles")
    func boltHitsFormerTeammate() {
        var (engine, _) = field(pilots: 3)
        engine.state.ball.position = .init(1.0, 0.45)
        engine.state.ball.velocity = .zero
        let wing = engine.state.ships[.cyanWing]!
        engine.state.bolts = [BoltState(id: 900, owner: .cyan, seat: .cyan, position: wing.position + .init(0.15, 0),
                                        velocity: .init(-2.6, 0), ticksRemaining: 60)]
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
    @Test("The bot takes rivals' lives far more often than it gives up its own", arguments: [3, 4])
    func botScores(pilots: Int) {
        var rival = 0
        var own = 0
        for offset in [0, 37, 91, 150, 233] {
            var (engine, arena) = field(pilots: pilots)
            for _ in 0 ..< offset { engine.step(inputs: [:]) }
            var bot = FreeForAllPilot(difficulty: .ace, configuration: .online)
            for _ in 0 ..< 60 * 120 {
                let input = bot.input(for: engine.state, seat: .cyanWing, arena: arena, tick: engine.state.tick)
                engine.step(inputs: [.cyanWing: input])
                for case let .lifeLost(seat, _, _) in engine.lastEvents {
                    if seat == .cyanWing { own += 1 } else { rival += 1 }
                }
                if engine.state.match.phase == .finished { break }
            }
        }
        #expect(rival >= 6, "only \(rival) rival lives in 10 minutes")
        #expect(rival >= 2 * own, "rival \(rival), own \(own)")
    }
}
