import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

/// Build 121: the stat book. Goals are credited to the last hull or bolt on
/// the ball, a bolt into a ball the shooter's beam just held is a slam dunk,
/// and only the rulebook's keeper writes the book.
@Suite("Match stats")
struct MatchStatsTests {
    // MARK: - The book on its own

    @Test("A goal goes to the last play on the ball, by kind")
    func creditByKind() {
        var stats = MatchStats()
        #expect(stats.creditGoal(lastPlay: BallPlay(seat: .orange, kind: .hull), defending: .cyan)?.style == .hull)
        #expect(stats.creditGoal(lastPlay: BallPlay(seat: .orange, kind: .bolt), defending: .cyan)?.style == .bolt)
        #expect(stats.creditGoal(lastPlay: BallPlay(seat: .orange, kind: .slamDunk), defending: .cyan)?.style == .slamDunk)
        #expect(stats[.orange] == PilotStats(goals: 3, boltGoals: 2, slamDunks: 1))
    }

    @Test("Putting it in your own goal is an own goal, not a goal")
    func ownGoal() {
        var stats = MatchStats()
        let credit = stats.creditGoal(lastPlay: BallPlay(seat: .cyanWing, kind: .slamDunk), defending: .cyan)
        #expect(credit?.seat == .cyanWing)
        #expect(credit?.style == .ownGoal)
        #expect(stats[.cyanWing] == PilotStats(ownGoals: 1))
    }

    @Test("A ball nobody played is nobody's goal")
    func unplayedBall() {
        var stats = MatchStats()
        #expect(stats.creditGoal(lastPlay: nil, defending: .cyan) == nil)
        #expect(stats == MatchStats())
    }

    @Test("The longest rally is the most crossings in one point")
    func longestRally() {
        var stats = MatchStats()
        for _ in 0 ..< 4 { stats.ballCrossedCenter() }
        stats.pointEnded()
        for _ in 0 ..< 2 { stats.ballCrossedCenter() }
        #expect(stats.longestRally == 4)
        #expect(stats.rallyCrossings == 2)
    }

    @Test("Only boards the pilot scored on are sent")
    func submissionsSkipZeros() {
        var stats = MatchStats()
        stats[.cyan].goals = 2
        stats[.cyan].zaps = 5
        stats[.orange].slamDunks = 1
        stats.longestRally = 3
        let sent = StatBoard.submissions(from: stats, for: .cyan)
        #expect(sent.map(\.board) == [.goals, .zaps, .longestRally])
        #expect(sent.map(\.value) == [2, 5, 3])
    }

    // MARK: - Goals through the engine

    /// The ball about to cross the cyan goal face mid-mouth, so cyan concedes.
    private func ballIntoCyanGoal(_ engine: inout SimulationEngine, lastPlay: BallPlay?) {
        let arena = engine.arena
        let mouthY = (arena.netBottomY + arena.portalMouthTopY) / 2
        engine.state.ball = BallState(
            position: SIMD2(-(arena.netHalfWidth + BallState.nominalRadius + 0.004), mouthY),
            velocity: SIMD2(2, 0),
            radius: BallState.nominalRadius,
            lastPlay: lastPlay
        )
    }

    private func goalScored(_ events: [SimulationEvent]) -> (seat: Seat, style: GoalStyle)? {
        for event in events { if case let .goalScored(seat, style) = event { return (seat, style) } }
        return nil
    }

    @Test("A slam dunk through the goal books a goal, a bolt goal and a slam, called right after the point")
    func slamThroughTheEngine() {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        ballIntoCyanGoal(&engine, lastPlay: BallPlay(seat: .orange, kind: .slamDunk))
        engine.step(inputs: [:])
        #expect(engine.state.match.score.orange == 1)
        #expect(engine.state.stats[.orange] == PilotStats(goals: 1, boltGoals: 1, slamDunks: 1))
        let pointIndex = engine.lastEvents.firstIndex { if case .point(.orange, .goal) = $0 { true } else { false } }
        #expect(pointIndex != nil)
        if let pointIndex {
            #expect(engine.lastEvents[pointIndex + 1] == .goalScored(seat: .orange, style: .slamDunk))
        }
    }

    @Test("Hulls and own goals through the engine")
    func hullAndOwnGoal() {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        ballIntoCyanGoal(&engine, lastPlay: BallPlay(seat: .cyan, kind: .hull))
        engine.step(inputs: [:])
        #expect(engine.state.match.score.orange == 1, "an own goal still scores for the other side")
        #expect(engine.state.stats[.cyan] == PilotStats(ownGoals: 1))
        #expect(goalScored(engine.lastEvents)?.style == .ownGoal)
    }

    @Test("A goal off nobody scores but credits no one")
    func unplayedGoal() {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        ballIntoCyanGoal(&engine, lastPlay: nil)
        engine.step(inputs: [:])
        #expect(engine.state.match.score.orange == 1)
        #expect(engine.state.stats.pilots.isEmpty)
        #expect(goalScored(engine.lastEvents) == nil)
    }

    @Test("A guest flies the physics but never writes the book")
    func guestKeepsNoBook() {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        engine.followsHost = true
        ballIntoCyanGoal(&engine, lastPlay: BallPlay(seat: .orange, kind: .bolt))
        engine.step(inputs: [:])
        #expect(engine.state.stats == MatchStats())
    }

    @Test("Play Again clears the book")
    func restartClears() {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        ballIntoCyanGoal(&engine, lastPlay: BallPlay(seat: .orange, kind: .hull))
        engine.step(inputs: [:])
        #expect(engine.state.stats[.orange].goals == 1)
        engine.restartMatch()
        #expect(engine.state.stats == MatchStats())
    }

    // MARK: - Bolts and the beam

    /// Cyan nose-up on its own half, the ball hanging `gap` above the nose.
    private func ballOverCyan(gap: Double) -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        let ship = engine.state.ships[.cyan]!
        engine.state.ships[.orange]!.position = .init(0.6, -0.45)
        engine.state.ball = BallState(position: ship.position + .init(0, gap), radius: BallState.nominalRadius)
        return engine
    }

    /// Holds the beam for `holdTicks`, waits `waitTicks` with it off, then
    /// fires and steps until the bolt has landed or gone.
    private func beamThenFire(holdTicks: Int, waitTicks: Int) -> SimulationEngine {
        var engine = ballOverCyan(gap: 0.22)
        var tick: UInt64 = 0
        func step(_ input: PlayerInput) {
            engine.step(inputs: [.cyan: input])
            tick += 1
        }
        for _ in 0 ..< holdTicks { step(PlayerInput(tick: tick, torque: 0, thrust: false, tractor: true)) }
        for _ in 0 ..< waitTicks { step(.idle(tick: tick)) }
        step(PlayerInput(tick: tick, torque: 0, thrust: false, fire: true))
        for _ in 0 ..< 20 where engine.state.stats[.cyan].boltHits == 0 { step(.idle(tick: tick)) }
        return engine
    }

    @Test("Bolting a ball the beam is holding marks it a slam")
    func beamThenBoltIsASlam() {
        let engine = beamThenFire(holdTicks: 6, waitTicks: 0)
        #expect(engine.state.stats[.cyan].boltHits == 1)
        #expect(engine.state.ball.lastPlay == BallPlay(seat: .cyan, kind: .slamDunk))
    }

    @Test("A bolt with no beam on the ball is a plain shot")
    func boltAloneIsNotASlam() {
        let engine = beamThenFire(holdTicks: 0, waitTicks: 0)
        #expect(engine.state.stats[.cyan].boltHits == 1)
        #expect(engine.state.ball.lastPlay == BallPlay(seat: .cyan, kind: .bolt))
    }

    @Test("A bolt long after the beam let go is a plain shot")
    func staleHoldIsNotASlam() {
        let window = Int((SimulationEngine.slamWindow / SimulationConfiguration().stepDuration).rounded())
        let engine = beamThenFire(holdTicks: 6, waitTicks: window + 10)
        #expect(engine.state.stats[.cyan].boltHits == 1)
        #expect(engine.state.ball.lastPlay?.kind == .bolt)
    }

    @Test("A bolt on an enemy hull is a zap for its shooter")
    func zapIsBooked() {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        engine.state.ball.position = .init(0.6, 0.45)
        engine.state.ball.velocity = .zero
        let target = engine.state.ships[.cyan]!.position
        engine.state.bolts = [BoltState(
            id: 900, owner: .orange, position: target + .init(0.15, 0),
            velocity: .init(-2.6, 0), ticksRemaining: 60
        )]
        for tick in UInt64(0) ..< 10 { engine.step(inputs: [.cyan: .idle(tick: tick)]) }
        #expect(engine.state.stats[.orange].zaps == 1)
        #expect(engine.state.stats[.cyan].zaps == 0)
    }

    @Test("The book and the ball's last play ride the snapshot")
    func snapshotCarriesTheBook() throws {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        ballIntoCyanGoal(&engine, lastPlay: BallPlay(seat: .orange, kind: .slamDunk))
        engine.step(inputs: [:])
        engine.state.ball.lastPlay = BallPlay(seat: .cyan, kind: .bolt)
        engine.state.ball.beamHold = BeamHold(seat: .cyan, tick: 7)
        let codec = WireCodec()
        for payload in [WirePayload.snapshot(engine.state), .event(.goalScored(seat: .orangeWing, style: .slamDunk))] {
            let envelope = WireEnvelope(sequence: 1, payload: payload)
            #expect(try codec.decode(codec.encode(envelope)) == envelope)
        }
    }
}
