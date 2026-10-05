import Foundation
import simd

// Free-for-all: three or four pilots down one long field, one roof-hung goal
// each. There are no halves and no teams -- every other hull is a rival --
// and nobody scores points. A ball through either face of your goal costs
// you a life; lose them all and your goal turns solid and your ship leaves
// the field. The last pilot flying wins.
//
// The engine keeps this book itself, like the hoop court, and a duel never
// carries one: `WorldState.freeForAll` is nil, and nil is the switch.

public struct FreeForAllState: Codable, Equatable, Sendable {
    /// Lives each pilot starts with.
    public static let startingLives = 5

    /// The order seats take the bays, left to right. The two leads hold the
    /// ends and the wings fill the middle, so the duel's two colours keep
    /// the same ends of the field they always had.
    public static let bayOrder: [Seat] = [.cyan, .cyanWing, .orangeWing, .orange]

    /// The seats for a field of `pilots`: you, then rivals, never more than
    /// the four seats there are.
    public static func seats(pilots: Int) -> Set<Seat> {
        switch pilots {
        case ...2: [.cyan, .orange]
        case 3: [.cyan, .cyanWing, .orange]
        default: Set(Seat.allCases)
        }
    }

    /// `bays[i]` owns goal `i`, counting goals left to right.
    public var bays: [Seat]
    public var lives: [Seat: Int]
    /// Set once one pilot is left flying.
    public var winner: Seat?
    /// The goal the next serve drops from: the one that just conceded, or
    /// the nearest one still in play.
    public var serveBay: Int

    public init(seats: Set<Seat>, lives: Int = startingLives) {
        bays = Self.bayOrder.filter(seats.contains)
        self.lives = Dictionary(uniqueKeysWithValues: bays.map { ($0, lives) })
        winner = nil
        // The first ball drops from the middle of the field, nearest nobody
        // in particular, rather than under the leftmost pilot's own goal.
        serveBay = bays.count / 2
    }

    public func isOut(_ seat: Seat) -> Bool { (lives[seat] ?? 0) <= 0 }

    /// Pilots still flying, left to right.
    public var standing: [Seat] { bays.filter { !isOut($0) } }

    public func owner(ofGoal index: Int) -> Seat? {
        bays.indices.contains(index) ? bays[index] : nil
    }

    public func bay(of seat: Seat) -> Int? { bays.firstIndex(of: seat) }

    /// A goal with nobody left to defend it is closed: the ball bounces off
    /// its faces like the collar above every mouth.
    public func isSolid(goal index: Int) -> Bool {
        owner(ofGoal: index).map(isOut) ?? true
    }

    /// The bay still in play nearest `index`, for the serve after a goal
    /// that knocked its owner out. The bays go round the ring, so the last
    /// is next to the first.
    public func nearestOpenBay(to index: Int) -> Int {
        func gap(_ bay: Int) -> Int {
            let straight = abs(bay - index)
            return min(straight, bays.count - straight)
        }
        return bays.indices
            .filter { !isSolid(goal: $0) }
            .min { gap($0) < gap($1) } ?? index
    }
}

/// A bot for the free-for-all field. The duel bot already knows how to put
/// a ball through a goal on a duel court, so this hands it one: the rival
/// goal nearest the ball, with the field shifted so that goal hangs at the
/// middle of a standard court, the bot's own ship the only hull in it, and
/// the bot's home half whichever side of that goal the ball is on.
///
/// Known gap: it attacks and never defends. Its own goal is only covered
/// when the ball happens to be nearer someone else's.
public struct FreeForAllPilot: Sendable {
    /// How much nearer the ball a new goal must be before the bot gives up
    /// the one it is working on, so a ball midway between two goals does not
    /// make it dither.
    static let targetHysteresis = 0.10
    /// How far past the middle of its target the ball must go before the
    /// bot switches sides of it, for the same reason.
    static let sideHysteresis = 0.15

    public let difficulty: AIDifficulty
    private var configuration: SimulationConfiguration
    private var controller: AIController
    private(set) var targetGoal: Int?
    private var homeSide: Team = .cyan
    /// On the ring: the ball or the ship is outside the target goal's duel
    /// court, so the bot flies the ring itself instead of the duel bot.
    private(set) var herding = false

    public init(difficulty: AIDifficulty, configuration: SimulationConfiguration) {
        self.difficulty = difficulty
        self.configuration = configuration
        controller = Self.makeController(difficulty: difficulty, configuration: configuration)
    }

    /// The duel court the bot is shown: the standard one, as wide as the real
    /// wall on the ball's side of the goal is far.
    private static func makeController(
        difficulty: AIDifficulty,
        configuration: SimulationConfiguration,
        wallDistance: Double = ArenaGeometry.standard.halfWidth,
        ring: RingField? = nil
    ) -> AIController {
        var court = ArenaGeometry.standard(ballRadius: configuration.ballRadius)
        court.halfWidth = wallDistance
        var controller = AIController(
            difficulty: difficulty,
            configuration: configuration,
            arena: court
        )
        controller.freeRoam = true
        controller.bowl = ring.map {
            AIController.Bowl(centre: SIMD2(0, $0.hubCentreY), rim: $0.rimRadius, hub: $0.hubRadius)
        }
        return controller
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
        controller.updateConfiguration(configuration)
    }

    public mutating func input(for state: WorldState, seat: Seat, arena: ArenaGeometry, tick: UInt64) -> PlayerInput {
        if let ring = arena.ring { return input(for: state, seat: seat, ring: ring, tick: tick) }
        guard let field = state.freeForAll, let ship = state.ships[seat],
              let goal = chooseGoal(state: state, field: field, seat: seat, arena: arena) else {
            return .idle(tick: tick)
        }
        let centre = arena.goalCentres[goal]
        // The bot plays from whichever side of the goal the ball is on, and
        // shoots it through the face on that side. Free-for-all has no
        // halves, so it simply flies under the goal to get there.
        let ballOffset = state.ball.position.x - centre
        var side = homeSide
        if goal != targetGoal {
            side = ballOffset < 0 ? .cyan : .orange
        } else {
            if side == .cyan, ballOffset > Self.sideHysteresis { side = .orange }
            if side == .orange, ballOffset < -Self.sideHysteresis { side = .cyan }
        }
        if goal != targetGoal || side != homeSide {
            targetGoal = goal
            homeSide = side
            let wall = side == .cyan ? centre + arena.halfWidth : arena.halfWidth - centre
            controller = Self.makeController(difficulty: difficulty, configuration: configuration, wallDistance: wall)
        }
        return controller.input(for: Self.view(of: state, seat: seat, ship: ship, centre: centre, homeSide: homeSide), seat: seat, tick: tick)
    }

    /// The ring: the rival goal nearest the ball, with the world turned so
    /// it hangs straight down. From the goal to the rim below it that is a
    /// duel court in a bowl -- the floor curving up either side and gravity
    /// pointing out from the hub -- and the duel bot is told so. Out of that
    /// court the bot herds the ball round the ring into it.
    private mutating func input(for state: WorldState, seat: Seat, ring: RingField, tick: UInt64) -> PlayerInput {
        guard let field = state.freeForAll, let ship = state.ships[seat] else { return .idle(tick: tick) }
        let ball = state.ball.position
        let open = ring.spokeAngles.indices.filter { !field.isSolid(goal: $0) && field.owner(ofGoal: $0) != seat }
        func distance(_ goal: Int) -> Double { simd_length(ring.mouthCentre(goal) - ball) }
        guard let nearest = open.min(by: { distance($0) < distance($1) }) else { return .idle(tick: tick) }
        var goal = nearest
        if let current = targetGoal, open.contains(current),
           distance(current) <= distance(nearest) + Self.targetHysteresis {
            goal = current
        }
        // The duel bot only makes sense inside the court it is shown: under
        // the hub, between the walls it thinks are there. The way in is
        // deeper than the way out so the two do not trade every tick.
        let court = ring.spoke
        func inCourt(_ point: SIMD2<Double>, margin: Double) -> Bool {
            let local = ring.toLocal(point, spoke: goal)
            return local.y < court.humpUndersideY - margin && abs(local.x) < Self.sectorHalfWidth(ring) - margin
        }
        let margin = herding || goal != targetGoal ? Self.courtEntryMargin : 0
        let wasHerding = herding
        herding = !(inCourt(ball, margin: margin) && inCourt(ship.position, margin: margin))
        if herding {
            targetGoal = goal
            return herd(ship: ship, ball: state.ball, ring: ring, goal: goal, tick: tick)
        }
        let ballOffset = ring.toLocal(ball, spoke: goal).x
        var side = homeSide
        if goal != targetGoal || wasHerding {
            side = ballOffset < 0 ? .cyan : .orange
        } else {
            if side == .cyan, ballOffset > Self.sideHysteresis { side = .orange }
            if side == .orange, ballOffset < -Self.sideHysteresis { side = .cyan }
        }
        if goal != targetGoal || side != homeSide || wasHerding {
            targetGoal = goal
            homeSide = side
            controller = Self.makeController(difficulty: difficulty, configuration: configuration,
                                             wallDistance: Self.sectorHalfWidth(ring), ring: ring)
        }
        return controller.input(
            for: Self.view(of: state, seat: seat, ship: ship, ring: ring, goal: goal, homeSide: homeSide),
            seat: seat,
            tick: tick
        )
    }

    /// Half the rim chord a goal owns, out to where the neighbouring goal's
    /// share begins: the duel bot is shown walls there, so it keeps a ball
    /// that has rolled wide rather than handing it back to herding.
    static func sectorHalfWidth(_ ring: RingField) -> Double {
        max(ArenaGeometry.standard.halfWidth, ring.rimRadius * sin(.pi / Double(ring.spokeAngles.count)))
    }

    /// How far inside the duel court the ball and ship must both be before
    /// the duel bot takes over from herding.
    static let courtEntryMargin = 0.12
    /// Herding flies round the ring at this radius, clear of the goals below
    /// the hub and over the top of a ball rolling on the rim.
    static let herdTravelRadius = 1.05
    /// Fastest the bot pushes the ball along the rim.
    static let herdPushSpeed = 0.75
    /// Push speed per unit of arc still to go, and the least it asks for:
    /// a ball sent at full speed rolls straight through the court.
    static let herdArrivalGain = 0.6
    static let herdArrivalFloor = 0.2

    /// Gets the ball into the target goal's court: fly round the ring to the
    /// side of the ball away from that goal, drop in behind it, and push it
    /// along the rim toward the goal. Flown in the world, where "up" is in
    /// toward the hub.
    private func herd(ship: ShipState, ball: BallState, ring: RingField, goal: Int, tick: UInt64) -> PlayerInput {
        let bearing = { (p: SIMD2<Double>) in atan2(p.y, p.x) }
        let ballBearing = bearing(ball.position)
        // +1 pushes the ball anticlockwise, -1 clockwise: the short way round.
        let way: Double = remainder(ring.spokeAngles[goal] - ballBearing, 2 * .pi) >= 0 ? 1 : -1
        let tangent = SIMD2(-sin(ballBearing), cos(ballBearing)) * way
        let lane = min(simd_length(ball.position), ring.rimRadius - 0.13)
        let behind = ballBearing - way * (ball.radius + 0.13) / max(lane, 0.3)
        let setUp = SIMD2(cos(behind), sin(behind)) * lane

        let shipBearing = bearing(ship.position)
        // Where the ship sits round the ring from the ball, positive ahead of
        // it toward the goal.
        let shipLead = remainder(shipBearing - ballBearing, 2 * .pi) * way
        let toBall = simd_distance(ship.position, ball.position)
        var target: SIMD2<Double>
        var closing = SIMD2<Double>.zero
        // The ball should reach the court slowly enough to stay in it: the
        // speed asked for falls with the arc still to go.
        let remaining = abs(remainder(ring.spokeAngles[goal] - ballBearing, 2 * .pi)) * lane
        let wanted = min(Self.herdPushSpeed, max(Self.herdArrivalFloor, remaining * Self.herdArrivalGain))
        let rolling = simd_dot(ball.velocity, tangent)
        if shipLead < 0, shipLead > -0.6, toBall < 0.32, rolling < wanted {
            // Behind the ball, near it, and the ball is slower than wanted:
            // drive through along the rim.
            target = ball.position + tangent * 0.12
            closing = tangent * wanted
        } else if shipLead < 0, shipLead > -0.6, toBall < 0.32 {
            // Already rolling fast enough: follow it without touching.
            target = setUp
            closing = tangent * rolling
        } else {
            let gap = remainder(behind - shipBearing, 2 * .pi)
            if abs(gap) < 0.30 {
                target = setUp
            } else {
                // Round the ring at travel height, a bounded step at a time
                // so the line never cuts across the hub.
                let step = shipBearing + max(-0.7, min(0.7, gap))
                target = SIMD2(cos(step), sin(step)) * Self.herdTravelRadius
            }
        }
        return fly(ship: ship, to: target, closing: closing, ring: ring, tick: tick)
    }


    /// The duel bot's flight law with gravity pointing out from the centre:
    /// a velocity aimed at `target`, the nose kept in a lift cone about the
    /// local "up", the motor fired once the nose is near the demand.
    private func fly(ship: ShipState, to target: SIMD2<Double>, closing: SIMD2<Double>, ring: RingField, tick: UInt64) -> PlayerInput {
        let out = ring.outward(at: ship.position)
        let up = -out
        let error = target - ship.position
        let range = simd_length(error)
        var desired = closing
        if range > 0.000_001 {
            desired += error / range * min(2.6, (2 * 2.0 * max(0, range - 0.015)).squareRoot())
        }
        let clearance = ring.rimRadius - simd_length(ship.position) - 0.05
        let fall = simd_dot(desired, out)
        let fallLimit = (2 * 2.6 * max(0, clearance - 0.04)).squareRoot()
        if fall > fallLimit { desired -= out * (fall - fallLimit) }

        var need = (desired - ship.velocity) * 3.5 + up * simd_length(configuration.gravity)
        let lift = simd_dot(need, up)
        let across = need - up * lift
        let altitude = min(1, max(0, clearance / 0.33))
        var pitch = 0.42 + 0.30 * (1 - altitude)
        if simd_dot(desired, out) > simd_dot(ship.velocity, out) + 0.05, altitude > 0.25 { pitch = 0.22 }
        var wantedLift = max(lift, simd_length(across) * tan(pitch))
        if altitude < 0.12 { wantedLift = max(wantedLift, 3.0) }
        need = across + up * wantedLift

        let angleError = remainder(atan2(need.y, need.x) - ship.angle, 2 * .pi)
        let turn = angleError * 4
        let torque = abs(turn) < 0.06 ? 0 : max(-1, min(1, turn))
        let nose = SIMD2(cos(ship.angle), sin(ship.angle))
        let thrust = cos(angleError) > 0.7
            && simd_dot(need, nose) > configuration.maximumThrustAcceleration * 0.34
        return PlayerInput(tick: tick, torque: torque, thrust: thrust)
    }

    /// The ring turned into goal `goal`'s own frame, the bot alone in it.
    static func view(of state: WorldState, seat: Seat, ship: ShipState, ring: RingField, goal: Int, homeSide: Team) -> WorldState {
        var copy = state
        var own = ship
        own.position = ring.toLocal(ship.position, spoke: goal)
        own.velocity = ring.vectorToLocal(ship.velocity, spoke: goal)
        own.angle = ship.angle - ring.frameAngle(goal)
        own.homeSide = homeSide
        copy.ships = [seat: own]
        for index in copy.balls.indices {
            copy.balls[index].position = ring.toLocal(copy.balls[index].position, spoke: goal)
            copy.balls[index].velocity = ring.vectorToLocal(copy.balls[index].velocity, spoke: goal)
        }
        for index in copy.bolts.indices {
            copy.bolts[index].position = ring.toLocal(copy.bolts[index].position, spoke: goal)
            copy.bolts[index].velocity = ring.vectorToLocal(copy.bolts[index].velocity, spoke: goal)
        }
        copy.bumpers = []
        copy.freeForAll = nil
        copy.sidesSwapped = false
        return copy
    }

    /// The rival goal still open that is nearest the ball, sticking with the
    /// current one unless another is clearly nearer.
    private func chooseGoal(state: WorldState, field: FreeForAllState, seat: Seat, arena: ArenaGeometry) -> Int? {
        let ballX = state.ball.position.x
        let open = arena.goalCentres.indices.filter { index in
            !field.isSolid(goal: index) && field.owner(ofGoal: index) != seat
        }
        guard let nearest = open.min(by: { abs(arena.goalCentres[$0] - ballX) < abs(arena.goalCentres[$1] - ballX) }) else {
            return nil
        }
        if let current = targetGoal, open.contains(current),
           abs(arena.goalCentres[current] - ballX) <= abs(arena.goalCentres[nearest] - ballX) + Self.targetHysteresis {
            return current
        }
        return nearest
    }

    /// The field as a duel court around one goal: everything shifted so the
    /// goal is at x = 0, and nobody else flying.
    static func view(of state: WorldState, seat: Seat, ship: ShipState, centre: Double, homeSide: Team) -> WorldState {
        let shift = SIMD2(centre, 0.0)
        var copy = state
        var own = ship
        own.position -= shift
        own.homeSide = homeSide
        copy.ships = [seat: own]
        for index in copy.balls.indices { copy.balls[index].position -= shift }
        for index in copy.bolts.indices { copy.bolts[index].position -= shift }
        copy.bumpers = []
        copy.freeForAll = nil
        copy.sidesSwapped = false
        return copy
    }
}
