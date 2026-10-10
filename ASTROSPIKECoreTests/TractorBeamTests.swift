import Foundation
import simd
import Testing
@testable import ASTROSPIKECore

@Suite("Tractor beam")
struct TractorBeamTests {
    private func playing() -> SimulationEngine {
        var engine = SimulationEngine.testing()
        engine.beginPlay()
        return engine
    }

    @Test("A held beam draws a ball ahead of the nose toward the ship without a touch")
    func beamPullsBallIn() {
        var engine = playing()
        let ship = engine.state.ships[.cyan]!
        // Straight ahead of the nose (which points up), inside range.
        engine.state.ball.position = ship.position + .init(0, 0.3)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        let gravityOnly = engine.configuration.gravity.y * engine.configuration.ballGravityMultiplier
            * engine.configuration.stepDuration
        #expect(engine.state.ships[.cyan]!.tractorActive)
        #expect(engine.state.ball.velocity.y < gravityOnly, "the beam adds pull on top of gravity")
        #expect(engine.state.match.shipTouches[.cyan] == 0, "reeling in is not a touch")
    }

    @Test("A ball behind the ship or out of range is left alone")
    func beamHasConeAndRange() {
        var engine = playing()
        let ship = engine.state.ships[.cyan]!
        let gravityOnly = engine.configuration.gravity.y * engine.configuration.ballGravityMultiplier
            * engine.configuration.stepDuration
        // Level with the ship, off to the side: outside the cone.
        engine.state.ball.position = ship.position - .init(0.2, 0)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        #expect(engine.state.ball.velocity.y == gravityOnly)
        engine.state.ball.position = ship.position + .init(0, engine.configuration.tractorRange + 0.05)
        engine.state.ball.velocity = .zero
        engine.step(inputs: [.cyan: PlayerInput(tick: 1, torque: 0, thrust: false, tractor: true)])
        #expect(engine.state.ball.velocity.y == gravityOnly)
    }

    @Test("The beam works anywhere, including deep in the opponent's half")
    func beamWorksAnywhere() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(0.6, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, tractor: true)])
        #expect(engine.state.ships[.cyan]!.tractorActive)
    }

    @Test("The cannon stays holstered deep in the opponent's half")
    func cannonStillHolstered() {
        var engine = playing()
        engine.state.ships[.cyan]!.position = .init(0.6, 0)
        engine.step(inputs: [.cyan: PlayerInput(tick: 0, torque: 0, thrust: false, fire: true)])
        #expect(engine.state.bolts.isEmpty)
    }

    @Test("The drawn cone is the cone that grabs")
    func coneIsNarrowAndLong() {
        let engine = playing()
        // A ball 26 degrees off the nose is outside the cone; 20 is inside.
        #expect(cos(26 * .pi / 180) < SimulationEngine.tractorCone)
        #expect(cos(20 * .pi / 180) > SimulationEngine.tractorCone)
        #expect(engine.configuration.tractorRange > 0.7, "the beam is a long reach")
    }

    /// Zero gravity is the only way to see the beam on its own: gravity is an
    /// outside force and would swamp the very thing under test.
    private func weightless() -> SimulationEngine {
        var engine = playing()
        var configuration = engine.configuration
        configuration.gravity = .zero
        engine.updateConfiguration(configuration)
        return engine
    }

    private func momentum(_ engine: SimulationEngine) -> SIMD2<Double> {
        var total = engine.state.ball.velocity * SimulationEngine.ballMass
        for seat in Seat.allCases {
            total += (engine.state.ships[seat]?.velocity ?? .zero) * SimulationEngine.shipMass
        }
        return total
    }

    @Test("Reeling the ball in drags the hull toward it, and the pair's momentum is unchanged")
    func beamConservesMomentum() {
        var engine = weightless()
        let ship = engine.state.ships[.cyan]!
        engine.state.ball.position = ship.position + .init(0, 0.3)
        engine.state.ball.velocity = .init(0.12, -0.2)
        let before = momentum(engine)
        for tick in 0 ..< 20 {
            engine.step(inputs: [.cyan: PlayerInput(
                tick: UInt64(tick), torque: 0, thrust: false, tractor: true
            )])
        }
        let drift = simd_length(momentum(engine) - before)
        #expect(drift < 1e-9, "the beam invented \(drift) of momentum")
        #expect(engine.state.ships[.cyan]!.velocity.y > 0, "the hull is pulled up toward the ball")
        #expect(engine.state.ball.velocity.y < -0.2, "the ball is still pulled down toward the hull")
    }

    @Test("The grab damps the ball against the ship's frame, not the world's")
    func grabDampsAgainstTheShipNotTheWorld() {
        var engine = weightless()
        let ship = engine.state.ships[.cyan]!
        // Hull and ball drifting sideways together, so there is nothing
        // between them for the grab to bleed off. Damping against the world
        // would drag the ball's 0.5 down to about 0.36 over these 30 steps
        // and leave the hull at 0.5; damping against the hull keeps the pair
        // flying as one. Not exact to the last bit -- the hull's position is
        // integrated a half step before the beam reads it, so the beam axis
        // leans a hair off true and leaks a little sideways pull.
        engine.state.ships[.cyan]!.velocity = .init(0.5, 0)
        engine.state.ball.position = ship.position + .init(0, 0.3)
        engine.state.ball.velocity = .init(0.5, 0)
        for tick in 0 ..< 30 {
            engine.step(inputs: [.cyan: PlayerInput(
                tick: UInt64(tick), torque: 0, thrust: false, tractor: true
            )])
        }
        let ballDrift = engine.state.ball.velocity.x
        let hullDrift = engine.state.ships[.cyan]!.velocity.x
        #expect(engine.configuration.tractorDrag > 0, "the damping under test is switched on")
        #expect(ballDrift > 0.49, "the ball keeps station with the hull, not with the world")
        #expect(abs(ballDrift - hullDrift) < 0.01, "hull and ball still fly as one")
    }

    @Test("S and the down arrow hold the beam; a snapshot with it on still fits an unreliable packet")
    func keysAndWireSize() throws {
        #expect(KeyboardControlMapping.action(forKeyCode: 22) == .tractor)
        #expect(KeyboardControlMapping.action(forKeyCode: 81) == .tractor)
        var engine = playing()
        engine.state.ships[.cyan]!.tractorActive = true
        let data = try WireCodec().encode(WireEnvelope(sequence: 1, payload: .snapshot(engine.state)))
        #expect(data.count < 1000, "singles snapshot is \\(data.count) bytes")
    }

    // MARK: Beam lock

    /// Weightless, with the beam set to lock after `seconds`, the hull
    /// clear of every wall and the ball straight off its nose.
    private func lockable(after seconds: Double) -> SimulationEngine {
        var engine = weightless()
        var configuration = engine.configuration
        configuration.beamLockTime = seconds
        configuration.beamSwing = 1
        engine.updateConfiguration(configuration)
        engine.state.ships[.cyan]!.position = .init(-0.5, 0)
        engine.state.ball.position = .init(-0.5, 0.25)
        engine.state.ball.velocity = .zero
        return engine
    }

    private func hold(_ engine: inout SimulationEngine, tractor: Bool = true, torque: Double = 0) {
        engine.step(inputs: [.cyan: PlayerInput(tick: engine.state.tick, torque: torque, thrust: false, tractor: tractor)])
    }

    /// Holds the beam stick-free until the step that locks it, and takes
    /// that one step with `torque` on the stick.
    private func lockOn(_ engine: inout SimulationEngine, torque: Double = 0) throws {
        for _ in 0 ..< 240 {
            var trial = engine
            hold(&trial, torque: torque)
            if trial.state.ball.beamLock != nil {
                engine = trial
                return
            }
            hold(&engine)
        }
        Issue.record("the beam never locked on")
    }

    /// Angular momentum of hull and ball about their shared centre of mass,
    /// the hull's own turn included.
    private func spinMomentum(_ engine: SimulationEngine) -> Double {
        let ship = engine.state.ships[.cyan]!
        let ball = engine.state.ball
        let ms = SimulationEngine.shipMass
        let mb = SimulationEngine.ballMass
        let centre = (ship.position * ms + ball.position * mb) / (ms + mb)
        let drift = (ship.velocity * ms + ball.velocity * mb) / (ms + mb)
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
        let reach = ShipHitbox.shared.reach
        let own = SimulationEngine.lockedHullInertia * ms * reach * reach * (ball.beamLock?.spin ?? 0)
            + SimulationEngine.lockedBallInertia * mb * ball.radius * ball.radius * ball.spin
        return ms * cross(ship.position - centre, ship.velocity - drift)
            + mb * cross(ball.position - centre, ball.velocity - drift) + own
    }

    private func pairMomentum(_ engine: SimulationEngine) -> SIMD2<Double> {
        engine.state.ball.velocity * SimulationEngine.ballMass
            + engine.state.ships[.cyan]!.velocity * SimulationEngine.shipMass
    }

    @Test("A beam held long enough locks the ball on: the pair turns as one body, momentum and angular momentum kept")
    func heldBeamLocksAndSpins() throws {
        var engine = lockable(after: 0.3)
        var steps = 0
        while engine.state.ball.beamLock == nil, steps < 120 {
            hold(&engine)
            steps += 1
        }
        let lock = try #require(engine.state.ball.beamLock, "the beam never locked on")
        #expect(lock.seat == .cyan)
        #expect(Double(steps) * engine.configuration.stepDuration >= 0.3 - 1e-9, "locked before the hold time")
        // Flick the ball sideways, with the catch's swing (the ball sits
        // above the hull): the weld has to turn that into more spin.
        engine.state.ball.velocity += .init(lock.spin >= 0 ? -0.6 : 0.6, 0)
        let angularBefore = spinMomentum(engine)
        let linearBefore = pairMomentum(engine)
        let angleBefore = engine.state.ships[.cyan]!.angle
        for _ in 0 ..< 45 { hold(&engine) }
        let ship = engine.state.ships[.cyan]!
        let ball = engine.state.ball
        let held = try #require(ball.beamLock, "the lock let go with the beam still held")
        #expect(abs(simd_length(ball.position - ship.position) - lock.length) < 1e-9, "the distance is locked")
        #expect(abs(spinMomentum(engine) - angularBefore) < 1e-9, "angular momentum drifted")
        #expect(simd_length(pairMomentum(engine) - linearBefore) < 1e-9, "linear momentum drifted")
        #expect(abs(ship.angle - angleBefore) > 0.3, "the pair barely turned")
        let line = ball.position - ship.position
        #expect(abs(remainder(atan2(line.y, line.x) - ship.angle - held.bearing, 2 * .pi)) < 1e-9, "the nose stays on the ball")
    }

    @Test("A locked ball dragged along the deck is one bounce per touch-down, not one a step")
    func lockedBallScrapingIsOneBounce() throws {
        var engine = lockable(after: 0.3)
        try lockOn(&engine)
        var configuration = engine.configuration
        configuration.gravity = SimulationEngine.testing().configuration.gravity
        engine.updateConfiguration(configuration)
        var lock = try #require(engine.state.ball.beamLock)
        lock.spin = 0
        // Hang the pair ball-down, the ball just off the deck and nothing
        // moving: gravity sets it down and the hull's weight holds it there.
        let rest = engine.arena.floorY + engine.state.ball.radius
        engine.state.ball.position = .init(-0.5, rest + 0.002)
        engine.state.ball.velocity = .zero
        engine.state.ball.spin = 0
        engine.state.ball.beamLock = lock
        engine.state.ships[.cyan]!.position = .init(-0.5, rest + 0.002 + lock.length)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angularVelocity = 0
        let score = engine.state.match.score
        var onDeck = 0
        for _ in 0 ..< 240 {
            hold(&engine)
            if engine.state.ball.position.y - rest < 0.001 { onDeck += 1 }
        }
        #expect(engine.state.ball.beamLock != nil, "the lock let go with the beam still held")
        #expect(onDeck > 60, "the ball never sat on the deck (\(onDeck) steps)")
        let floor = engine.state.match.floorContacts
        #expect(floor[.cyan] + floor[.orange] == 1, "one touch-down, counted \(floor[.cyan] + floor[.orange])")
        #expect(engine.state.match.score == score, "the scrape gave away a point")
    }

    @Test("Let go before the lock and the ball flies on in to a headbutt")
    func earlyReleaseNeverLocks() {
        var engine = lockable(after: 0.7)
        for _ in 0 ..< 30 { hold(&engine) } // half a second
        #expect(engine.state.ball.beamLock == nil)
        let contact = ShipHitbox.shared.noseReach + engine.state.ball.radius + 0.01
        var touched = false
        for _ in 0 ..< 240 where !touched {
            hold(&engine, tractor: false)
            #expect(engine.state.ball.beamLock == nil)
            touched = simd_length(engine.state.ball.position - engine.state.ships[.cyan]!.position) < contact
        }
        #expect(touched, "the ball never reached the hull")
    }

    @Test("Letting go drops the lock; the ball flies off along the spin and the hull keeps turning")
    func releaseFlingsTheBall() throws {
        var engine = lockable(after: 0.3)
        for _ in 0 ..< 120 where engine.state.ball.beamLock == nil { hold(&engine) }
        engine.state.ball.velocity += .init(0.6, 0)
        for _ in 0 ..< 10 { hold(&engine) }
        let lock = try #require(engine.state.ball.beamLock)
        let flung = engine.state.ball.velocity
        hold(&engine, tractor: false)
        #expect(engine.state.ball.beamLock == nil)
        #expect(simd_length(engine.state.ball.velocity - flung) < 1e-9, "the ball keeps the speed the spin gave it")
        #expect(engine.state.ships[.cyan]!.knockSpin == lock.spin, "the hull's spin carries on and winds down")
    }

    @Test("A locked ball turns with the hull: its own spin goes into the pair, and it never spins on its own")
    func lockedBallSpinTurnsWithThePair() throws {
        func locked(spinning spin: Double) throws -> SimulationEngine {
            var engine = lockable(after: 0.3)
            engine.state.ball.spin = spin
            // The stick sets the catch's way, so the two differ only by the
            // ball's own spin.
            try lockOn(&engine, torque: 1)
            _ = try #require(engine.state.ball.beamLock, "the beam never locked on")
            return engine
        }
        let still = try locked(spinning: 0)
        var engine = try locked(spinning: 30)
        let lock = engine.state.ball.beamLock!
        #expect(lock.spin - still.state.ball.beamLock!.spin > 0.05, "the ball's own spin never reached the pair")
        #expect(engine.state.ball.spin == lock.spin)
        let angleBefore = engine.state.ships[.cyan]!.angle
        for _ in 0 ..< 60 { hold(&engine) }
        let held = try #require(engine.state.ball.beamLock)
        #expect(engine.state.ball.spin == held.spin, "the ball spins on its own while locked")
        #expect(engine.state.ships[.cyan]!.angularVelocity == held.spin, "the hull turns at the pair's rate")
        #expect(abs(held.spin - lock.spin) < 1e-9, "nothing outside touched the pair, so its turn holds")
        #expect(engine.state.ships[.cyan]!.angle - angleBefore > 0.05, "the hull did not turn with the ball")
    }

    @Test("The catch keeps the ball's run: the closing speed turns into swing, the way the stick is held")
    func catchSwings() throws {
        for torque in [1.0, -1.0] {
            var engine = lockable(after: 0.3)
            try lockOn(&engine, torque: torque)
            let lock = try #require(engine.state.ball.beamLock)
            #expect(lock.spin * torque > 1, "the catch died instead of swinging (spin \(lock.spin))")
        }
        // Stick-free, the catch still swings, and the swing keeps its
        // momentum from then on.
        var engine = lockable(after: 0.3)
        try lockOn(&engine)
        let caught = try #require(engine.state.ball.beamLock).spin
        #expect(abs(caught) > 1, "a stick-free catch died (spin \(caught))")
        let linear = pairMomentum(engine)
        for _ in 0 ..< 30 { hold(&engine) }
        #expect(abs(engine.state.ball.beamLock!.spin - caught) < 1e-9)
        #expect(simd_length(pairMomentum(engine) - linear) < 1e-9)
    }

    @Test("The stick pumps a locked pair's swing up to twice the hull's turn, brakes it the other way, and beam swing 0 never pumps")
    func stickPumpsTheSwing() throws {
        var engine = lockable(after: 0.3)
        try lockOn(&engine)
        let start = try #require(engine.state.ball.beamLock).spin
        let way: Double = start >= 0 ? 1 : -1
        let linear = pairMomentum(engine)
        let steps = 20
        for _ in 0 ..< steps { hold(&engine, torque: way) }
        let pumped = engine.state.ball.beamLock!.spin
        let expected = SimulationEngine.beamSwingAcceleration * Double(steps) * engine.configuration.stepDuration
        #expect(abs((pumped - start) * way - expected) < 1e-6, "pumped \(pumped - start), expected \(expected)")
        #expect(simd_length(pairMomentum(engine) - linear) < 1e-9, "pumping moved the pair")
        for _ in 0 ..< 1200 { hold(&engine, torque: way) }
        let top = SimulationEngine.beamSwingTopRate * engine.configuration.torqueAcceleration
        #expect(abs(engine.state.ball.beamLock!.spin * way - top) < 1e-6, "the swing did not top out")
        for _ in 0 ..< 20 { hold(&engine, torque: -way) }
        #expect(engine.state.ball.beamLock!.spin * way < top - 1, "the stick against the swing did not brake it")

        var still = lockable(after: 0.3)
        var configuration = still.configuration
        configuration.beamSwing = 0
        still.updateConfiguration(configuration)
        try lockOn(&still)
        let free = still.state.ball.beamLock!.spin
        for _ in 0 ..< 30 { hold(&still, torque: 1) }
        #expect(abs(still.state.ball.beamLock!.spin - free) < 1e-9, "beam swing 0 still pumped")
    }

    @Test("Beam swing is a match rule, clamped off the wire")
    func beamSwingIsAMatchRule() {
        #expect(SimulationConfiguration().beamSwing == 0)
        #expect(FlightTuningSnapshot.defaults.configuration.beamSwing == FlightTuningSnapshot.defaults.beamSwing)
        var snapshot = FlightTuningSnapshot.defaults
        snapshot.beamSwing = .nan
        #expect(snapshot.configuration.beamSwing == FlightTuningSnapshot.defaults.beamSwing)
        snapshot.beamSwing = 1e300
        #expect(snapshot.configuration.beamSwing == FlightTuningSnapshot.beamSwingRange.upperBound)
    }

    @Test("The shipped match rules lock the beam on; a bare configuration never does")
    func lockIsAMatchRule() {
        #expect(SimulationConfiguration().beamLockTime == 0)
        #expect(FlightTuningSnapshot.defaults.configuration.beamLockTime == FlightTuningSnapshot.defaults.beamLock)
        #expect(FlightTuningSnapshot.beamLockRange.contains(FlightTuningSnapshot.defaults.beamLock))
    }

    @Test("A host's beam lock time off the wire is clamped, and nonsense never traps the engine")
    func beamLockFromTheWireIsSafe() {
        var snapshot = FlightTuningSnapshot.defaults
        snapshot.beamLock = .nan
        #expect(snapshot.configuration.beamLockTime == FlightTuningSnapshot.defaults.beamLock)
        snapshot.beamLock = 1e300
        #expect(snapshot.configuration.beamLockTime == FlightTuningSnapshot.beamLockRange.upperBound)
        for nonsense in [Double.nan, .infinity, 1e300] {
            var engine = lockable(after: nonsense)
            for _ in 0 ..< 30 { hold(&engine) }
            #expect(engine.state.ball.beamLock == nil)
        }
    }

    // MARK: - What breaks a lock

    /// Locks on in weightless play with the stick centred, then stills the
    /// pair: no spin, nothing moving, the ball straight above the hull at
    /// the locked length.
    private func stilledLock() throws -> (engine: SimulationEngine, lock: BeamLock) {
        var engine = lockable(after: 0.3)
        try lockOn(&engine)
        var lock = try #require(engine.state.ball.beamLock)
        lock.spin = 0
        engine.state.ships[.cyan]!.position = .init(-0.5, 0)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angularVelocity = 0
        engine.state.ball.position = .init(-0.5, lock.length)
        engine.state.ball.velocity = .zero
        engine.state.ball.spin = 0
        engine.state.ball.beamLock = lock
        return (engine, lock)
    }

    @Test("The hull touching the deck drops the lock, and it does not come straight back")
    func deckTouchDropsTheLock() throws {
        var (engine, lock) = try stilledLock()
        // Set the pair down with the hull's middle on the deck line: the
        // deck pushes it up this step, and that touch is the end of the lock.
        let drop = engine.state.ships[.cyan]!.position.y - engine.arena.floorY
        engine.state.ships[.cyan]!.position.y -= drop
        engine.state.ball.position.y -= drop
        hold(&engine)
        #expect(engine.state.ball.beamLock == nil, "the lock survived the deck")
        #expect(engine.state.ships[.cyan]!.knockSpin == lock.spin)
        // The hold starts over: the beam is still on the ball, but it has to
        // be held the full lock time again.
        for _ in 0 ..< 8 {
            hold(&engine)
            #expect(engine.state.ball.beamLock == nil, "the lock came back at once")
        }
    }

    @Test("A hull sitting on the deck never locks on, however long the beam is held")
    func groundedHullNeverLocks() throws {
        var engine = lockable(after: 0.3)
        var configuration = engine.configuration
        configuration.gravity = SimulationEngine.testing().configuration.gravity
        engine.updateConfiguration(configuration)
        // Hull parked on the deck, ball above the nose in the beam.
        engine.state.ships[.cyan]!.position = .init(-0.5, engine.arena.floorY)
        engine.state.ball.position = .init(-0.5, engine.arena.floorY + 0.3)
        hold(&engine)
        let parked = engine.state.ships[.cyan]!.position.y
        for _ in 0 ..< 120 {
            hold(&engine)
            #expect(engine.state.ball.beamLock == nil, "a grounded hull locked on")
        }
        #expect(abs(engine.state.ships[.cyan]!.position.y - parked) < 0.01, "the hull left the deck, so this proved nothing")
        #expect(engine.state.ball.beamHold?.seat == .cyan, "the beam lost the ball, so this proved nothing")
    }

    @Test("On the ring, the wall is the ground: a hull against it drops its lock")
    func rimTouchDropsTheLock() throws {
        var configuration = SimulationConfiguration.online
        configuration.ring = .lab
        let arena = ArenaGeometry.freeForAll(pilots: 3, ballRadius: configuration.ballRadius, tuning: .lab)
        var engine = SimulationEngine.testing()
        engine.updateConfiguration(configuration)
        engine.updateArena(arena)
        engine.configureFreeForAll(FreeForAllState.seats(pilots: 3))
        engine.beginPlay()
        // Past the serve: a lock is only solved in play.
        engine.state.serveTicksRemaining = 0
        engine.step(inputs: [:])
        try #require(engine.state.match.phase == .playing)
        let ring = try #require(engine.arena.ring)
        let out = SIMD2(0.0, 1.0)
        let length = ShipHitbox.shared.reach + engine.state.balls[0].radius + 0.05
        // Hull pressed into the wall at the top of the ring, ball welded on
        // just inside it.
        engine.state.ships[.cyan]!.position = out * (ring.rimRadius - 0.01)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ships[.cyan]!.angularVelocity = 0
        engine.state.balls[0].position = out * (ring.rimRadius - 0.01 - length)
        engine.state.balls[0].velocity = .zero
        engine.state.balls[0].beamLock = BeamLock(seat: .cyan, length: length, bearing: 0, spin: 0)
        hold(&engine)
        #expect(engine.state.balls[0].beamLock == nil, "the lock survived the wall")
    }

    @Test("Another hull touching the locked ball knocks the lock off")
    func rivalTouchBreaksTheLock() throws {
        var (engine, lock) = try stilledLock()
        let ball = engine.state.ball
        // The rival's nose, pointing down, already a hair into the top of
        // the ball.
        engine.state.ships[.orange]!.position = ball.position + .init(0, ShipHitbox.shared.noseReach + ball.radius - 0.01)
        engine.state.ships[.orange]!.angle = -.pi / 2
        engine.state.ships[.orange]!.velocity = .zero
        engine.state.ships[.orange]!.angularVelocity = 0
        hold(&engine)
        #expect(engine.state.ball.beamLock == nil, "the lock held through a rival's touch")
        #expect(engine.state.ball.lastPlay == BallPlay(seat: .orange, kind: .hull), "the touch did not play the ball")
        #expect(engine.state.ball.beamHold?.since == engine.state.tick - 1, "the hold did not start over")
        #expect(engine.state.ball.beamHold?.seat == lock.seat)
    }

    @Test("A rival's bolt on the locked ball breaks the lock and punches the ball")
    func rivalBoltOnTheBallBreaksTheLock() throws {
        var (engine, _) = try stilledLock()
        let ball = engine.state.ball
        engine.state.bolts = [BoltState(
            id: 1, owner: .orange,
            position: ball.position + .init(ball.radius + BoltState.radius + 0.01, 0),
            velocity: .init(-engine.configuration.boltSpeed, 0),
            ticksRemaining: 30
        )]
        hold(&engine)
        #expect(engine.state.ball.beamLock == nil, "the lock held through a bolt on the ball")
        #expect(engine.state.ball.velocity.x < -0.1, "the punch never landed, so this proved nothing")
    }

    @Test("The holder's own bolt on the locked ball breaks the lock too")
    func ownBoltOnTheBallBreaksTheLock() throws {
        var (engine, _) = try stilledLock()
        let ball = engine.state.ball
        engine.state.bolts = [BoltState(
            id: 1, owner: .cyan,
            position: ball.position + .init(ball.radius + BoltState.radius + 0.01, 0),
            velocity: .init(-engine.configuration.boltSpeed, 0),
            ticksRemaining: 30
        )]
        hold(&engine)
        #expect(engine.state.ball.beamLock == nil, "the lock held through the holder's own bolt")
        #expect(engine.state.ball.velocity.x < -0.1, "the punch never landed, so this proved nothing")
    }

    @Test("A rival's bolt on the hull breaks the lock")
    func rivalBoltOnTheHullBreaksTheLock() throws {
        var (engine, lock) = try stilledLock()
        let ship = engine.state.ships[.cyan]!
        // Up the tail, from behind: nowhere near the beam.
        let tail = ShipHitbox.shared.extent(along: .init(0, -1), angle: ship.angle)
        engine.state.bolts = [BoltState(
            id: 1, owner: .orange,
            position: ship.position - .init(0, tail + BoltState.radius + ShipHitbox.skin + 0.01),
            velocity: .init(0, engine.configuration.boltSpeed),
            ticksRemaining: 30
        )]
        hold(&engine)
        #expect(engine.state.ball.beamLock == nil, "the lock held through a bolt on the hull")
        #expect(engine.state.ships[.cyan]!.knockSpin == lock.spin)
        #expect(engine.state.ships[.cyan]!.velocity.y > 0.01, "the bolt never landed, so this proved nothing")
    }

    @Test("No goal takes a locked ball: the same ball, let go, scores")
    func lockedBallMeetsTheGoalShut() throws {
        let (stilled, lock) = try stilledLock()
        let arena = stilled.arena
        for side in [1.0, -1.0] {
            var engine = stilled
            // The pair flying flat at the face, ball first, the ball a hair
            // off the mouth: a free ball at this speed is in this step.
            let mouth = SIMD2(
                side * (arena.netHalfWidth + engine.state.ball.radius + 0.01),
                (arena.netBottomY + arena.portalMouthTopY) / 2
            )
            let run = SIMD2(-side * 4, 0)
            engine.state.ball.position = mouth
            engine.state.ball.velocity = run
            engine.state.ships[.cyan]!.position = mouth - .init(0, lock.length)
            engine.state.ships[.cyan]!.velocity = run
            let before = engine.state.match.score
            var free = engine
            free.state.ball.beamLock = nil
            free.state.ball.beamHold = nil
            hold(&engine)
            hold(&free)
            #expect(engine.state.match.score == before, "a locked ball went in on side \(side)")
            #expect(engine.state.ball.beamLock != nil, "the goal face broke the lock on side \(side)")
            #expect(free.state.match.score != before, "the free ball did not score on side \(side), so this proved nothing")
        }
    }
}
