import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Arena physics")
struct ArenaPhysicsTests {
    @Test("The hump is the corner arc, mirrored into the middle of the roof")
    func humpMirrorsTheCornerCurvature() {
        let arena = ArenaGeometry.standard

        // Same arc, same semi-axes, with the net face standing in for the side
        // wall: vertical at the collar, horizontal where it meets the roof.
        #expect(arena.humpBaseX == arena.netHalfWidth + arena.cornerRadiusX)
        #expect(arena.humpUndersideY == arena.ceilingY - arena.cornerRadiusY)
        let underside = arena.humpSurfacePoint(0)
        #expect(abs(underside.x - arena.netHalfWidth) < 1e-12)
        #expect(abs(underside.y - arena.humpUndersideY) < 1e-12)
        let base = arena.humpSurfacePoint(arena.humpSampleCount - 1)
        #expect(abs(base.x - arena.humpBaseX) < 1e-12)
        #expect(abs(base.y - arena.ceilingY) < 1e-12)
        // Flat enough at the roof to be a slope rather than a step.
        #expect(arena.humpSurfacePoint(arena.humpSampleCount - 2).y > arena.ceilingY - 0.01)
    }

    @Test("The portal mouth hangs clear of the hump and stays aimable")
    func portalMouthClearsTheHump() {
        let arena = ArenaGeometry.standard
        let ballRadius = BallState(position: .zero).radius

        // A whole ball of collar under the hump, so anything that scores is
        // clear of the slope rather than grazing the point where the two meet.
        #expect(arena.portalMouthTopY <= arena.humpUndersideY - ballRadius * 2)
        // And the mouth left below it is still comfortably taller than the
        // ball, so a lifted drive can find it.
        #expect(arena.portalFaceHeight > ballRadius * 4)
        // It stays a slab, not a wall: thin, dead centre, so the middle of the
        // court is a target rather than an obstruction.
        #expect(arena.netHalfWidth < arena.halfWidth * 0.05)
    }

    /// One tick of physics with the ships parked out of the way, so the only
    /// thing the ball can meet is the goal structure.
    private func ballOnlyStep(
        position: SIMD2<Double>,
        velocity: SIMD2<Double>
    ) -> (scored: Bool, engine: SimulationEngine) {
        let ships: [Seat: ShipState] = [
            .cyan: ShipState(position: SIMD2(-1.4, -0.4), angle: 0, isDestroyed: true, homeSide: .cyan),
            .orange: ShipState(position: SIMD2(1.4, -0.4), angle: .pi, isDestroyed: true, homeSide: .orange),
        ]
        var engine = SimulationEngine(
            state: WorldState(ships: ships, ball: BallState(position: position))
        )
        engine.state.ball.velocity = velocity
        let before = engine.state.match.score.cyan + engine.state.match.score.orange
        engine.step(inputs: [:])
        let after = engine.state.match.score.cyan + engine.state.match.score.orange
        return (after > before, engine)
    }

    @Test("A ball driven up into the underside of a lip does not score")
    func theLipIsTheBottomBar() {
        // Found by sweeping position x velocity against the unfixed engine:
        // the one-tick sweep carried the ball clean through the ledge and past
        // the face, and the goal was awarded before the lip was ever consulted.
        let result = ballOnlyStep(
            position: SIMD2(0.060, 0.125),
            velocity: SIMD2(-0.69, 3.94)
        )
        #expect(!result.scored)
        // And it was actually turned around rather than merely not counted.
        #expect(result.engine.state.ball.velocity.y < 0)
    }

    @Test("No shot anywhere scores through the underside of a lip")
    func noGoalsThroughTheBottomBar() {
        let arena = ArenaGeometry.standard
        let configuration = SimulationConfiguration()
        let dt = configuration.stepDuration
        // Classify against the same swept segment the engine integrates --
        // gravity included -- and with a hair off the radius, so a ball that
        // grazes the very underside of the ledge by a fraction of a percent
        // is not read as one that went through it.
        let radius = BallState(position: .zero).radius * 0.99
        var leaks = 0
        var goals = 0
        // Both lips. `lipContact` mirrors through `abs(position.x)`, so a bug
        // that only leaks on one side is possible in principle -- a one-sided
        // grid could never turn this test red.
        for side in [1.0, -1.0] {
            for xStep in 0 ... 24 {
                let x = side * (0.058 + Double(xStep) * 0.008)
                for yStep in 0 ... 24 {
                    let y = 0.09 + Double(yStep) * 0.006
                    for speed in [3.0, 5.0, 8.0, 12.0] {
                        for degrees in stride(from: 100.0, through: 260.0, by: 10.0) {
                            let angle = degrees * .pi / 180
                            let velocity = SIMD2(side * cos(angle), sin(angle)) * speed
                            let result = ballOnlyStep(position: SIMD2(x, y), velocity: velocity)
                            guard result.scored else { continue }
                            goals += 1
                            // Would this shot's own sweep have been sitting under
                            // the ledge, driving into it? Then it went through the
                            // bottom bar and should never have counted.
                            let swept = velocity
                                + configuration.gravity * configuration.ballGravityMultiplier * dt
                            let end = SIMD2(x, y) + swept * dt
                            guard let lip = arena.lipContact(
                                from: SIMD2(x, y),
                                to: end,
                                radius: radius
                            ) else { continue }
                            if lip.normal.y < 0, simd_dot(swept, lip.normal) < 0 { leaks += 1 }
                        }
                    }
                }
            }
        }
        // The sweep has to actually be scoring goals, or "no leaks" is vacuous.
        #expect(goals > 1000)
        #expect(leaks == 0)
    }

    @Test("A ball that starts a tick wedged under a lip stays under it")
    func aWedgedBallCannotComeUpThroughTheLip() {
        let arena = ArenaGeometry.standard
        let radius = BallState(position: .zero).radius
        // A knock off the cap can leave the ball's centre a fraction of a
        // radius under the ledge. The lip is a line, so a drive up and in from
        // there put the centre over the top by the swept check's first sample:
        // the ball read as sitting on the ledge, and the face behind it took
        // the goal. Placed from the geometry, halfway along each lip.
        for side in [1.0, -1.0] {
            let root = arena.lipRoot(sign: side)
            let edge = arena.lipTip(sign: side) - root
            let up = simd_normalize(SIMD2(-edge.y, edge.x)) * side
            for depth in [0.2, 0.3, 0.4] {
                for drive in [SIMD2(2.0, 2.0), SIMD2(3, 4), SIMD2(4, 6)] {
                    let result = ballOnlyStep(
                        position: root + edge * 0.5 - up * (radius * depth),
                        velocity: SIMD2(-side * drive.x, drive.y)
                    )
                    #expect(!result.scored, "side \(side) depth \(depth) drive \(drive)")
                    #expect(result.engine.state.ball.velocity.y < 0, "side \(side) depth \(depth) drive \(drive)")
                }
            }
        }
    }

    @Test("A ball tucked under the lip beside the cap has not reached a face")
    func thePocketUnderTheLipIsNotTheMouth() {
        let arena = ArenaGeometry.standard
        let radius = BallState(position: .zero).radius
        // Beside the rounded bottom of the net, under the root of the lip, is
        // open space. The face plane reaches down there but the mouth does not:
        // it starts where the cap does. Placed from the geometry rather than
        // from a found case, so it stays in that pocket whatever the ball's size.
        for side in [1.0, -1.0] {
            let result = ballOnlyStep(
                position: SIMD2(
                    side * (arena.netHalfWidth + radius + 0.001),
                    arena.netBottomY - radius * 0.9
                ),
                velocity: SIMD2(-side * 0.5, 0)
            )
            #expect(!result.scored, "side \(side)")
        }
    }

    @Test("No goal is scored across a face below the bottom of the mouth")
    func noGoalsBelowTheMouth() {
        let arena = ArenaGeometry.standard
        let configuration = SimulationConfiguration()
        let dt = configuration.stepDuration
        let radius = BallState(position: .zero).radius
        let limit = arena.netHalfWidth + radius
        var goals = 0
        var belowMouth = 0
        for side in [1.0, -1.0] {
            for xStep in 0 ..< 8 {
                let x = side * (limit + 0.001 + Double(xStep) * 0.003)
                for yStep in 0 ... 27 {
                    let y = arena.netBottomY + radius * (-1.2 + Double(yStep) * 0.1)
                    for speed in [1.0, 3.0, 6.0, 10.0] {
                        for degrees in stride(from: -60.0, through: 60.0, by: 15.0) {
                            let angle = degrees * .pi / 180
                            let velocity = SIMD2(-side * cos(angle), sin(angle)) * speed
                            let result = ballOnlyStep(position: SIMD2(x, y), velocity: velocity)
                            guard result.scored else { continue }
                            goals += 1
                            // Where did this tick's own sweep cross the face plane?
                            let swept = (velocity
                                + configuration.gravity * configuration.ballGravityMultiplier * dt) * dt
                            let t = (side * limit - x) / swept.x
                            guard (0 ... 1).contains(t) else { continue }
                            if y + swept.y * t < arena.netBottomY - 1e-9 { belowMouth += 1 }
                        }
                    }
                }
            }
        }
        #expect(goals > 500)
        #expect(belowMouth == 0)
    }

    @Test("The lips tilt inward and are wider than a ball")
    func lipsFeedTheMouth() {
        let arena = ArenaGeometry.standard
        let ballRadius = BallState(position: .zero).radius

        for sign in [-1.0, 1.0] {
            let root = arena.lipRoot(sign: sign)
            let tip = arena.lipTip(sign: sign)
            // Rooted at the bottom corner of the face, jutting outward.
            #expect(abs(root.x - sign * arena.netHalfWidth) < 1e-12)
            #expect(abs(root.y - arena.netBottomY) < 1e-12)
            #expect(tip.x * sign > root.x * sign)
            // The outer end is the high end, so a ball rolls in, not off.
            #expect(tip.y > root.y)
            #expect(abs(tip.x - root.x) > ballRadius * 2)
        }
    }

    @Test("A ball landing on a lip rolls into the portal, against the side defending it")
    func lipFeedsTheBallIntoThePortal() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        // Dropped from rest just above the orange lip: no drive at the face
        // at all, only the tilt of the ledge to carry it in.
        engine.state.ball = BallState(
            position: SIMD2(0.115, 0.26),
            velocity: .zero,
            radius: BallState.nominalRadius
        )

        for tick in UInt64(0) ..< 240 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.match.score == Score(cyan: 1, orange: 0), "the lip did not feed the goal")
    }

    @Test("The bottom of the net is hard: a toss from below bounces, never scores")
    func capIsHardAndNeverScores() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.state.ball = BallState(
            position: SIMD2(0, -0.20),
            velocity: SIMD2(0, 2),
            radius: BallState.nominalRadius
        )

        for tick in UInt64(0) ..< 90 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            // The instant it comes back down off the cap, the point is settled.
            if engine.state.ball.velocity.y < 0 { break }
        }

        #expect(engine.state.match.score == Score())
        #expect(engine.state.ball.velocity.y < 0)
        #expect(engine.state.ball.position.y < ArenaGeometry.standard.netBottomY)
    }

    @Test("The cap favours neither half")
    func capDeflectionIsNeutral() {
        // Neutral means unbiased, not motionless: which way the ball comes off
        // the cap is set by where it hits, mirrored exactly. Neither half is
        // the one the net always feeds.
        var deflections: [Double] = []
        for offset in [-0.01, 0.01] {
            var engine = SimulationEngine.testing()
            engine.state.ships[.cyan]!.position.y = -0.40
            engine.state.ships[.orange]!.position.y = -0.40
            engine.state.ball = BallState(
                position: SIMD2(offset, -0.20),
                velocity: SIMD2(0, 2),
                radius: BallState.nominalRadius
            )
            for tick in UInt64(0) ..< 90 where engine.state.match.phase == .playing {
                engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
                if engine.state.ball.velocity.y < 0 { break }
            }
            #expect(engine.state.match.score == Score(), "the cap scored a point")
            deflections.append(engine.state.ball.velocity.x)
        }

        #expect(deflections[0] < 0, "a ball hitting left of centre was not sent left")
        #expect(deflections[1] > 0, "a ball hitting right of centre was not sent right")
        #expect(abs(deflections[0] + deflections[1]) < 0.001, "the cap leans one way")
    }

    @Test("A lifted drive into the near face is a point against the side defending it")
    func liftedDriveThroughThePortalScores() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        // A rising drive from the cyan half into the cyan face: an own goal.
        engine.state.ball = BallState(
            position: SIMD2(-0.30, 0.29),
            velocity: SIMD2(2, 0.3),
            radius: BallState.nominalRadius
        )

        for tick in UInt64(0) ..< 30 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.match.score == Score(cyan: 0, orange: 1))
    }

    @Test("The face on your side is your goal: entry from your half scores for the other side")
    func portalEntryScoresAgainstTheDefender() {
        let arena = ArenaGeometry.standard

        #expect(arena.portalScorer(enteredFromLeft: true) == .orange)
        #expect(arena.portalScorer(enteredFromLeft: false) == .cyan)
    }

    @Test("A ball crossing under the net has not scored")
    func crossingBelowTheNetIsNotAGoal() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.state.ball = BallState(
            position: SIMD2(-0.30, 0.0),
            velocity: SIMD2(2, 0),
            radius: BallState.nominalRadius
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
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.state.ball = BallState(
            position: SIMD2(-0.20, 0.30),
            velocity: SIMD2(1.5, 0),
            radius: BallState.nominalRadius
        )

        for tick in UInt64(0) ..< 120 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.match.score == Score(cyan: 0, orange: 1))
    }

    @Test("The ball does not linger in the net -- it is consumed on entry")
    func portalConsumesTheBall() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.state.ball = BallState(
            position: SIMD2(-0.06, 0.30),
            velocity: SIMD2(2, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        // One tick is enough: the face is reached and the rally is already over.
        #expect(engine.state.match.score == Score(cyan: 0, orange: 1))
        #expect(engine.state.match.phase != .playing)
    }

    @Test("A toss up into the cap deflects sideways instead of pogoing")
    func roundedNetCapDeflectsToss() {
        var engine = SimulationEngine.testing()
        let postX = 0.0
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.state.ball = BallState(
            position: SIMD2(postX, -0.10),
            velocity: SIMD2(0, 2),
            radius: 0.04
        )

        for tick in UInt64(0) ..< 60 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            // Sample on the way back down, before the floor sends it up again.
            if engine.state.ball.position.y < -0.30 { break }
        }

        #expect(engine.state.ball.velocity.y < 0)
        #expect(abs(engine.state.ball.velocity.x) > 0.05)
        #expect(abs(engine.state.ball.position.x - postX) > 0.05)
    }

    @Test("A maximum speed ball cannot tunnel past the portal unnoticed")
    func fastBallCannotTunnelThroughNet() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.state.ball = BallState(
            position: SIMD2(-0.40, 0.30),
            velocity: SIMD2(60, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        // Half an arena in one tick still has to be caught by the swept test.
        #expect(engine.state.match.score == Score(cyan: 0, orange: 1))
    }

    @Test("A ball riding the roof into the middle is thrown down instead of scoring")
    func roofRideIntoTheMiddleIsThrownDown() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        // Skimming in along the ceiling from the corner: the one path that
        // would trickle into a roof-hung goal if the hump were not there.
        engine.state.ball = BallState(
            position: SIMD2(-0.55, 0.58),
            velocity: SIMD2(3, 0.6),
            radius: BallState.nominalRadius
        )

        var thrownDown = false
        for tick in UInt64(0) ..< 240 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            if engine.state.ball.velocity.y < -0.4 { thrownDown = true }
            if engine.state.ball.position.y < 0 { break }
        }

        #expect(engine.state.match.score == Score(), "the roof ride still found the goal")
        #expect(thrownDown, "the hump never threw the ball downward")
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

        #expect(engine.state.ball.velocity.x < -4.8)
    }

    @Test("A ship can cross under the net and enter the opponent's half")
    func shipCanEnterOpponentHalfBelowNet() {
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
        let mouthY = (ArenaGeometry.standard.portalMouthTopY
            + ArenaGeometry.standard.netBottomY) / 2
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

    @Test("An untouched serve falls into play instead of scoring by itself")
    func untouchedServeMissesThePortal() {
        let arena = ArenaGeometry.standard
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = -0.40
        engine.state.ships[.orange]!.position.y = -0.40
        engine.prepareNextRally(mirrored: false)
        engine.beginPlay()

        var highest = engine.state.ball.position.y
        var reachedTheFloor = false
        for tick in UInt64(0) ..< 240 where engine.state.match.phase == .playing {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            highest = max(highest, engine.state.ball.position.y)
            if engine.state.ball.position.y < arena.floorY + 0.10 {
                reachedTheFloor = true
                break
            }
        }

        // The goal is above the serve and the serve only ever falls, so an
        // untouched serve can never hand out a free point.
        #expect(highest < arena.netBottomY - engine.state.ball.radius)
        #expect(reachedTheFloor, "the serve never came down into play")
        #expect(engine.state.match.score == Score())
    }

    @Test("A ship flown up into the goal stops on the hump, not on the net")
    func shipStopsOnTheHumpInsideTheGoal() {
        let arena = ArenaGeometry.standard
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(0, 0.10)
        engine.state.ships[.cyan]!.velocity = SIMD2(0, 3)

        var highest = engine.state.ships[.cyan]!.position.y
        for tick in UInt64(0) ..< 60 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            highest = max(highest, engine.state.ships[.cyan]!.position.y)
        }

        let ship = engine.state.ships[.cyan]!
        #expect(!ship.isDestroyed)
        // Through the mouth -- the net did not stop it ...
        #expect(highest > arena.portalMouthTopY)
        // ... and stopped by the hump, which is solid, rather than sinking in.
        #expect(highest < arena.humpUndersideY)
        #expect(engine.state.match.score == Score())
    }

    @Test("Skidding along the hump is quiet; hitting it is a knock")
    func skiddingAlongTheHumpIsNotAKnockEveryTick() {
        // Thrusting up under the roof, the hull rides the hump for the whole
        // run. That must not spark and buzz every tick.
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(0.25, 0.42)
        engine.state.ships[.cyan]!.velocity = SIMD2(-0.6, 0.3)
        engine.state.ships[.cyan]!.angle = 1.9
        var effects = 0
        for tick in UInt64(0) ..< 150 {
            engine.step(inputs: [
                .cyan: PlayerInput(tick: tick, torque: 0, thrust: true),
                .orange: .idle(tick: tick),
            ])
            for case .collisionEffect in engine.lastEvents { effects += 1 }
        }
        #expect(effects <= 3)

        // A hull flung straight into the hump still registers one.
        engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(0.20, 0.36)
        engine.state.ships[.cyan]!.velocity = SIMD2(0, 3)
        var hits = 0
        for tick in UInt64(0) ..< 30 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
            for case .collisionEffect in engine.lastEvents { hits += 1 }
        }
        #expect(hits >= 1)
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
            let inputs = Dictionary(uniqueKeysWithValues: Seat.singles.map { seat -> (Seat, PlayerInput) in
                guard let ship = engine.state.ships[seat] else { return (seat, .idle(tick: tick)) }
                let holding = ship.position.y < 0.20 || ship.velocity.y < -0.05
                return (seat, PlayerInput(tick: tick, torque: 0, thrust: holding))
            })
            engine.step(inputs: inputs)
            guard engine.state.match.phase == .playing else { break }
            let riding = Seat.singles.contains { seat in
                guard let ship = engine.state.ships[seat] else { return false }
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
