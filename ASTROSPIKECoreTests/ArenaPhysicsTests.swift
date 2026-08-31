import Testing
import simd
@testable import ASTROSPIKECore

@Suite("Arena physics")
struct ArenaPhysicsTests {
    @Test("The standard net is a low hurdle rather than a wall")
    func standardNetIsLowEnoughToFlyOver() {
        let arena = ArenaGeometry.standard
        let netHeight = arena.netTopY - arena.floorY
        let arenaHeight = arena.ceilingY - arena.floorY

        #expect(arena.netTopY == -0.46)
        #expect(netHeight / arenaHeight < 0.22)
        // The pocket roof still passes under the net cap, so goals stay reachable.
        #expect(arena.netTopY > arena.floorY + (arena.goalOuterX - arena.goalInnerX))
    }

    @Test("A straight ground roll is rejected by the goal lip")
    func straightRollDoesNotScore() {
        let ball = BallState(
            position: SIMD2(0.10, -0.72),
            velocity: SIMD2(2, 0),
            radius: 0.045
        )

        #expect(ArenaGeometry.standard.goalDefender(for: ball) == nil)
    }

    @Test("A downward return from the center net enters the adjacent goal")
    func downwardNetReturnScores() {
        let ball = BallState(
            position: SIMD2(0.08, -0.72),
            velocity: SIMD2(0.4, -1.2),
            radius: 0.045
        )

        #expect(ArenaGeometry.standard.goalDefender(for: ball) == .orange)
    }

    @Test("A ball approaching the center net does not score before returning")
    func inwardApproachDoesNotScoreBeforeNetReturn() {
        let directShot = BallState(
            position: SIMD2(0.08, -0.72),
            velocity: SIMD2(-0.4, -1.2),
            radius: 0.045
        )

        #expect(ArenaGeometry.standard.goalDefender(for: directShot) == nil)
    }

    @Test("The compact goal opens outward and narrows toward the center net")
    func compactGoalFacesAwayFromCenterNet() {
        let insideMouth = BallState(
            position: SIMD2(0.12, -0.65),
            velocity: SIMD2(0.4, -1.2),
            radius: 0.045
        )
        let aboveNarrowBack = BallState(
            position: SIMD2(0.03, -0.70),
            velocity: SIMD2(0.4, -1.2),
            radius: 0.045
        )

        #expect(ArenaGeometry.standard.goalDefender(for: insideMouth) == .orange)
        #expect(ArenaGeometry.standard.goalDefender(for: aboveNarrowBack) == nil)
    }

    @Test("The net rebounds the ball")
    func netReboundsBall() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(-0.051, -0.60),
            velocity: SIMD2(2, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.velocity.x < 0)
    }

    @Test("A rebounding ball clears the net instead of sticking to its edge")
    func reboundingBallClearsNet() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(-0.051, -0.60),
            velocity: SIMD2(2, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])
        let reboundX = engine.state.ball.position.x
        for tick in UInt64(1) ... 12 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.ball.position.x < reboundX - 0.02)
        #expect(engine.state.ball.velocity.x < 0)
    }

    @Test("A center drop bounces from the rounded net cap and deflects sideways")
    func roundedNetCapDeflectsCenterDrop() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position.y = 0.5
        engine.state.ships[.orange]!.position.y = 0.5
        engine.state.ball = BallState(
            position: SIMD2(0, 0.32),
            velocity: SIMD2(0, -2),
            radius: 0.04
        )

        for tick in UInt64(0) ..< 60 {
            engine.step(inputs: [.cyan: .idle(tick: tick), .orange: .idle(tick: tick)])
        }

        #expect(engine.state.ball.velocity.y > 0)
        #expect(abs(engine.state.ball.velocity.x) > 0.05)
        #expect(abs(engine.state.ball.position.x) > 0.058)
    }

    @Test("A maximum speed ball cannot tunnel through the net")
    func fastBallCannotTunnelThroughNet() {
        var engine = SimulationEngine.testing()
        engine.state.ball = BallState(
            position: SIMD2(-0.40, -0.60),
            velocity: SIMD2(60, 0),
            radius: 0.04
        )

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(engine.state.ball.position.x < 0)
        #expect(engine.state.ball.velocity.x < 0)
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

    @Test("The net rebounds a ship from either side")
    func netContactReboundsFromEitherSide() {
        for x in [0.04, -0.04] {
            var engine = SimulationEngine.testing()
            engine.state.ships[.cyan]!.position = SIMD2(x, -0.40)
            engine.state.ships[.cyan]!.velocity = SIMD2(x > 0 ? -0.5 : 0.5, -0.5)

            engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

            #expect(!engine.state.ships[.cyan]!.isDestroyed, "died on the net at x = \(x)")
            #expect(engine.state.match.score == Score())
            #expect(engine.lastEvents.contains { event in
                if case .collisionEffect = event { return true }
                return false
            })
        }
    }

    @Test("Touching the net from the home side rebounds safely")
    func homeSideNetContactReboundsShip() {
        var engine = SimulationEngine.testing()
        engine.state.ships[.cyan]!.position = SIMD2(-0.04, -0.40)
        engine.state.ships[.cyan]!.velocity = SIMD2(0.5, -0.5)

        engine.step(inputs: [.cyan: .idle(tick: 0), .orange: .idle(tick: 0)])

        #expect(!engine.state.ships[.cyan]!.isDestroyed)
        #expect(engine.state.match.score == Score())
        #expect(engine.lastEvents.contains { event in
            guard case .collisionEffect = event else { return false }
            return true
        })
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
        for x in [-0.5, 0.30] {
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
                return simd_distance(engine.state.ball.position, ship.position) < 0.17
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
