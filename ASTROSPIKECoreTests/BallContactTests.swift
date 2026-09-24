import Testing
import simd
@testable import ASTROSPIKECore

/// The ball is always hittable: a hull never ghosts through it, whether it is
/// hanging for a serve, already overlapping the hull, or pinned to a wall.
@Suite("Ball contact")
struct BallContactTests {
    private static let beside = SIMD2(
        -(ArenaGeometry.standard.netHalfWidth + BallState.nominalRadius + 0.004),
        0.30
    )

    /// The hull is sitting inside the ball, skin included, by more than a hair.
    private static func hullOverlapsBall(_ engine: SimulationEngine, seat: Seat) -> Bool {
        let ship = engine.state.ships[seat]!
        let ball = engine.state.ball
        let offset = ball.position - ship.position
        let local = SIMD2(
            simd_dot(offset, SIMD2(cos(ship.angle), sin(ship.angle))),
            simd_dot(offset, SIMD2(-sin(ship.angle), cos(ship.angle)))
        )
        let hull = ShipHitbox.shared
        return hull.contains(local) || hull.distance(from: local) < ball.radius + ShipHitbox.skin - 0.002
    }

    /// A point just scored, the next ball hanging for the serve.
    private static func servingEngine() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(position: beside, velocity: SIMD2(2, 0))
        engine.step(inputs: [:])
        return engine
    }

    @Test("A hull cannot fly through the ball hanging for a serve")
    func stagedBallIsSolid() {
        var engine = Self.servingEngine()
        #expect(engine.state.match.phase == .serve)
        let ball = engine.state.ball
        engine.state.ships[.cyan] = ShipState(
            position: SIMD2(ball.position.x - 0.15, ball.position.y),
            velocity: SIMD2(1.5, 0),
            angle: 0
        )

        for _ in 0 ..< 20 where engine.state.match.phase == .serve {
            engine.step(inputs: [:])
            let nose = engine.state.ships[.cyan]!.position.x + ShipHitbox.shared.noseReach
            #expect(nose <= engine.state.ball.position.x - engine.state.ball.radius + 0.000_1)
        }
        #expect(engine.state.ball.position == ball.position, "the staged ball does not move")
    }

    @Test("A ball already touching the hull is still struck")
    func overlappingBallIsStruck() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(position: SIMD2(-0.40, 0.30), velocity: SIMD2(3, 0), angle: 0)
        let r = BallState.nominalRadius
        engine.state.ball = BallState(
            position: SIMD2(-0.40 + ShipHitbox.shared.noseReach + r - 0.01, 0.30),
            velocity: .zero,
            radius: r
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x > 2)
        #expect(engine.state.lastBallToucher == .cyan)
    }

    /// Swept, not hand-picked: before the fix 444 of 480 runs like these
    /// ended with the hull swallowing the ball.
    @Test("A ball pinned to the wall stops the hull instead of sinking into it", arguments: [-0.20, 0.0, 0.20])
    func pinnedBallStopsHull(y: Double) {
        let wall = SimulationEngine.testing().arena.halfWidth
        let r = BallState.nominalRadius
        let hull = ShipHitbox.shared
        for speed in [0.5, 1.5, 3.0] {
            for angle in [-0.3, 0.0, 0.3] {
                var engine = SimulationEngine.testing()
                engine.state.ships[.orange] = ShipState(position: SIMD2(wall - 0.30, y), velocity: SIMD2(speed, 0), angle: angle)
                engine.state.ball = BallState(position: SIMD2(wall - r - 0.001, y), velocity: .zero, radius: r)
                var overlapped = 0
                for _ in 0 ..< 90 {
                    engine.step(inputs: [.orange: PlayerInput(tick: 0, torque: 0, thrust: true)])
                    let ship = engine.state.ships[.orange]!
                    let offset = engine.state.ball.position - ship.position
                    let local = SIMD2(
                        simd_dot(offset, SIMD2(cos(ship.angle), sin(ship.angle))),
                        simd_dot(offset, SIMD2(-sin(ship.angle), cos(ship.angle)))
                    )
                    if hull.contains(local) || hull.distance(from: local) < r + ShipHitbox.skin - 0.002 {
                        overlapped += 1
                    }
                }
                #expect(overlapped == 0, "speed \(speed) angle \(angle): hull inside the ball for \(overlapped) steps")
            }
        }
    }

    @Test("Serves differ in drift, drop and countdown, but always go to the conceding side")
    func servesVary() {
        var drifts: Set<Double> = []
        var delays: Set<UInt64> = []
        for rally in 0 ..< 8 {
            var engine = SimulationEngine.testing()
            for _ in 0 ..< rally { engine.step(inputs: [:]) }
            engine.state.ball = BallState(position: Self.beside, velocity: SIMD2(2, 0))
            engine.step(inputs: [:])
            #expect(engine.state.match.phase == .serve)
            delays.insert(engine.state.serveTicksRemaining)
            while engine.state.match.phase == .serve { engine.step(inputs: [:]) }
            let v = engine.state.ball.velocity
            // Orange scored through the cyan face; cyan conceded, on the left.
            #expect(v.x < 0)
            drifts.insert(v.x)
        }
        #expect(drifts.count >= 6)
        #expect(delays.count >= 4)
    }

    @Test("The same moment serves the same ball, so host and guest agree")
    func servesAreRepeatable() {
        func serve() -> (UInt64, SIMD2<Double>) {
            var engine = Self.servingEngine()
            let delay = engine.state.serveTicksRemaining
            while engine.state.match.phase == .serve { engine.step(inputs: [:]) }
            return (delay, engine.state.ball.velocity)
        }
        #expect(serve() == serve())
    }

    /// Online: the guest rebuilds its engine from each host snapshot and
    /// flies the physics itself between them. Started from the same
    /// snapshot mid-serve with the same inputs, it has to stop against the
    /// same staged ball and serve the same ball on the same tick.
    @Test("An online guest stops on the staged ball and serves the same ball as the host")
    func guestMatchesHostThroughTheServe() {
        var host = Self.servingEngine()
        let ball = host.state.ball
        host.state.ships[.cyan] = ShipState(
            position: SIMD2(ball.position.x - 0.15, ball.position.y),
            velocity: SIMD2(1.5, 0),
            angle: 0
        )
        // A few ticks in, the way a snapshot catches the serve in flight.
        for _ in 0 ..< 5 { host.step(inputs: [:]) }
        var guest = SimulationEngine(state: host.state, configuration: host.configuration, arena: host.arena)
        guest.followsHost = true

        let push = PlayerInput(tick: 0, torque: 0, thrust: true)
        var hostRelease: (UInt64, SIMD2<Double>)?
        var guestRelease: (UInt64, SIMD2<Double>)?
        for _ in 0 ..< 200 where hostRelease == nil || guestRelease == nil {
            host.step(inputs: [.cyan: push])
            guest.step(inputs: [.cyan: push])
            for engine in [host, guest] where engine.state.match.phase == .serve {
                #expect(!Self.hullOverlapsBall(engine, seat: .cyan))
            }
            if hostRelease == nil, host.state.match.phase == .playing {
                hostRelease = (host.state.tick, host.state.ball.velocity)
            }
            if guestRelease == nil, guest.state.match.phase == .playing {
                guestRelease = (guest.state.tick, guest.state.ball.velocity)
            }
        }
        #expect(hostRelease != nil)
        #expect(hostRelease?.0 == guestRelease?.0)
        #expect(hostRelease?.1 == guestRelease?.1)
    }
}
