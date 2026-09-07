import Foundation
import simd

public protocol InputSource {
    mutating func input(for state: WorldState, team: Team, tick: UInt64) -> PlayerInput
}

public enum AIDifficulty: String, Codable, CaseIterable, Sendable {
    case rookie
    case pilot
    case ace

    public var reactionIntervalTicks: UInt64 {
        switch self {
        case .rookie: 24
        case .pilot: 12
        case .ace: 6
        }
    }

    public var aimErrorRadians: Double {
        switch self {
        case .rookie: 0.26
        case .pilot: 0.12
        case .ace: 0.03
        }
    }

    /// Speed the ship carries through the ball when it takes its shot.
    public var strikeSpeed: Double {
        switch self {
        case .rookie: 1.8
        case .pilot: 2.5
        case .ace: 3.2
        }
    }

    public var physicsMultiplier: Double { 1 }

    /// How well the nose has to line up with the shot before the bot fires.
    /// Cosine of the angle; nil means this level never shoots.
    public var fireAlignment: Double? {
        switch self {
        case .rookie: nil
        case .pilot: 0.86
        case .ace: 0.72
        }
    }
}

/// Flies a lander the way a player has to. It rolls the ball forward to find
/// where it will arrive on its own half, waits a run-up behind that point along
/// the line of the shot it wants, then drives through the ball to send it back
/// over the net.
///
/// Two constraints shape everything here: thrust is on or off along the nose,
/// and the nose only turns at a fixed rate. A demand the ship cannot turn to
/// serve in time is worse than no demand at all, so the guidance caps its own
/// descent, keeps the nose inside a lift cone, and holds a plan steady instead of
/// re-cutting it every reaction tick. None of that is about survival any more —
/// nothing in the arena is lethal — it is about arriving at the ball in control.
public struct AIController: InputSource, Sendable {
    /// Deceleration the approach law assumes it can rely on when braking.
    private static let brakingDeceleration = 2.0
    private static let approachSpeedCap = 2.6
    private static let accelerationGain = 3.5
    /// Fraction of full thrust that has to be useful before the motor fires.
    private static let thrustGate = 0.34
    /// Cosine of the largest nose error the motor will still fire through.
    private static let thrustAlignment = 0.7
    private static let turnGain = 4.0
    private static let turnDeadzone = 0.06
    /// Ship centre to ball centre for a nose-on contact.
    private static let strikeStandoff = 0.107
    /// Room kept behind the ball so the ship can build speed into the strike.
    private static let strikeRunup = 0.18
    /// Seconds before contact that the run-in begins.
    private static let driveWindow = 0.55
    /// How far under the cap the shot is aimed. Deep enough that a low ball
    /// is driven nearly flat, so the run-up is beside it rather than under
    /// it, and a high one is spiked down into the far half.
    private static let aimDepthUnderCap = 0.34
    /// Seconds a plan assumes the ship spends turning before it can move.
    private static let turnLatency = 0.25
    /// Contact ticks after which the ball is swatted clear no matter what.
    private static let carryLimitTicks: UInt64 = 36
    private static let predictionSteps = 120
    private static let predictionStep = 1.0 / 60.0

    private struct Plan {
        var hasIntercept: Bool
        var point: SIMD2<Double>
        var delay: Double
        var shot: SIMD2<Double>
    }

    public let difficulty: AIDifficulty
    private let arena: ArenaGeometry
    private var configuration: SimulationConfiguration
    private var planTick: UInt64?
    private var plannedTarget: SIMD2<Double>?
    private var plannedShot = SIMD2(-1.0, 0)
    private var plannedDelay = 9.0
    private var hasIntercept = false
    private var cachedAimError = 0.0
    private var cachedHomeSide: Team?
    private var carryTicks: UInt64 = 0

    public init(
        difficulty: AIDifficulty,
        configuration: SimulationConfiguration = .init(),
        arena: ArenaGeometry = .standard
    ) {
        self.difficulty = difficulty
        self.configuration = configuration
        self.arena = arena
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
    }

    public mutating func input(for state: WorldState, team: Team, tick: UInt64) -> PlayerInput {
        input(for: state, seat: .lead(team), tick: tick)
    }

    /// Flies one seat. In doubles the ship farther from the ball hangs back
    /// at a support post and leaves the play to its partner, so two bots on
    /// a side do not race each other to the same ball.
    public mutating func input(for state: WorldState, seat: Seat, tick: UInt64) -> PlayerInput {
        guard let ship = state.ships[seat] else { return .idle(tick: tick) }
        let homeSign = ship.homeSide == .cyan ? -1.0 : 1.0
        let supporting = supportsPartner(state: state, seat: seat, ship: ship)

        let projectedHomeDistance = (ship.position.x + ship.velocity.x * 1.20) * homeSign
        let crossingDanger = projectedHomeDistance < -(arena.opponentCrossingLimit - 0.12)
        let recovering = recoveryIsUrgent(for: ship)
        // The net never traps anyone -- hulls fly straight through it. What
        // can pin them is the hump above it, so the escape check keys off the
        // underside of the hump rather than the net.
        let pinnedByNet = ship.position.y > arena.humpUndersideY - 0.20
            && abs(ship.position.x) < arena.humpBaseX
            && ship.position.x * homeSign < 0.20

        let elapsed = planTick.map { Double(tick &- $0) * configuration.stepDuration } ?? 0
        var remaining = max(0, plannedDelay - elapsed)
        let stale = plannedTarget == nil
            || cachedHomeSide != ship.homeSide
            || planTick.map { tick &- $0 >= difficulty.reactionIntervalTicks } != false
        if stale {
            let plan = planShot(for: state, ship: ship, homeSign: homeSign)
            // Hold the standing plan while a fresh one agrees with it. Re-cutting
            // the stance every reaction tick is what makes a bot flail beside the
            // ball instead of setting up behind it.
            let agrees = hasIntercept
                && plan.hasIntercept
                && remaining > 0.001
                && simd_distance(plan.point, plannedTarget ?? plan.point) < 0.12
            if agrees {
                plannedShot = plan.shot
            } else {
                hasIntercept = plan.hasIntercept
                plannedTarget = plan.point
                plannedDelay = plan.delay
                plannedShot = plan.shot
                planTick = tick
                remaining = plan.delay
            }
            let salt: UInt64 = switch seat {
            case .cyan: 17
            case .orange: 43
            case .cyanWing: 29
            case .orangeWing: 61
            }
            cachedAimError = sin(Double(tick &+ salt) * 0.17)
                * difficulty.aimErrorRadians
            cachedHomeSide = ship.homeSide
        }

        let plannedPoint = plannedTarget ?? guardPost(homeSign: homeSign)
        let toBall = state.ball.position - ship.position
        let distance = simd_length(toBall)
        carryTicks = distance < 0.17 ? carryTicks &+ 1 : 0
        let ballIsHome = state.ball.position.x * homeSign > -0.02
        // Close in, chase the live ball rather than a prediction that has aged out.
        let anchor = distance < 0.34 && ballIsHome ? state.ball.position : plannedPoint
        let behindBall = distance > 0.000_001 ? simd_dot(toBall / distance, plannedShot) : 1
        let forcedSwat = carryTicks >= Self.carryLimitTicks && ballIsHome

        var target: SIMD2<Double>
        var closingVelocity = SIMD2<Double>.zero
        var striking = false
        if hasIntercept {
            // Sit a run-up behind the ball, then slide onto the contact point so the
            // ship is already moving along the shot line when the ball arrives.
            var lead = min(1, remaining / Self.driveWindow)
            if behindBall < 0.20, distance < 0.45 {
                lead = 1                                // wrong side of the ball: swing back
            }
            target = clamped(
                anchor - plannedShot * (Self.strikeStandoff + Self.strikeRunup * lead),
                homeSign: homeSign
            )
            closingVelocity = plannedShot * (difficulty.strikeSpeed * (1 - lead))
            striking = lead < 0.5
        } else {
            target = plannedPoint                       // ready position
        }
        if forcedSwat {
            target = clamped(anchor - plannedShot * Self.strikeStandoff, homeSign: homeSign)
            closingVelocity = plannedShot * (difficulty.strikeSpeed * 1.4)
            striking = true
        }
        if supporting {
            target = supportPost(homeSign: homeSign)
            closingVelocity = .zero
            striking = false
        }
        if pinnedByNet {
            target = SIMD2(homeSign * 0.34, arena.humpUndersideY - 0.34)
            closingVelocity = .zero
        }
        if recovering {
            target = SIMD2(ship.position.x, arena.floorY + 0.21)
            closingVelocity = .zero
        }

        let positionError = target - ship.position
        let range = simd_length(positionError)
        let approachSpeed = min(
            Self.approachSpeedCap,
            (2 * Self.brakingDeceleration * max(0, range - 0.015)).squareRoot()
        )
        var desiredVelocity = closingVelocity
        if range > 0.000_001 {
            desiredVelocity += positionError / range * approachSpeed
        }
        // Never ask for a descent that cannot be arrested, allowing for the turn.
        // Landing is allowed now, so this only stops the ship arriving so fast it
        // bounces away from a ball it meant to play.
        let headroom = max(0, ship.position.y - (arena.floorY + 0.065))
        desiredVelocity.y = max(
            desiredVelocity.y,
            -(2 * 2.6 * max(0, headroom - 0.04)).squareRoot()
        )

        var need = (desiredVelocity - ship.velocity) * Self.accelerationGain
            - configuration.gravity
        if crossingDanger {
            need.x = homeSign * (7 + abs(ship.velocity.x) * 2)
        }
        // Keep the nose inside a lift cone that tightens as the ship descends. A
        // lander pointed at the horizon has no vertical support and is half a
        // second of turning away from being able to save itself.
        let altitudeMargin = min(1, max(0, (ship.position.y - (arena.floorY + 0.05)) / 0.33))
        var minimumPitch = 0.42 + 0.30 * (1 - altitudeMargin)
        // The goal hangs from the roof, so the run-up is under the ball and
        // the ship spends its life needing to get low. Inside the cone every
        // sideways move is also a climb, so when it wants to sink and has the
        // height to spare, let the nose drop toward the horizon: it slides
        // across and falls at the same time instead of climbing away from
        // the ball.
        let wantsDescent = desiredVelocity.y < ship.velocity.y - 0.05
        if wantsDescent, altitudeMargin > 0.25 {
            minimumPitch = 0.22
        }
        need.y = max(need.y, abs(need.x) * tan(minimumPitch))
        // Only right down at the deck is a climb forced regardless: the floor
        // is survivable, and low balls have to be played from low down. A
        // genuinely dangerous descent is already caught by `recovering`.
        if altitudeMargin < 0.12 {
            need.y = max(need.y, 3.0)
        }

        var desiredAngle = atan2(need.y, need.x)
        if !crossingDanger, !striking, !recovering {
            desiredAngle += cachedAimError
        }
        let angleError = normalizedAngle(desiredAngle - ship.angle)
        let turnDemand = angleError * Self.turnGain
        let torque = abs(turnDemand) < Self.turnDeadzone ? 0 : max(-1, min(1, turnDemand))
        let nose = SIMD2(cos(ship.angle), sin(ship.angle))
        // Fire only once the nose is roughly where the demand points. A big
        // lateral demand always carries some lift, and burning on that lift
        // alone while the nose is still upright is how the ship climbs away
        // from a ball it was told to go down and get.
        let aligned = cos(angleError) > Self.thrustAlignment
        // The motor is all or nothing, and at full burn the nose carries far
        // more lift than the demand asked for. So when the ship is already
        // rising faster than it wants to, and a burn would lift it further,
        // coast: it keeps its sideways speed and sinks, which is the only way
        // a lander gets down to a low ball. The deck rule above still wins.
        let liftsWhenBurning = nose.y * configuration.maximumThrustAcceleration
            > -configuration.gravity.y
        let climbingAway = ship.velocity.y > desiredVelocity.y + 0.10
            && liftsWhenBurning
            && !recovering
            && altitudeMargin >= 0.12
        let thrust = crossingDanger
            ? cos(ship.angle) * homeSign > 0.25
            : aligned
                && !climbingAway
                && simd_dot(need, nose) > configuration.maximumThrustAcceleration * Self.thrustGate
        let fire = !supporting && wantsToFire(state: state, ship: ship, nose: nose, homeSign: homeSign)
        return PlayerInput(tick: tick, torque: torque, thrust: thrust, fire: fire)
    }

    /// Where the second ship on a side waits: back by its own wall at
    /// mid-height, out from under the ball and off the lead's run-up.
    private func supportPost(homeSign: Double) -> SIMD2<Double> {
        SIMD2(homeSign * 0.76, arena.floorY + 0.34)
    }

    /// True when the partner is the one who should play this ball. The wing
    /// yields on anything close to a tie; the lead only yields when it is
    /// clearly the farther of the two.
    private func supportsPartner(state: WorldState, seat: Seat, ship: ShipState) -> Bool {
        guard let partner = state.ships[seat.partner], !partner.isDestroyed else { return false }
        let mine = simd_distance(ship.position, state.ball.position)
        let theirs = simd_distance(partner.position, state.ball.position)
        return seat.isWing ? theirs < mine + 0.06 : theirs + 0.10 < mine
    }

    /// Shoot when the ball is out in front, from this half, and the nose is
    /// already pointing roughly the way the shot should go -- so a bolt sends
    /// it over rather than into the bot's own face. Too close and the hull
    /// will hit it anyway; too far and the bolt fizzles first.
    private func wantsToFire(
        state: WorldState,
        ship: ShipState,
        nose: SIMD2<Double>,
        homeSign: Double
    ) -> Bool {
        guard let alignment = difficulty.fireAlignment, ship.fireCooldownTicks == 0 else { return false }
        let toBall = state.ball.position - ship.position
        let distance = simd_length(toBall)
        let reach = configuration.boltSpeed * configuration.boltLifetime * 0.85
        guard distance > 0.16, distance < reach else { return false }
        // The trigger only works from home ground; the ball may be anywhere.
        guard ship.position.x * homeSign > 0.02 else { return false }
        guard simd_dot(toBall / distance, nose) > 0.985 else { return false }
        return simd_dot(nose, plannedShot) > alignment
    }

    /// Altitude a full recovery costs from here: swing the nose upright at the
    /// fixed turn rate, then brake at full thrust. Below that the ship is already
    /// falling into the floor and nothing else matters.
    private func recoveryIsUrgent(for ship: ShipState) -> Bool {
        let turnTime = abs(normalizedAngle(.pi / 2 - ship.angle))
            / configuration.torqueAcceleration
        let gravityPull = -configuration.gravity.y
        let descentAfterTurn = -ship.velocity.y + gravityPull * turnTime
        let dropWhileTurning = max(
            0,
            -ship.velocity.y * turnTime + 0.5 * gravityPull * turnTime * turnTime
        )
        // Tuning can leave thrust barely above gravity; never divide by nothing.
        let netLift = max(0.5, configuration.maximumThrustAcceleration - gravityPull)
        let brakingDistance = descentAfterTurn > 0
            ? descentAfterTurn * descentAfterTurn / (2 * netLift)
            : 0
        return ship.position.y - dropWhileTurning - brakingDistance < arena.floorY + 0.033
    }

    /// Rolls the ball forward through the arena and takes the first strike point
    /// on this half that the ship can actually get set up behind in time.
    private func planShot(
        for state: WorldState,
        ship: ShipState,
        homeSign: Double
    ) -> Plan {
        // Just under the hump: the goal hangs from the roof, so the useful
        // part of the court runs right up to the collar.
        let ceiling = arena.ceilingY - 0.275
        let floor = arena.floorY + 0.21
        let radius = state.ball.radius
        let ballGravity = configuration.gravity.y * configuration.ballGravityMultiplier
        let shipSpeed = simd_length(ship.velocity)
        var position = state.ball.position
        var velocity = state.ball.velocity
        var earliestArrival: Plan?

        for step in 1 ... Self.predictionSteps {
            velocity.y += ballGravity * Self.predictionStep
            position += velocity * Self.predictionStep
            if position.x - radius <= -arena.halfWidth {
                position.x = -arena.halfWidth + radius
                velocity.x = abs(velocity.x) * SimulationEngine.ballRestitution
            }
            if position.x + radius >= arena.halfWidth {
                position.x = arena.halfWidth - radius
                velocity.x = -abs(velocity.x) * SimulationEngine.ballRestitution
            }
            if position.y + radius >= arena.ceilingY {
                position.y = arena.ceilingY - radius
                velocity.y = -abs(velocity.y) * SimulationEngine.ballRestitution
            }
            if position.y - radius <= arena.floorY {
                position.y = arena.floorY + radius
                velocity.y = abs(velocity.y) * SimulationEngine.floorRestitution
            }
            // The net is a portal, not a wall. A rollout that reaches the open
            // mouth is a ball already through and gone, so stop projecting
            // rather than bouncing it off something that is not there. The
            // cap, the collar above the mouth, and the hump are all still
            // solid. The lips are left out: they only matter to a ball that
            // is already at the mouth, which is a ball this side has lost.
            if let hump = arena.humpContact(position: position, radius: radius) {
                position = hump.position
                let inward = simd_dot(velocity, hump.normal)
                if inward < 0 {
                    velocity -= hump.normal * ((1 + SimulationEngine.ballRestitution) * inward)
                }
            }
            if abs(position.x) <= arena.netHalfWidth + radius {
                if position.y <= arena.portalMouthTopY, position.y + radius >= arena.netBottomY {
                    break
                }
                if position.y > arena.portalMouthTopY {
                    // Solid collar above the mouth: it shoves the ball back
                    // out along the slope it came down.
                    let sign: Double = position.x < 0 ? -1 : 1
                    position.x = sign * (arena.netHalfWidth + radius)
                    velocity.x = sign * abs(velocity.x)
                } else if position.y + radius >= arena.netBottomY - radius {
                    position.y = arena.netBottomY - radius * 2
                    velocity.y = -abs(velocity.y)
                }
            }
            guard position.x * homeSign > 0.06,
                  position.y <= ceiling,
                  position.y >= floor else { continue }

            let shot = shotDirection(from: position, homeSign: homeSign)
            // Every shot is a lift now, so the run-up sits under the ball and
            // a low ball has its run-up on the floor. That is fine -- the
            // ground is survivable and `clamped` lifts the run-up off it --
            // as long as the contact itself is not down in the deck.
            let contact = position - shot * Self.strikeStandoff
            guard contact.y >= arena.floorY + 0.10 else { continue }
            let runup = position - shot * (Self.strikeStandoff + Self.strikeRunup)

            let delay = Double(step) * Self.predictionStep
            let candidate = Plan(hasIntercept: true, point: position, delay: delay, shot: shot)
            if earliestArrival == nil { earliestArrival = candidate }
            let travel = simd_length(clamped(runup, homeSign: homeSign) - ship.position)
            // A lander goes nowhere until its nose points the right way, so
            // the first quarter second of any plan buys no distance at all.
            let burn = max(0, delay - Self.turnLatency)
            let reach = 0.45 * shipSpeed * delay + 1.6 * burn * burn
            if travel + 0.05 <= reach { return candidate }
        }

        // Nothing is comfortably reachable, so chase the first arrival anyway.
        if let earliestArrival { return earliestArrival }
        let post = guardPost(homeSign: homeSign)
        return Plan(
            hasIntercept: false,
            point: post,
            delay: 9,
            shot: shotDirection(from: post, homeSign: homeSign)
        )
    }

    /// Ready position while the ball is on the far side of the net.
    private func guardPost(homeSign: Double) -> SIMD2<Double> {
        SIMD2(homeSign * 0.42, arena.floorY + 0.50)
    }

    /// Direction to send the ball from `point`. The face on this side is the
    /// goal this ship defends, so the ball must never be driven at it. The
    /// shot goes just under the cap instead: across into the far half, and
    /// rising, so it can drop onto the far lip and roll into the goal the
    /// other side is defending.
    private func shotDirection(from point: SIMD2<Double>, homeSign: Double) -> SIMD2<Double> {
        let aim = SIMD2(0, arena.netBottomY - Self.aimDepthUnderCap)
        var direction = simd_normalize(aim - point)
        // Always across, never a lob into the roof.
        if direction.x * homeSign > -0.35 {
            direction = simd_normalize(SIMD2(-homeSign * 0.35, direction.y))
        }
        return direction
    }

    /// Keeps a flight target on this side of the net and clear of the hazards.
    private func clamped(_ point: SIMD2<Double>, homeSign: Double) -> SIMD2<Double> {
        var result = point
        let minimumX = result.y > arena.humpUndersideY - 0.30 ? 0.12 : 0.03
        if result.x * homeSign < minimumX {
            result.x = homeSign * minimumX
        }
        if abs(result.x) > arena.halfWidth - 0.10 {
            result.x = homeSign * (arena.halfWidth - 0.10)
        }
        result.y = max(arena.floorY + 0.115, min(arena.ceilingY - 0.082, result.y))
        return result
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value < -.pi { value += 2 * .pi }
        return value
    }
}
