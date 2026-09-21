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
            payload: .seating(plan: ["G:1": .cyan, "G:2": .orange, "G:3": .cyanWing], tuning: FlightTuningSnapshot.defaults)
        )
        var snapshotEngine = doublesEngine()
        snapshotEngine.step(inputs: [:])
        let snapshot = WireEnvelope(sequence: 4, payload: .snapshot(snapshotEngine.state))
        for envelope in [input, profile, seating, snapshot] {
            #expect(try codec.decode(codec.encode(envelope)) == envelope)
        }
        #expect(WireEnvelope.currentVersion == 21)
    }
}
