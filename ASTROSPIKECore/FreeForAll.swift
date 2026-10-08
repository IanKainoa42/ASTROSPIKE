import Foundation
import simd

// Free-for-all: three or four pilots in a round arena, one net each standing
// round the open middle. There are no halves and no teams -- every other
// hull is a rival --
// and nobody scores points. A ball through either face of your goal costs
// you a life; lose them all and your net closes and your ship leaves
// the field. The last pilot flying wins.
//
// The engine keeps this book itself, like the hoop court, and a duel never
// carries one: `WorldState.freeForAll` is nil, and nil is the switch.

public struct FreeForAllState: Codable, Equatable, Sendable {
    /// Lives each pilot starts with.
    public static let startingLives = 5

    /// The order seats take the bays, anticlockwise from the bottom of the
    /// ring.
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

    /// `bays[i]` owns net `i`, counting anticlockwise from the bottom.
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

    /// Pilots still flying, in bay order.
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

/// A bot for the free-for-all ring. Every mouth faces the rim, so it banks
/// the ball off the rim into the rival mouth nearest it, and never knocks
/// it on a line that runs -- straight or off the rim -- into its own.
///
/// Known gap: it defends weakly. It clears a ball in the lane in front of
/// its own mouth out sideways but keeps no goal, so its misses that rebound
/// off the bump flanks and rim can still go into its own net. It keeps short of every MAX CROSS line
/// and shoots a ball out on a rival's ground that it cannot reach. Alone
/// against idle hulls (two-hour samples) it takes about 1.3 rival lives a
/// minute at three pilots and 2.0 at four, and gives up 0.1-0.2 (default ring tuning).
public struct FreeForAllPilot: Sendable {
    /// How much nearer the ball a new net must be before the bot gives up
    /// the one it is working on, so a ball midway between two does not make
    /// it dither.
    static let targetHysteresis = 0.10

    public let difficulty: AIDifficulty
    private var configuration: SimulationConfiguration
    private(set) var targetGoal: Int?

    public init(difficulty: AIDifficulty, configuration: SimulationConfiguration) {
        self.difficulty = difficulty
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
    }

    public mutating func input(for state: WorldState, seat: Seat, arena: ArenaGeometry, tick: UInt64) -> PlayerInput {
        guard let ring = arena.ring else { return .idle(tick: tick) }
        var input = input(for: state, seat: seat, ring: ring, tick: tick)
        guard let field = state.freeForAll, let ship = state.ships[seat], !ship.isDestroyed,
              let own = field.bay(of: seat) else { return input }
        let guarded = { (index: Int) in !field.isSolid(goal: index) }
        let toBall = state.ball.position - ship.position
        let distance = simd_length(toBall)
        let reach = configuration.boltSpeed * configuration.boltLifetime * 0.85
        // A ball out on a rival's ground, past the line, the hull cannot
        // reach: hold at the line with the nose on it and shoot it.
        let unreachable = ring.offside(state.ball.position, home: own, guarded: guarded) != nil
        if unreachable, distance < reach, simd_length(ship.velocity) < 0.4, distance > 0.000_001 {
            let error = remainder(atan2(toBall.y, toBall.x) - ship.angle, 2 * .pi)
            input.torque = abs(error) < 0.03 ? 0 : max(-1, min(1, error * 4))
            input.thrust = false
        }
        // Fire when the nose is on the ball and the knock either frees an
        // unreachable ball or heads into an open rival mouth -- never into
        // its own -- from short of the line.
        guard let alignment = difficulty.fireAlignment, ship.fireCooldownTicks == 0,
              distance > 0.16, distance < reach,
              ring.offside(ship.position, home: own, guarded: guarded) == nil else { return input }
        let nose = SIMD2(cos(ship.angle), sin(ship.angle))
        guard simd_dot(toBall / distance, nose) > max(alignment, 0.985),
              !headsInto(own, from: state.ball.position, along: nose, ring: ring) else { return input }
        let scores = ring.spokeAngles.indices.contains { $0 != own && guarded($0) && headsInto($0, from: state.ball.position, along: nose, ring: ring) }
        if unreachable || scores { input.fire = true }
        return input
    }

    /// How near its own mouth the ball must come before the bot drops the
    /// attack and clears it.
    static let ringDefendRange = 0.55
    /// How far behind the ball the bot lines up before it drives through.
    static let ringStandoff = 0.11
    /// How wide of the ball, past its radius, the hull passes going round.
    static let ringClearance = 0.10
    /// A ball this close to the rim is treated as lying on it.
    static let ringRimBand = 0.06
    /// How far off dead behind the ball, in radians, the ship may be and
    /// still strike.
    static let ringStrikeArc = 0.35
    /// Going round the ball: the circle's radius and how much of it the
    /// ship takes at once.
    static let ringOrbitRadius = 0.32
    static let ringOrbitStep = 0.7
    /// How far a knock is followed to see whether it would carry the ball
    /// into the bot's own mouth.
    static let ringOwnMouthLookahead = 2.0
    /// Ship speed through the ball when it is only moving it on, not
    /// shooting: the middle has no weight to stop a ball, so a full strike
    /// to the middle carries it straight across.
    static let ringNudgeSpeed = 0.9
    /// How far short of a MAX CROSS line the bot holds a target.
    static let ringLineMargin = 0.04
    /// How far out in front of a rival mouth the bot moves a ball that has
    /// no clear line through the slot.
    static let ringStagingRoom = 0.25

    /// The ring bot. Every mouth faces the middle, on its bump's crown.
    /// A ball with a clear line through a rival slot the bot strikes straight
    /// at the mouth, from behind the ball, or from the MAX CROSS line if the
    /// ball is past it; one off to the side it first moves round in front of
    /// the mouth; one on the rim it runs along toward the target's bump. A ball in
    /// front of its own mouth it clears back out to the middle. It never
    /// knocks the ball on a line that runs into its own mouth.
    private mutating func input(for state: WorldState, seat: Seat, ring: RingField, tick: UInt64) -> PlayerInput {
        guard let field = state.freeForAll, let ship = state.ships[seat], !ship.isDestroyed else {
            return .idle(tick: tick)
        }
        let own = field.bay(of: seat)
        let ball = state.ball
        // Never aim past the MAX CROSS line: a target on a rival's ground is
        // pulled back short of it, so the bot shoots from the line rather
        // than leaning on the push-back.
        func onside(_ point: SIMD2<Double>) -> SIMD2<Double> {
            guard let own, let back = ring.offside(point, home: own, guarded: { !field.isSolid(goal: $0) }) else { return point }
            let depth = simd_length(back)
            return point + back * ((depth + Self.ringLineMargin) / depth)
        }
        // Where the ball will be by the time the ship gets there, roughly.
        let lead = min(0.25, simd_length(ball.position - ship.position) / 2.0)
        let spot = ball.position + ball.velocity * lead

        var aim: SIMD2<Double>
        var speed = min(Self.ringNudgeSpeed, configuration.ringTopSpeed * 0.55)
        if let own, threatens(spot, net: own, ring: ring) {
            // Clear: knock it back out of the slot, down the middle of it;
            // sideways only runs it into a post.
            let local = ring.toLocal(spot, net: own)
            aim = ring.toWorld(SIMD2(local.x * 0.5, local.y + 0.8), net: own)
            targetGoal = nil
        } else if let goal = chooseRingGoal(state: state, field: field, seat: seat, ring: ring, from: spot) {
            targetGoal = goal
            let mouth = ring.toWorld(SIMD2(0, ring.goalLineY - ring.ballRadius), net: goal)
            if downMouth(goal, from: spot, at: mouth, ring: ring) {
                aim = mouth
                speed = min(difficulty.strikeSpeed * 0.6, configuration.ringTopSpeed * 0.9)
            } else if simd_length(spot) > ring.rimRadius - ring.ballRadius - Self.ringRimBand {
                // On the rim: run it along toward the target, up its bump's
                // flank and back in. Nothing can get under it to push.
                let bearing = atan2(spot.y, spot.x)
                let out = ring.outward(at: spot)
                aim = spot + SIMD2(-out.y, out.x) * (remainder(ring.spokeAngles[goal] - bearing, 2 * .pi) >= 0 ? 0.5 : -0.5)
            } else {
                // Off to the side of the slot: move it on round in front of
                // the mouth, for a clear line next time.
                aim = ring.toWorld(SIMD2(0, ring.netDepth + Self.ringStagingRoom), net: goal)
            }
        } else {
            return fly(ship: ship, to: onside(.zero), closing: .zero, ring: ring, tick: tick)
        }

        // Aim error, the same each reaction window so it reads as a miss
        // rather than a wobble.
        var line = aim - spot
        let length = simd_length(line)
        line = length > 0.000_001 ? line / length : SIMD2(1, 0)
        let window = tick / difficulty.reactionIntervalTicks
        let jitter = (Double((window &* 2_654_435_761 &+ UInt64(seat.rawValue) &* 97) % 1000) / 500 - 1)
            * difficulty.aimErrorRadians
        line = Self.rotate(line, by: jitter)
        if let own, headsInto(own, from: spot, along: line, ring: ring) {
            // Bend the knock off the bot's own mouth.
            line = [0.6, -0.6, 1.2, -1.2].lazy.map { Self.rotate(line, by: $0) }
                .first { !self.headsInto(own, from: spot, along: $0, ring: ring) } ?? -line
        }

        let standoff = ring.ballRadius + Self.ringStandoff
        let behind = spot - line * standoff
        let fromBall = ship.position - spot
        let distance = simd_length(fromBall)
        let bearing = distance > 0.000_001 ? fromBall / distance : -line
        // How far round the ball the ship still has to go to be behind it.
        let turn = remainder(atan2(-line.y, -line.x) - atan2(bearing.y, bearing.x), 2 * .pi)
        if abs(turn) < Self.ringStrikeArc {
            let hit = -bearing
            let safe = own.map { !headsInto($0, from: spot, along: hit, ring: ring) } ?? true
            if distance < standoff * 1.6, safe {
                // Behind it and close: drive through along the line.
                return fly(ship: ship, to: onside(spot + line * standoff), closing: ball.velocity + line * speed, ring: ring, tick: tick)
            }
            return fly(ship: ship, to: onside(behind), closing: ball.velocity, ring: ring, tick: tick)
        }
        // Go round the ball on a circle clear of it, a step at a time, so
        // the hull never cuts across it and knocks it somewhere unplanned.
        let orbit = max(standoff + Self.ringClearance, min(distance, Self.ringOrbitRadius))
        let step = max(-Self.ringOrbitStep, min(Self.ringOrbitStep, turn))
        return fly(ship: ship, to: onside(spot + Self.rotate(bearing, by: step) * orbit), closing: ball.velocity, ring: ring, tick: tick)
    }

    static func rotate(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        SIMD2(v.x * cos(angle) - v.y * sin(angle), v.x * sin(angle) + v.y * cos(angle))
    }

    /// True when a ball at `point` sent along `direction` would cross `net`'s
    /// goal line inside the posts, coming in the mouth, within the lookahead
    /// -- straight, or after one bounce off the rim.
    private func headsInto(_ net: Int, from point: SIMD2<Double>, along direction: SIMD2<Double>, ring: RingField) -> Bool {
        if headsStraightInto(net, from: point, along: direction, ring: ring) { return true }
        // Where the line meets the rim, and the bounce back off it.
        let rim = ring.rimRadius - ring.ballRadius
        let b = simd_dot(point, direction)
        let c = simd_length_squared(point) - rim * rim
        let root = b * b - c
        guard root >= 0 else { return false }
        let hit = point + direction * (-b + root.squareRoot())
        let normal = ring.outward(at: hit)
        let bounce = direction - normal * ((1 + SimulationEngine.floorRestitution) * simd_dot(direction, normal))
        let length = simd_length(bounce)
        guard length > 0.000_001 else { return false }
        return headsStraightInto(net, from: hit, along: bounce / length, ring: ring)
    }

    private func headsStraightInto(_ net: Int, from point: SIMD2<Double>, along direction: SIMD2<Double>, ring: RingField) -> Bool {
        let local = ring.toLocal(point, net: net)
        let end = ring.toLocal(point + direction * Self.ringOwnMouthLookahead, net: net)
        guard local.y > ring.goalLineY, end.y < ring.goalLineY else { return false }
        let t = (local.y - ring.goalLineY) / (local.y - end.y)
        return abs(local.x + (end.x - local.x) * t) < ring.netHalfWidth + ring.ballRadius
    }

    /// True when a ball at `point` struck at `target` (the mouth) would run
    /// through `net`'s slot: its line crosses the mouth inside the posts.
    /// A ball already in the lane in front of the mouth counts.
    private func downMouth(_ net: Int, from point: SIMD2<Double>, at target: SIMD2<Double>, ring: RingField) -> Bool {
        let start = ring.toLocal(point, net: net)
        let end = ring.toLocal(target, net: net)
        if start.y >= ring.netDepth, abs(start.x) < ring.netInnerHalfWidth { return true }
        guard start.y > end.y else { return false }
        let t = (start.y - ring.netDepth) / (start.y - end.y)
        guard (0 ... 1).contains(t) else { return false }
        return abs(start.x + (end.x - start.x) * t) < ring.netInnerHalfWidth - ring.ballRadius
    }

    /// True when the ball is in front of a mouth: past it, toward the
    /// middle, and inside a cone opening out from the posts.
    private func inFront(_ local: SIMD2<Double>, ring: RingField) -> Bool {
        local.y > ring.netDepth && abs(local.x) < ring.netInnerHalfWidth + (local.y - ring.netDepth) * 1.2
    }

    /// The ball is in front of `net`'s mouth and close to it.
    private func threatens(_ point: SIMD2<Double>, net: Int, ring: RingField) -> Bool {
        let local = ring.toLocal(point, net: net)
        return inFront(local, ring: ring) && simd_length(point - ring.mouthCentre(net)) < Self.ringDefendRange
    }

    /// The open rival net whose mouth is nearest the ball, sticking with the
    /// current one unless another is clearly nearer.
    private func chooseRingGoal(state: WorldState, field: FreeForAllState, seat: Seat, ring: RingField, from point: SIMD2<Double>) -> Int? {
        let open = ring.spokeAngles.indices.filter { !field.isSolid(goal: $0) && field.owner(ofGoal: $0) != seat }
        func distance(_ index: Int) -> Double { simd_length(ring.mouthCentre(index) - point) }
        guard let nearest = open.min(by: { distance($0) < distance($1) }) else { return nil }
        if let current = targetGoal, open.contains(current), distance(current) <= distance(nearest) + Self.targetHysteresis {
            return current
        }
        return nearest
    }

    /// Flight on the ring: a velocity aimed at `target`, the nose turned to
    /// the demand, the motor fired once the nose is near it.
    private func fly(ship: ShipState, to target: SIMD2<Double>, closing: SIMD2<Double>, ring: RingField, tick: UInt64) -> PlayerInput {
        let out = ring.outward(at: ship.position)
        let up = -out
        let error = target - ship.position
        let range = simd_length(error)
        // The hull glides on drag toward its top speed, so the bot cruises
        // a little under it and brakes on most of the motor.
        let motor = configuration.ringThrust
        var desired = closing
        if range > 0.000_001 {
            desired += error / range * min(
                configuration.ringTopSpeed * 0.9,
                (2 * 0.75 * motor * max(0, range - 0.015)).squareRoot()
            )
        }
        let clearance = ring.rimRadius - simd_length(ship.position) - 0.05
        let fall = simd_dot(desired, out)
        let fallLimit = (2 * motor * max(0, clearance - 0.04)).squareRoot()
        if fall > fallLimit { desired -= out * (fall - fallLimit) }

        let weight = simd_length(ring.gravity(
            at: ship.position,
            rim: simd_length(configuration.gravity) * configuration.ring.gravity
        ))
        var need = (desired - ship.velocity) * 3.5 + up * weight
            + ship.velocity * configuration.ring.hullDrag
        // Ring gravity is a small fraction of the thrust, so the nose goes
        // wherever the demand points -- outward too, which every shot at a
        // mouth needs. Only just over the rim does it insist on lift.
        let clearanceShare = min(1, max(0, clearance / 0.33))
        if clearanceShare < 0.25, simd_dot(need, up) < motor * 0.55 {
            need += up * (motor * 0.55 - simd_dot(need, up))
        }

        let angleError = remainder(atan2(need.y, need.x) - ship.angle, 2 * .pi)
        let turn = angleError * 4
        let torque = abs(turn) < 0.06 ? 0 : max(-1, min(1, turn))
        let nose = SIMD2(cos(ship.angle), sin(ship.angle))
        let thrust = cos(angleError) > 0.7
            && simd_dot(need, nose) > motor * 0.34
        return PlayerInput(tick: tick, torque: torque, thrust: thrust)
    }
}
