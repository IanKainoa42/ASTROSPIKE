import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Arena physics")
struct ArenaPhysicsTests {
    @Test("The hill is the corner arc, mirrored into the middle")
    func moundMirrorsTheCornerCurvature() {
        let arena = ArenaGeometry.standard

        // Same arc, same semi-axes, with the net face standing in for the side
        // wall: horizontal where it meets the floor, vertical at the post.
        #expect(arena.moundBaseX == arena.netHalfWidth + arena.cornerRadiusX)
        #expect(arena.moundCrestY == arena.floorY + arena.cornerRadiusY)
        let crest = arena.moundSurfacePoint(0)
        #expect(abs(crest.x - arena.netHalfWidth) < 1e-12)
        #expect(abs(crest.y - arena.moundCrestY) < 1e-12)
        let base = arena.moundSurfacePoint(arena.moundSampleCount - 1)
        #expect(abs(base.x - arena.moundBaseX) < 1e-12)
        #expect(abs(base.y - arena.floorY) < 1e-12)
        // Flat enough at the bottom to be a ramp rather than a kerb.
        #expect(arena.moundSurfacePoint(arena.moundSampleCount - 2).y < arena.floorY + 0.01)
    }

    @Test("The portal mouth stands clear of the hill and stays aimable")
    func portalMouthClearsTheMound() {
        let arena = ArenaGeometry.standard
        let ballRadius = BallState(position: .zero).radius

        // A whole ball of sill above the crest, so anything that scores is
        // clear of the hill rather than grazing the point where the two meet.
        #expect(arena.portalMouthFloorY >= arena.moundCrestY + ballRadius * 2)
        // And the mouth left above it is still comfortably taller than the
        // ball, so a flat drive can find it.
        #expect(arena.portalFaceHeight > ballRadius * 4)
        // It stays a slab, not a wall: thin, dead centre, so the middle of the
        // court is a target rather than an obstruction.
        #expect(arena.netHalfWidth < arena.halfWidth * 0.05)
    }

    @Test("The top of the net is hard: a drop from above bounces, never scores")
    func capIsHardAndNeverScores() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.55
        engine.state.ships[.orange]!.position.y = 0.55
        engine.state.ball = BallState(
            position: SIMD2(0, 0.20),
            velocity: SIMD2(0, -2),
            radius: 0.038
        )

        for tick in UInt64(0) ..< 90 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            // The instant it comes back up off the crown, the point is settled.
            if engine.state.ball.velocity.y > 0 { break }
        }

        #expect(engine.state.match.score == Score())
        #expect(engine.state.ball.velocity.y > 0)
        #expect(engine.state.ball.position.y > ArenaGeometry.standard.netTopY)
    }

    @Test("The cap favours neither half")
    func capDeflectionIsNeutral() {
        // Neutral means unbiased, not motionless: which way the ball comes off
        // the crown is set by where it lands, mirrored exactly. Neither half
        // is the one the net always feeds.
        var deflections: [Double] = []
        for offset in [-0.01, 0.01] {
            var engine = SimulationEngine.testing()
            engine.state.ships[.cyan]!.position.y = 0.55
            engine.state.ships[.orange]!.position.y = 0.55
            engine.state.ball = BallState(
                position: SIMD2(offset, 0.20),
                velocity: SIMD2(0, -2),
                radius: 0.038
            )
            for tick in UInt64(0) ..< 90 where engine.state.match.phase == .playing {
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
                if engine.state.ball.velocity.y > 0 { break }
            }
            #expect(engine.state.match.score == Score(), "the crown scored a point")
            deflections.append(engine.state.ball.velocity.x)
        }

        #expect(deflections[0] < 0, "a ball landing left of centre was not sent left")
        #expect(deflections[1] > 0, "a ball landing right of centre was not sent right")
        #expect(abs(deflections[0] + deflections[1]) < 0.001, "the crown leans one way")
    }

    @Test("A low drive into the portal scores for whoever drove it")
    func lowDriveThroughThePortalScores() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.5
        engine.state.ships[.orange]!.position.y = 0.5
        // A flat drive from the cyan half into the near face -- the shot the
        // whole game is aimed at.
        engine.state.ball = BallState(
            position: SIMD2(-0.30, -0.30),
            velocity: SIMD2(2, -0.3),
            radius: 0.038
        )

        for tick in UInt64(0) ..< 30 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.match.score == Score(cyan: 1, orange: 0))
    }

    @Test("The half the ball came from is the half that scores")
    func portalEntryScoresForWhoeverDroveItIn() {
        let arena = ArenaGeometry.standard

        #expect(arena.portalScorer(enteredFromLeft: true) == .cyan)
        #expect(arena.portalScorer(enteredFromLeft: false) == .orange)
    }

    @Test("A ball crossing over the net has not scored")
    func crossingAboveTheNetIsNotAGoal() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.55
        engine.state.ships[.orange]!.position.y = 0.55
        engine.state.ball = BallState(
            position: SIMD2(-0.30, 0.10),
            velocity: SIMD2(2, 0),
            radius: 0.038
        )

        for tick in UInt64(0) ..< 20 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.match.score == Score())
        #expect(engine.state.ball.position.x > 0)
    }

    @Test("Driving the ball through the portal scores")
    func portalDriveScores() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.5
        engine.state.ships[.orange]!.position.y = 0.5
        engine.state.ball = BallState(
            position: SIMD2(-0.20, -0.30),
            velocity: SIMD2(1.5, 0),
            radius: 0.038
        )

        for tick in UInt64(0) ..< 120 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.match.score == Score(cyan: 1, orange: 0))
    }

    @Test("The ball does not linger in the net -- it is consumed on entry")
    func portalConsumesTheBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.55
        engine.state.ships[.orange]!.position.y = 0.55
        engine.state.ball = BallState(
            position: SIMD2(-0.06, -0.30),
            velocity: SIMD2(2, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        // One tick is enough: the face is reached and the rally is already over.
        #expect(engine.state.match.score == Score(cyan: 1, orange: 0))
        #expect(engine.state.match.phase != .playing)
    }

    @Test("A drop onto the cap deflects sideways instead of balancing")
    func roundedNetCapDeflectsDrop() {
        var engine = SimulationEngine.testing()
        let postX = 0.0
        engine.state.ships[.cyan]!.position.y = 0.5
        engine.state.ships[.orange]!.position.y = 0.5
        engine.state.ball = BallState(
            position: SIMD2(postX, 0.32),
            velocity: SIMD2(0, -2),
            radius: 0.04
        )

        for tick in UInt64(0) ..< 60 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.ball.velocity.y > 0)
        #expect(abs(engine.state.ball.velocity.x) > 0.05)
        #expect(abs(engine.state.ball.position.x - postX) > 0.05)
    }

    @Test("A maximum speed ball cannot tunnel past the portal unnoticed")
    func fastBallCannotTunnelThroughNet() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.55
        engine.state.ships[.orange]!.position.y = 0.55
        engine.state.ball = BallState(
            position: SIMD2(-0.40, -0.32),
            velocity: SIMD2(60, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        // Half an arena in one tick still has to be caught by the swept test.
        #expect(engine.state.match.score == Score(cyan: 1, orange: 0))
    }

    @Test("A ball driven in low along the floor ramps up instead of scoring")
    func lowRollIntoTheMiddleRampsUp() {
        let arena = ArenaGeometry.standard
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.55
        engine.state.ships[.orange]!.position.y = 0.55
        // Skimming in from the corner, below the sill: the shot that used to
        // roll straight into the goal.
        engine.state.ball = BallState(
            position: SIMD2(-0.55, -0.58),
            velocity: SIMD2(3, 0),
            radius: 0.038
        )

        var peak = -1.0
        var tossedUp = false
        for tick in UInt64(0) ..< 240 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            peak = max(peak, engine.state.ball.position.y)
            if engine.state.ball.velocity.y > 0.4 { tossedUp = true }
        }

        #expect(engine.state.match.score == Score(), "the low roll still found the goal")
        #expect(tossedUp, "the hill never kicked the ball upward")
        #expect(peak > arena.moundCrestY, "the ball never got above the crest")
    }

    @Test("A maximum speed ball cannot tunnel through a ship")
    func fastBallCannotTunnelThroughShip() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(-0.40, 0.30)
        engine.state.ships[.cyan]!.velocity = .zero
        engine.state.ball = BallState(
            position: SIMD2(-0.80, 0.30),
            velocity: SIMD2(60, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x < 0)
        #expect(engine.state.ships[.cyan]!.velocity.x > 0)
    }

    @Test("A ship strike launches a stationary ball with arcade energy")
    func movingShipLaunchesStationaryBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(
            position: SIMD2(-0.55, 0.30),
            velocity: SIMD2(12, 0),
            angle: 0
        )
        engine.state.ball = BallState(
            position: SIMD2(-0.40, 0.30),
            velocity: .zero,
            radius: 0.045
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x > 12)
    }

    @Test("A ship strike refreshes an existing same-side bounce count")
    func shipStrikeRefreshesBounceCount() {
        var engine = SimulationEngine(state: WorldState(
            ships: [
                .cyan: ShipState(
                    position: SIMD2(-0.55, 0.30),
                    velocity: SIMD2(12, 0),
                    angle: 0
                ),
                .orange: ShipState(position: SIMD2(0.55, -0.55), angle: .pi / 2),
            ],
            ball: BallState(
                position: SIMD2(-0.40, 0.30),
                velocity: .zero,
                radius: 0.045
            ),
            match: MatchRuleState(
                floorContacts: FloorContactCounts(cyan: 2, orange: 0)
            )
        ))

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.match.floorContacts == FloorContactCounts())
        #expect(engine.state.match.score == Score())
    }

    @Test("Arena rebounds preserve Rocket League style ball speed")
    func wallReboundPreservesBallSpeed() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(0.90, 0.30),
            velocity: SIMD2(6, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x < -5.5)
    }

    @Test("A ship can cross above the net and enter the opponent's half")
    func shipCanEnterOpponentHalfAboveNet() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(-0.01, 0.20)
        engine.state.ships[.cyan]!.velocity = SIMD2(3, 0)

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(!engine.state.ships[.cyan]!.isDestroyed)
        #expect(engine.state.ships[.cyan]!.position.x > 0)
        #expect(engine.state.match.score == Score())
    }

    @Test("A ship flies straight through the portal from either side")
    func shipPassesThroughThePortal() {
        // The net is a goal now, not a blocker: defending it means being able
        // to fly into the mouth and sit in front of it.
        let mouthY = (ArenaGeometry.standard.portalMouthFloorY
            + ArenaGeometry.standard.netTopY) / 2
        for direction in [1.0, -1.0] {
            var engine = SimulationEngine.testing()
            engine.state.ships[.cyan]!.position = SIMD2(-0.10 * direction, mouthY)
            engine.state.ships[.cyan]!.velocity = SIMD2(2.5 * direction, 0)

            for tick in UInt64(0) ..< 20 {
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            }

            let ship = engine.state.ships[.cyan]!
            #expect(!ship.isDestroyed, "died on the net going \(direction)")
            #expect(ship.position.x * direction > 0.10, "the net still blocked the hull")
            #expect(engine.state.match.score == Score())
        }
    }

    @Test("An untouched serve lands in play instead of scoring by itself")
    func untouchedServeMissesThePortal() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.55
        engine.state.ships[.orange]!.position.y = 0.55
        engine.prepareNextRally(mirrored: false)
        engine.beginPlay()

        var reachedNetHeight = false
        for tick in UInt64(0) ..< 240 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            if engine.state.ball.position.y <= ArenaGeometry.standard.netTopY {
                reachedNetHeight = true
                break
            }
        }

        #expect(reachedNetHeight, "the serve never reached net height")
        // It has to arrive beside the net, not inside it: an untouched serve
        // must never hand out a free point.
        #expect(abs(engine.state.ball.position.x)
            > ArenaGeometry.standard.netHalfWidth + engine.state.ball.radius)
        #expect(engine.state.match.score == Score())
    }

    @Test("A ship dropped into the goal settles on the hill, not on the net")
    func shipLandsOnTheMoundInsideTheGoal() {
        let arena = ArenaGeometry.standard
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(0, -0.10)
        engine.state.ships[.cyan]!.velocity = SIMD2(0, -3)

        // Long enough for the hull to drop through, settle, and stop bouncing.
        var lowest = engine.state.ships[.cyan]!.position.y
        for tick in UInt64(0) ..< 300 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            lowest = min(lowest, engine.state.ships[.cyan]!.position.y)
        }

        let ship = engine.state.ships[.cyan]!
        #expect(!ship.isDestroyed)
        // Through the mouth -- the net did not hold it up ...
        #expect(lowest < arena.portalMouthFloorY)
        // ... and resting on the crest, which is solid, rather than sinking in.
        #expect(lowest > arena.moundCrestY)
        #expect(ship.position.y > arena.moundCrestY)
        #expect(engine.state.match.score == Score())
    }

    @Test("Short of the marker a ship flies free")
    func insideTheMarkerIsUnresisted() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(0.20, 0.35)
        engine.state.ships[.cyan]!.velocity = SIMD2(1, 0)
        let startSpeed = engine.state.ships[.cyan]!.velocity.x

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        // No push-back until the marker, so horizontal speed is untouched.
        #expect(abs(engine.state.ships[.cyan]!.velocity.x - startSpeed) < 0.000_001)
        #expect(!engine.state.ships[.cyan]!.isDestroyed)
    }

    @Test("Past the marker the far half pushes back instead of killing")
    func crossingTheMarkerIsResisted() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(0.60, 0.35)
        engine.state.ships[.cyan]!.velocity = SIMD2(1, 0)
        let limit = engine.arena.opponentCrossingLimit

        var deepest = engine.state.ships[.cyan]!.position.x
        var wasExpelled = false
        for tick in UInt64(0) ..< 300 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            let x = engine.state.ships[.cyan]!.position.x
            deepest = max(deepest, x)
            if x < limit { wasExpelled = true }
        }

        #expect(!engine.state.ships[.cyan]!.isDestroyed)
        #expect(engine.state.match.score == Score())
        // It gets in, and the far half throws it back out. Latched rather than
        // sampled at the end, because a loose ship drifts once it is clear.
        #expect(deepest > limit)
        #expect(wasExpelled)
    }

    @Test("The ground is a landing on either half, never a crash")
    func groundContactIsSurvivable() {
        // Both points are on the flat floor, clear of the hill in the middle
        // and of the corner arcs at the ends.
        for x in [-0.5, 0.45] {
            var engine = SimulationEngine.testing()
            engine.state.ships[.cyan]!.position = SIMD2(x, -0.72)
            engine.state.ships[.cyan]!.velocity = SIMD2(0, -4)

            for tick in UInt64(0) ..< 30 {
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            }

            #expect(!engine.state.ships[.cyan]!.isDestroyed, "died on the floor at x = \(x)")
            #expect(engine.state.match.score == Score())
            #expect(engine.state.ships[.cyan]!.position.y > engine.arena.floorY)
        }
    }

    @Test("Outer walls and the ceiling remain safe at high speed")
    func outerWallsAndCeilingAreForgiving() {
        var sideWall = SimulationEngine.testing()
        sideWall.state.ships[.cyan]!.position = SIMD2(-0.90, 0.30)
        sideWall.state.ships[.cyan]!.velocity = SIMD2(-8, 0)
        sideWall.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])
        #expect(!sideWall.state.ships[.cyan]!.isDestroyed)

        var ceiling = SimulationEngine.testing()
        ceiling.state.ships[.cyan]!.position = SIMD2(-0.5, 0.72)
        ceiling.state.ships[.cyan]!.velocity = SIMD2(0, 8)
        ceiling.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])
        #expect(!ceiling.state.ships[.cyan]!.isDestroyed)
    }

    @Test("A hull cannot carry the ball: every contact pops it clear")
    func hullCannotCarryTheBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(-0.55, 0.20)
        engine.state.ships[.orange]!.position = SIMD2(0.55, 0.20)
        engine.state.ball = BallState(position: SIMD2(-0.55, 0.60), velocity: SIMD2(0, -0.2))
        var longestContact = 0
        var contact = 0

        for tick in UInt64(0) ..< 900 {
            // Both players hold station, which is exactly how a ball gets ridden.
            let inputs = Dictionary(uniqueKeysWithValues: Team.allCases.map { team -> (Team, PlayerInput) in
                guard let ship = engine.state.ships[team] else { return (team, .idle(tick: tick)) }
                let holding = ship.position.y < 0.20 || ship.velocity.y < -0.05
                return (team, PlayerInput(tick: tick, torque: 0, thrust: holding))
            })
            engine.step(inputs: inputs)
            guard engine.state.match.phase == .playing else { break }
            let riding = Team.allCases.contains { team in
                guard let ship = engine.state.ships[team] else { return false }
                return simd_distance(engine.state.ball.position, ship.position) < 0.125
            }
            contact = riding ? contact + 1 : 0
            longestContact = max(longestContact, contact)
        }

        // Half a second of unbroken contact is a bounce; four seconds is a stall.
        #expect(longestContact < 120)
    }

    @Test("Even a gentle touch pushes the ball clear of the hull")
    func gentleTouchStillSeparatesTheBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(position: SIMD2(-0.55, 0.30), angle: 0)
        engine.state.ships[.orange] = ShipState(position: SIMD2(0.55, 0.30), angle: .pi)
        engine.state.ball = BallState(
            position: SIMD2(-0.38, 0.30),
            velocity: SIMD2(-0.25, 0),
            radius: 0.045
        )
        var separation = 0.0

        for tick in UInt64(0) ..< 40 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            if engine.state.ball.velocity.x > 0 {
                separation = simd_length(
                    engine.state.ball.velocity - engine.state.ships[.cyan]!.velocity
                )
                break
            }
        }

        // This nudge only carries 0.25 of closing speed, so an elastic bounce alone
        // would leave the ball loitering on the hull.
        #expect(separation >= engine.configuration.minimumBallSeparationSpeed - 0.001)
    }

    @Test("Ship-to-ship contact bounces both players apart")
    func shipContactBouncesBothPlayers() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan] = ShipState(
            position: SIMD2(-0.39, 0.40),
            velocity: SIMD2(8, 0),
            angle: 0,
            homeSide: .cyan
        )
        engine.state.ships[.orange] = ShipState(
            position: SIMD2(-0.21, 0.40),
            velocity: SIMD2(-8, 0),
            angle: .pi,
            homeSide: .cyan
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(!engine.state.ships[.cyan]!.isDestroyed)
        #expect(!engine.state.ships[.orange]!.isDestroyed)
        #expect(engine.state.match.score == Score())
        // They came together at 8 apiece and must leave going the other way.
        #expect(engine.state.ships[.cyan]!.velocity.x < 0)
        #expect(engine.state.ships[.orange]!.velocity.x > 0)
    }
}
