import Foundation
import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Doubles")
struct DoublesTests {
    private func doublesEngine() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.configureRoster(Seat.doubles)
        engine.beginPlay()
        return engine
    }

    @Test("Seats map to teams and partners")
    func seatsAndPartners() {
        #expect(Seat.cyan.team == .cyan)
        #expect(Seat.cyanWing.team == .cyan)
        #expect(Seat.orangeWing.team == .orange)
        #expect(Seat.cyan.partner == .cyanWing)
        #expect(Seat.orangeWing.partner == .orange)
        #expect(Seat.lead(.orange) == .orange)
        #expect(Seat.wing(.cyan) == .cyanWing)
        #expect(Seat.singles == [.cyan, .orange])
        #expect(Seat.doubles.count == 4)
    }

    @Test("Wings spawn behind their leads on their own side")
    func wingSpawns() {
        let engine = doublesEngine()
        let ships = engine.state.ships
        #expect(ships.count == 4)
        #expect(ships[.cyan]?.position.x == -0.55)
        #expect(ships[.cyanWing]?.position.x == -0.80)
        #expect(ships[.orange]?.position.x == 0.55)
        #expect(ships[.orangeWing]?.position.x == 0.80)
        #expect(ships[.cyanWing]?.homeSide == .cyan)
        #expect(ships[.orangeWing]?.homeSide == .orange)
        // The team subscript still reads the lead.
        #expect(ships[team: .cyan] == ships[.cyan])
    }

    @Test("A rally reset keeps every seat filled")
    func rallyResetKeepsRoster() {
        var engine = doublesEngine()
        for tick in UInt64(0) ..< 600 {
            engine.step(inputs: [.cyanWing: PlayerInput(tick: tick, torque: 0, thrust: true)])
            if engine.state.match.phase != .playing { break }
        }
        engine.prepareNextRally(mirrored: false)
        #expect(Set(engine.state.ships.keys) == Seat.doubles)
        #expect(engine.state.ships[.cyanWing]?.position == SIMD2(-0.80, -0.45))
    }

    @Test("Four ships step for a whole rally without losing anyone")
    func fourShipsStep() {
        var engine = doublesEngine()
        var pilots: [Seat: AIController] = [:]
        for seat in Seat.allCases { pilots[seat] = AIController(difficulty: .pilot) }
        for _ in 0 ..< 1800 {
            let tick = engine.state.tick
            var inputs: [Seat: PlayerInput] = [:]
            for seat in Seat.allCases {
                inputs[seat] = pilots[seat]!.input(for: engine.state, seat: seat, tick: tick)
            }
            engine.step(inputs: inputs)
            #expect(engine.state.ships.count == 4)
        }
    }

    @Test("Teammates knock into each other")
    func teammatesCollide() {
        var engine = doublesEngine()
        engine.state.ships[.cyan] = ShipState(position: SIMD2(-0.50, -0.20), velocity: SIMD2(-6.0, 0), angle: .pi / 2)
        engine.state.ships[.cyanWing] = ShipState(position: SIMD2(-0.62, -0.20), velocity: SIMD2(6.0, 0), angle: .pi / 2)
        engine.step(inputs: [:])
        let lead = engine.state.ships[.cyan]!
        let wing = engine.state.ships[.cyanWing]!
        #expect(lead.velocity.x > -6.0)
        #expect(wing.velocity.x < 6.0)
        #expect(engine.lastEvents.contains { if case .collisionEffect = $0 { true } else { false } })
    }

    @Test("A wing's touch counts for its team")
    func wingTouchCountsForTeam() {
        var engine = doublesEngine()
        engine.state.ships[.cyan] = ShipState(position: SIMD2(-0.55, -0.45), angle: .pi / 2)
        engine.state.ships[.cyanWing] = ShipState(position: SIMD2(-0.30, -0.10), angle: .pi / 2)
        engine.state.ball = BallState(position: SIMD2(-0.30, 0.05), velocity: SIMD2(0, -1.0))
        for _ in 0 ..< 30 { engine.step(inputs: [:]) }
        #expect(engine.state.match.shipTouches.cyan >= 1)
        #expect(engine.state.match.shipTouches.orange == 0)
    }

    @Test("The AI wing hangs back when its lead is closer to the ball")
    func wingSupports() {
        var engine = doublesEngine()
        engine.state.ships[.orange] = ShipState(position: SIMD2(0.30, -0.10), angle: .pi / 2)
        engine.state.ships[.orangeWing] = ShipState(position: SIMD2(0.80, -0.45), angle: .pi / 2)
        engine.state.ball = BallState(position: SIMD2(0.25, 0.10), velocity: .zero)
        var wing = AIController(difficulty: .ace)
        var wingPositions: [SIMD2<Double>] = []
        for _ in 0 ..< 240 {
            let tick = engine.state.tick
            let input = wing.input(for: engine.state, seat: .orangeWing, tick: tick)
            #expect(input.fire == false)
            // Pin the lead as well as the ball: left idle it falls to the
            // floor and ends up farther from the ball than the wing.
            engine.state.ball = BallState(position: SIMD2(0.25, 0.10), velocity: .zero)
            engine.state.ships[.orange] = ShipState(position: SIMD2(0.30, -0.10), angle: .pi / 2)
            engine.step(inputs: [.orangeWing: input])
            wingPositions.append(engine.state.ships[.orangeWing]!.position)
        }
        // Two seconds later it is still nowhere near the ball its lead owns.
        let closest = wingPositions.map { simd_distance($0, SIMD2(0.25, 0.10)) }.min() ?? 0
        #expect(closest > 0.25)
    }

    @Test("Seat-keyed messages and seating survive the wire")
    func wireRoundTrip() throws {
        let codec = WireCodec()
        let input = WireEnvelope(sequence: 1, payload: .input(seat: .orangeWing, value: PlayerInput(tick: 5, torque: 0.5, thrust: true, fire: true)))
        let profile = WireEnvelope(sequence: 2, payload: .profile(seat: .cyanWing, hull: .manta))
        let seating = WireEnvelope(
            sequence: 3,
            payload: .seating(plan: ["G:1": .cyan, "G:2": .orange, "G:3": .cyanWing], tuning: FlightTuningSnapshot.defaults, teamUp: true)
        )
        var snapshotEngine = doublesEngine()
        snapshotEngine.step(inputs: [:])
        let snapshot = WireEnvelope(sequence: 4, payload: .snapshot(snapshotEngine.state))
        for envelope in [input, profile, seating, snapshot] {
            #expect(try codec.decode(codec.encode(envelope)) == envelope)
        }
        #expect(WireEnvelope.currentVersion == 26)
    }

    @Test("A team-up seats the invited friend beside the host")
    func teamUpSeating() {
        let plan = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:2"], teamUp: true)
        #expect(plan == ["G:1": .cyan, "G:2": .cyanWing])
        #expect(Set(plan.values.map(\.team)) == [.cyan])
        let four = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:4", "G:2", "G:3"], teamUp: true)
        #expect(four == ["G:1": .cyan, "G:2": .cyanWing, "G:3": .orange, "G:4": .orangeWing])
    }

    @Test("A duel still puts the second pilot across the net")
    func duelSeating() {
        let plan = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:2"], teamUp: false)
        #expect(plan == ["G:1": .cyan, "G:2": .orange])
        let three = OnlineSeating.plan(localID: "G:1", peerIDs: ["G:3", "G:2"], teamUp: false)
        #expect(three == ["G:1": .cyan, "G:2": .orange, "G:3": .cyanWing])
    }

    @Test("Two friends teamed up play doubles, not a duel")
    func teamUpRoster() {
        #expect(OnlineSeating.roster(filled: [.cyan, .cyanWing], teamUp: true) == Seat.doubles)
        #expect(OnlineSeating.roster(filled: [.cyan, .orange], teamUp: false) == Seat.singles)
        #expect(OnlineSeating.roster(filled: [.cyan, .orange, .cyanWing], teamUp: false) == Seat.doubles)
    }

    @Test("A teammate walking out hands their chair to a bot")
    func teammateDropBenches() {
        let teamUp: [String: Seat] = ["G:1": .cyan, "G:2": .cyanWing]
        #expect(OnlineSeating.seatingAfterHold(seating: teamUp, dropped: ["G:2"]) == ["G:1": .cyan])
        let four: [String: Seat] = ["G:1": .cyan, "G:2": .cyanWing, "G:3": .orange, "G:4": .orangeWing]
        #expect(OnlineSeating.seatingAfterHold(seating: four, dropped: ["G:3"])?.count == 3)
    }

    @Test("The last human on a side walking out is still a forfeit")
    func lastHumanDropForfeits() {
        let duel: [String: Seat] = ["G:1": .cyan, "G:2": .orange]
        #expect(OnlineSeating.seatingAfterHold(seating: duel, dropped: ["G:2"]) == nil)
        let three: [String: Seat] = ["G:1": .cyan, "G:2": .orange, "G:3": .cyanWing]
        #expect(OnlineSeating.seatingAfterHold(seating: three, dropped: ["G:2"]) == nil)
        let four: [String: Seat] = ["G:1": .cyan, "G:2": .cyanWing, "G:3": .orange, "G:4": .orangeWing]
        #expect(OnlineSeating.seatingAfterHold(seating: four, dropped: ["G:3", "G:4"]) == nil)
    }

    // MARK: Two balls on the big court

    private func bigCourtEngine() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        let configuration = SimulationConfiguration.doubles(from: SimulationConfiguration())
        engine.updateConfiguration(configuration)
        engine.updateArena(.doubles(ballRadius: configuration.ballRadius))
        engine.configureRoster(Seat.doubles)
        engine.beginPlay()
        return engine
    }

    @Test("Doubles is two small balls on a court a quarter bigger")
    func doublesConfiguration() {
        let base = SimulationConfiguration(ballRadius: BallState.nominalRadius * 2)
        let doubles = SimulationConfiguration.doubles(from: base)
        #expect(doubles.ballCount == 2)
        #expect(doubles.ballRadius == BallState.nominalRadius)
        #expect(SimulationConfiguration(ballCount: 9).ballCount == SimulationConfiguration.maximumBallCount)
        let court = ArenaGeometry.doubles(ballRadius: doubles.ballRadius)
        #expect(court.halfWidth == ArenaGeometry.standard.halfWidth * 1.25)
        #expect(court.ceilingY == ArenaGeometry.standard.ceilingY * 1.25)
        #expect(court.widthScale == 1.25)
        #expect(abs(court.heightScale - 1.25) < 1e-9)
        #expect(ArenaGeometry.standard.widthScale == 1)
    }

    @Test("Two balls are staged apart and drift to opposite halves")
    func twoBallServe() {
        var engine = bigCourtEngine()
        #expect(engine.state.balls.count == 2)
        let staged = engine.state.balls
        #expect(staged[0].position.x * staged[1].position.x < 0)
        #expect(simd_distance(staged[0].position, staged[1].position) > staged[0].radius * 2)
        for _ in 0 ..< 120 { engine.step(inputs: [:]) }
        let balls = engine.state.balls
        #expect(balls[0].position.x * balls[1].position.x < 0)
        #expect(balls[0].velocity.x * balls[1].velocity.x < 0)
        // The compatibility accessor still reads the first ball.
        #expect(engine.state.ball == balls[0])
    }

    @Test("Spawns stretch with the court")
    func bigCourtSpawns() {
        let engine = bigCourtEngine()
        #expect(abs(engine.state.ships[.cyan]!.position.x - (-0.55 * 1.25)) < 1e-9)
        #expect(abs(engine.state.ships[.orangeWing]!.position.x - (0.80 * 1.25)) < 1e-9)
        #expect(abs(engine.state.ships[.cyan]!.position.y - (-0.45 * 1.25)) < 1e-9)
    }

    @Test("Two balls bounce off each other")
    func ballsCollide() {
        var engine = bigCourtEngine()
        engine.state.balls[0] = BallState(position: SIMD2(-0.10, -0.10), velocity: SIMD2(2.0, 0), radius: BallState.nominalRadius)
        engine.state.balls[1] = BallState(position: SIMD2(0.10, -0.10), velocity: SIMD2(-2.0, 0), radius: BallState.nominalRadius)
        var closest = Double.infinity
        var hit = false
        for _ in 0 ..< 60 {
            engine.step(inputs: [:])
            closest = min(closest, simd_distance(engine.state.balls[0].position, engine.state.balls[1].position))
            hit = hit || engine.lastEvents.contains { if case .collisionEffect = $0 { true } else { false } }
        }
        // They never pass through each other, and they come apart again.
        #expect(closest >= BallState.nominalRadius * 2 - 0.002)
        #expect(engine.state.balls[0].velocity.x < 0)
        #expect(engine.state.balls[1].velocity.x > 0)
        #expect(hit)
    }

    @Test("Partners split the two balls between them")
    func partnersSplitBalls() {
        var engine = bigCourtEngine()
        engine.state.ships[.orange] = ShipState(position: SIMD2(0.40, -0.20), angle: .pi / 2)
        engine.state.ships[.orangeWing] = ShipState(position: SIMD2(0.90, -0.20), angle: .pi / 2)
        engine.state.balls[0] = BallState(position: SIMD2(0.45, 0.10), velocity: .zero, radius: BallState.nominalRadius)
        engine.state.balls[1] = BallState(position: SIMD2(0.85, 0.10), velocity: .zero, radius: BallState.nominalRadius)
        let lead = AIController.focusBall(in: engine.state, seat: .orange, ship: engine.state.ships[.orange]!)
        let wing = AIController.focusBall(in: engine.state, seat: .orangeWing, ship: engine.state.ships[.orangeWing]!)
        #expect(lead == 0)
        #expect(wing == 1)
        // Both near the same ball: the wing takes the other one.
        engine.state.ships[.orangeWing] = ShipState(position: SIMD2(0.50, -0.20), angle: .pi / 2)
        #expect(AIController.focusBall(in: engine.state, seat: .orangeWing, ship: engine.state.ships[.orangeWing]!) == 1)
        #expect(AIController.focusBall(in: engine.state, seat: .orange, ship: engine.state.ships[.orange]!) == 0)
    }

    @Test("A guest's engine follows the host: no points of its own")
    func followerKeepsNoBook() {
        func dropBall(follows: Bool) -> SimulationEngine {
            var engine = doublesEngine()
            engine.followsHost = follows
            // A ball dropped onto the cyan floor, over and over: the moment
            // it comes off the deck it is put back above it, clear of every
            // hull, so the only thing that can end a rally is the floor.
            for _ in 0 ..< 600 {
                if engine.state.match.phase == .playing, engine.state.ball.velocity.y >= 0 {
                    engine.state.ball = BallState(position: SIMD2(-0.30, -0.60), velocity: SIMD2(0, -3))
                }
                engine.step(inputs: [:])
            }
            return engine
        }
        let host = dropBall(follows: false)
        #expect(host.state.match.score.orange > 0)
        let guest = dropBall(follows: true)
        #expect(guest.state.match.score == Score())
        #expect(guest.state.match.phase == .playing)
        #expect(guest.state.tick == 600)
        // Effects still show: the guest may spark, it just may not score.
        #expect(!guest.lastEvents.contains { if case .point = $0 { true } else { false } })
    }

    @Test("A doubles snapshot fits in one datagram with room to spare")
    func snapshotSize() throws {
        var engine = bigCourtEngine()
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0.5, thrust: true, fire: true)])
        for _ in 0 ..< 30 { engine.step(inputs: [.cyan: PlayerInput(tick: engine.state.tick, torque: 0, thrust: false, fire: true)]) }
        let data = try WireCodec().encode(WireEnvelope(sequence: 1, payload: .snapshot(engine.state)))
        #expect(data.count < 1400, "snapshot is \(data.count) bytes")
    }

    @Test("The host seats the pilots who are here when the count sticks")
    func seatsPastAStuckCount() {
        // Everyone accounted for: seat at once.
        #expect(OnlineSeating.shouldSeat(expected: 0, declined: 0, connectedPeers: 1, graceElapsed: false))
        // Game Center still says one more is coming, but they are already in.
        #expect(!OnlineSeating.shouldSeat(expected: 1, declined: 0, connectedPeers: 1, graceElapsed: false))
        #expect(OnlineSeating.shouldSeat(expected: 1, declined: 0, connectedPeers: 1, graceElapsed: true))
        // Nobody at the table is never a reason to seat it.
        #expect(!OnlineSeating.shouldSeat(expected: 0, declined: 0, connectedPeers: 0, graceElapsed: true))
        // A decline still opens the door without waiting out the grace.
        #expect(OnlineSeating.shouldSeat(expected: 1, declined: 1, connectedPeers: 1, graceElapsed: false))
    }
}
