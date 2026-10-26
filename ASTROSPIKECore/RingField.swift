import Foundation
import simd

/// The free-for-all field: a round air-hockey table. Under every pilot's
/// goal a bell-curve bump rises off the rim toward the middle, peak on the
/// goal's line; the net is sunk in the top of the bell, mouth cut across
/// it with both posts on the curve and the pocket inside the bump, and the
/// flanks fall smoothly away either side and stop just shy of the posts,
/// so the mouth is the opening. A shot that misses the mouth glances off a
/// flank and is sent on round toward a neighbour. With
/// the Bump height at zero the goals are slots flush in a plain round rim.
/// An optional bumper can stand in the middle.
///
/// Each net is drawn and collided in its own frame: x across the mouth, y
/// pointing in from the back of the pocket (outside the rim), through the
/// mouth, toward the middle. Nets and bump flanks are `ArenaObstacle`
/// capsules. The ball meets a live net's frame and goes in only through the
/// mouth; the rim itself opens there. A hull meets every net shut, so
/// nobody parks behind a goal line.
public struct RingField: Equatable, Sendable {
    /// Centre to rim at a Ring size of 1: the size the old hub-and-spoke
    /// ring was. The Ring size setting scales it; hulls, ball, nets and the
    /// centre bumper keep their size, so a bigger ring is more room.
    public static let baseRimRadius = 1.52
    /// Each pilot's MAX CROSS line, as a share of the distance out to the
    /// mouths: the arc across each rival's ground past which the rival
    /// shoves a pilot back, as the duel's line does half way into the far
    /// half. The MAX CROSS line setting.
    public var maxCrossShare: Double
    /// Whether the round bumper in the middle is standing.
    public var centreBumper: Bool
    /// How many times its duel size every hull flies and is drawn at on
    /// the ring: the Hull size setting.
    public var hullScale: Double
    /// Thickness of a net's frame, as a capsule radius.
    public static let netWall = 0.014
    /// Radius of the round bumper in the middle.
    public static let centreBumperRadius = 0.09
    /// How far the peak of each goal's bell stands in off the rim, on the
    /// goal's line: the Bump height setting, a share of the rim radius,
    /// held to its cap. Zero (or too low to clear the slot) is a plain rim,
    /// goals flush. The mouth is cut across the top, a little short of it.
    public var cornerDepth: Double
    /// The bell's standard deviation, as a share of the rim from a goal's
    /// line to the valley: the Bump width setting.
    public var bumpSigma: Double
    /// Distance from the centre to the middle of every mouth. On a bump the
    /// mouth is cut across the bell where both posts sit on the curve. With
    /// no bumps the mouth's ends sit on the rim and the middle of the chord
    /// is a hair inside, so the slot reads flush with the wall.
    public var mouthRadius: Double

    public var rimRadius: Double
    /// The way each net sits, out from the centre. Net 0 is at the bottom of
    /// the screen, like the duel's floor.
    public var spokeAngles: [Double]
    public var ballRadius: Double

    /// Half the net's mouth, out to the middle of each post: the puck plus
    /// room either side, 0.16 or 1.85 radii when that is more, so the
    /// opening is a goal and not a crack between the barriers.
    public var netHalfWidth: Double
    /// Back of the net to the mouth, along the frame's centreline.
    public var netDepth: Double
    /// Each net's two sides, mouth to the rounded corners of the pocket.
    public var posts: [ArenaObstacle]
    /// Each net's back, post to post round the rounded corners.
    public var backs: [[ArenaObstacle]]
    /// Every bump's two flanks, each from a post down to the rim in the
    /// valley. Empty when the Bump height is zero: a plain round rim.
    public var corners: [ArenaObstacle]
    /// The centre bumper, when it is standing. Empty when the toggle is off.
    public var centre: [ArenaObstacle]
    /// A round guard in front of every goal, on a track across the mouth,
    /// one per net in net order. Empty when the Goal guards toggle is off.
    /// Sliding, a hull, the beam or a bolt shoves it along and it stays
    /// where it stops; stood still, it is a post where Settings put it.
    public var guards: [ArenaObstacle]
    /// Radius of a goal guard.
    public static let guardRadius = 0.06
    /// Room between a guard at the Guard distance's far end and the MAX
    /// CROSS line.
    static let guardLineGap = 0.04
    /// A pilot's spawn, across from the post and out from the mouth.
    static let spawnBeside = 0.18
    static let spawnOut = 0.28
    /// The longest a sliding guard runs either side of its centre.
    static let guardMaxReach = 0.9

    public init(pilots: Int, ballRadius: Double, tuning: RingTuning = RingTuning()) {
        let count = max(2, pilots)
        self.ballRadius = ballRadius
        maxCrossShare = tuning.lineShare
        centreBumper = tuning.centreBumper
        hullScale = min(3, max(1, tuning.hullSize))
        rimRadius = Self.baseRimRadius * min(2.5, max(1, tuning.size))
        spokeAngles = (0 ..< count).map { -.pi / 2 + Double($0) * 2 * .pi / Double(count) }
        netHalfWidth = ballRadius + max(0.16, 1.85 * ballRadius) + Self.netWall
        netDepth = 2 * ballRadius + 0.07 + Self.netWall
        posts = []
        backs = []
        corners = []
        centre = []
        guards = []
        cornerDepth = 0
        bumpSigma = 0
        let depth = min(max(0, tuning.bumpHeight) * rimRadius, 0.40 * rimRadius)
        cornerDepth = depth > Self.leastBump ? depth : 0
        bumpSigma = max(0.05, tuning.bumpWidth)
        mouthRadius = (rimRadius * rimRadius - netHalfWidth * netHalfWidth).squareRoot()
        if cornerDepth > 0 {
            // Where the posts' ends meet the bell: settle the mouth's
            // distance in until each end sits on the curve.
            mouthRadius = rimRadius - cornerDepth
            for _ in 0 ..< 40 {
                let post = rimRadius - bumpHeight(at: atan2(netHalfWidth, mouthRadius))
                mouthRadius = max(post * post - netHalfWidth * netHalfWidth, 0.01).squareRoot()
            }
        }
        for index in spokeAngles.indices {
            let outline = Self.segments(netOutline.map { toWorld($0, net: index) }, radius: Self.netWall)
            posts += [outline[0], outline[outline.count - 1]]
            backs.append(Array(outline[1 ..< outline.count - 1]))
        }
        if hasBumps {
            for index in spokeAngles.indices {
                for side in [-1.0, 1.0] {
                    corners += Self.segments(bumpFlank(index, side: side), radius: Self.netWall)
                }
            }
        }
        if centreBumper {
            centre = [.peg(.zero, radius: Self.centreBumperRadius)]
        }
        if tuning.goalGuards {
            // Out in front of the mouth, `guardDistance` of the way to the
            // MAX CROSS line: at 1 the guard's far edge sits just inside the
            // line, on the owner's ground. Sliding, it runs a track three
            // mouths wide or so, short of the wedge's borders so two
            // neighbours' guards never meet; `guardShift` of that reach
            // puts it across.
            let toLine = mouthRadius - maxCrossRadius - Self.guardRadius - Self.guardLineGap
            let distance = max(0.18, min(1, max(0.2, tuning.guardDistance)) * toLine)
            let trackRadius = netBackRadius - netDepth - distance
            let wedge = trackRadius * tan(.pi / Double(count)) - Self.guardRadius
            var reach = min(Self.guardMaxReach, 0.75 * wedge)
            // Pulled in near the mouth, the track stops short of the hulls'
            // spawn beside it.
            let spawn = SIMD2(netHalfWidth + Self.spawnBeside, netDepth + Self.spawnOut)
            let clear = Self.guardRadius + ShipHitbox.shared.reach * hullScale + 0.04
            let rise = abs(netDepth + distance - spawn.y)
            if rise < clear { reach = min(reach, spawn.x - (clear * clear - rise * rise).squareRoot()) }
            reach = max(netInnerHalfWidth - Self.guardRadius, reach)
            let shift = min(1, max(-1, tuning.guardShift)) * reach
            for index in spokeAngles.indices {
                let out = Self.outward(spokeAngles[index])
                let across = SIMD2(-out.y, out.x)
                let anchor = toWorld(SIMD2(shift, netDepth + distance), net: index)
                guards.append(.peg(
                    anchor,
                    radius: Self.guardRadius,
                    sprung: true,
                    track: across,
                    travel: tuning.guardsSlide ? (-reach - shift) ... (reach - shift) : 0 ... 0
                ))
            }
        }
    }

    /// What the ball meets: the bump flanks, the centre bumper, every
    /// net's frame, and a bar across the mouth of every net in `solid` (a
    /// knocked-out pilot's).
    public func ballWalls(solid: (Int) -> Bool) -> [ArenaObstacle] {
        corners + centre + posts + backs.flatMap { $0 } + spokeAngles.indices.filter(solid).map(mouthBar)
    }

    /// Every net in `solid`, shut all round: frame and mouth. A hull meets
    /// every net this way, live or not, as well as the bump flanks.
    public func closedNets(_ solid: (Int) -> Bool) -> [ArenaObstacle] {
        spokeAngles.indices.filter(solid).flatMap { index in
            [posts[2 * index], posts[2 * index + 1], mouthBar(index)] + backs[index]
        }
    }

    // MARK: - Frames

    /// Straight out from the centre at `bearing`.
    static func outward(_ bearing: Double) -> SIMD2<Double> { SIMD2(cos(bearing), sin(bearing)) }

    /// Distance from the centre to the back of every net's frame. Sunk in a
    /// bump the pocket is inside the rim; flush, it hangs outside.
    public var netBackRadius: Double { mouthRadius + netDepth }

    /// The least bump height that clears a flush slot's chord; any lower
    /// is a plain rim.
    static let leastBump = 0.03

    /// Whether the goals stand on bumps, or sit flush in a plain rim.
    public var hasBumps: Bool { cornerDepth > 0 }

    /// Whether the pocket hangs outside the rim, so the rim must open at
    /// the mouth. A pocket sunk deep enough in its bump is walled all round.
    public var pocketsPastRim: Bool { netBackRadius + Self.netWall > rimRadius - 0.001 }

    /// How far round the rim each post stands, out to the middle of the post.
    public var postHalfAngle: Double { asin(min(0.95, netHalfWidth / rimRadius)) }

    /// How far round the rim the ball's centre may pass: inside the posts,
    /// so the opening in the wall is the slot and not the wood beside it.
    public var mouthHalfAngle: Double { asin(min(0.95, netInnerHalfWidth / rimRadius)) }

    /// True when `point` lies in an open goal's slot, the wedge the rim
    /// gives up so the ball can leave the circle into the pocket.
    public func admitsThroughRim(_ point: SIMD2<Double>, open: (Int) -> Bool) -> Bool {
        guard pocketsPastRim else { return false }
        let bearing = atan2(point.y, point.x)
        return spokeAngles.indices.contains { index in
            open(index) && abs(remainder(bearing - spokeAngles[index], 2 * .pi)) < mouthHalfAngle
        }
    }

    /// Net `index`'s frame point `local` in the world.
    public func toWorld(_ local: SIMD2<Double>, net index: Int) -> SIMD2<Double> {
        let out = Self.outward(spokeAngles[index])
        let across = SIMD2(-out.y, out.x)
        return out * (netBackRadius - local.y) + across * local.x
    }

    /// A world point in net `index`'s frame.
    public func toLocal(_ point: SIMD2<Double>, net index: Int) -> SIMD2<Double> {
        let out = Self.outward(spokeAngles[index])
        let across = SIMD2(-out.y, out.x)
        return SIMD2(simd_dot(point, across), netBackRadius - simd_dot(point, out))
    }

    /// How far round from its goal a post's mouth end stands.
    public var flankStartAngle: Double { atan2(netHalfWidth, mouthRadius) }

    /// How far, in world units, a barrier's near end stops short of the post.
    /// Just shy: the wall does not pinch the mouth, and the opening is the
    /// goal rather than a crack beside it.
    public static let barrierShy = 0.05

    /// Where a barrier's near end stands: a shy past the post, still well
    /// short of the valley.
    public var barrierStartAngle: Double {
        let shy = Self.barrierShy / max(0.3, mouthRadius)
        return min(flankEndAngle * 0.85, flankStartAngle + shy)
    }

    /// How far round from its goal a bump reaches: half way to the next
    /// goal, the bottom of the valley, where it meets the neighbour's flank.
    public var flankEndAngle: Double { Double.pi / Double(spokeAngles.count) }

    /// How far in off the rim the bell under a goal stands `offset` radians
    /// round from the goal's line: peak `cornerDepth` on the line, falling
    /// smoothly to the rim in the valley either side.
    public func bumpHeight(at offset: Double) -> Double {
        let end = flankEndAngle
        guard cornerDepth > 0, abs(offset) < end else { return 0 }
        let sigma = bumpSigma * end
        let bell = { (x: Double) in exp(-x * x / (2 * sigma * sigma)) }
        // Lowered by the bell's height at the valley so it lands on the rim.
        let foot = bell(end)
        return cornerDepth * (bell(offset) - foot) / (1 - foot)
    }

    /// One flank of net `index`'s bump: from just shy of the post (`side`
    /// -1 is the clockwise post) down the bell to the rim in the valley.
    /// Sampled finely enough that the chain reads as a smooth curve. The
    /// goal's opening is the gap between the two near ends.
    public func bumpFlank(_ index: Int, side: Double) -> [SIMD2<Double>] {
        let start = barrierStartAngle, end = flankEndAngle
        let steps = 40
        return (0 ... steps).map { step in
            let offset = start + (end - start) * Double(step) / Double(steps)
            return Self.outward(spokeAngles[index] + side * offset) * (rimRadius - bumpHeight(at: offset))
        }
    }

    /// A spring on a hull toward its own mouth: acceleration grows with
    /// the distance, so the far side pulls harder than a step away. Zero
    /// strength pulls nothing. The puck is not a hull and is never pulled.
    public func goalSpring(at point: SIMD2<Double>, home: Int, strength: Double) -> SIMD2<Double> {
        guard strength > 0, spokeAngles.indices.contains(home) else { return .zero }
        return (mouthCentre(home) - point) * strength
    }

    /// Where a pilot starts: just inside the rim, beside their own mouth,
    /// nose to the middle. Clear of the bump's flank, so an idle hull is
    /// not a keeper parked in its own goal.
    public func spawnPoint(bay: Int) -> SIMD2<Double> {
        toWorld(SIMD2(netHalfWidth + Self.spawnBeside, netDepth + Self.spawnOut), net: bay)
    }

    /// The bearings of the valleys, midway between neighbouring mouths,
    /// where two bumps' flanks meet the rim. The face-off drifts out toward one of these.
    public var gapBearings: [Double] {
        spokeAngles.map { $0 + .pi / Double(spokeAngles.count) }
    }

    /// The net whose direction is nearest `point`'s.
    public func spokeIndex(nearest point: SIMD2<Double>) -> Int {
        let bearing = atan2(point.y, point.x)
        func gap(_ index: Int) -> Double { abs(remainder(bearing - spokeAngles[index], 2 * .pi)) }
        return spokeAngles.indices.min { gap($0) < gap($1) } ?? 0
    }

    /// Straight out from the centre: the way gravity pulls at `point`.
    public func outward(at point: SIMD2<Double>) -> SIMD2<Double> {
        let distance = simd_length(point)
        return distance > 0.000_001 ? point / distance : SIMD2(0, -1)
    }

    /// Spin gravity at `point`: straight out, nothing at the centre, growing
    /// in step with the distance to `rim` at the rim itself. The middle is
    /// light air and only the rim pulls with full weight.
    public func gravity(at point: SIMD2<Double>, rim strength: Double) -> SIMD2<Double> {
        point * (strength / rimRadius)
    }

    // MARK: - Nets

    /// The middle of net `index`'s mouth, in the world.
    public func mouthCentre(_ index: Int) -> SIMD2<Double> {
        toWorld(SIMD2(0, netDepth), net: index)
    }

    /// The line a ball's centre must cross to be all the way in: a radius
    /// inside the mouth, so the whole ball is over it.
    public var goalLineY: Double { netDepth - ballRadius }

    /// Half the open width inside the posts.
    public var netInnerHalfWidth: Double { netHalfWidth - Self.netWall }

    /// The net's frame, post to post round the back, in its own frame: two
    /// straight sides and a rounded back, so the inside corners never pinch
    /// the ball. The mouth is the open end, flush with the rim.
    public var netOutline: [SIMD2<Double>] {
        let w = netHalfWidth
        let fillet = 0.6 * w
        var points = [SIMD2(-w, netDepth), SIMD2(-w, fillet)]
        let steps = 6
        for step in 1 ... steps {
            let angle = Double.pi + Double(step) / Double(steps) * (Double.pi / 2)
            points.append(SIMD2(-w + fillet, fillet) + SIMD2(cos(angle), sin(angle)) * fillet)
        }
        for step in 0 ... steps {
            let angle = 1.5 * Double.pi + Double(step) / Double(steps) * (Double.pi / 2)
            points.append(SIMD2(w - fillet, fillet) + SIMD2(cos(angle), sin(angle)) * fillet)
        }
        points.append(SIMD2(w, netDepth))
        return points
    }

    static func segments(_ points: [SIMD2<Double>], radius: Double) -> [ArenaObstacle] {
        zip(points, points.dropFirst()).map { ArenaObstacle(start: $0, end: $1, radius: radius) }
    }

    /// A bar across net `index`'s mouth: shut to a knocked-out pilot's net,
    /// and to every hull, so nobody parks inside their own net.
    public func mouthBar(_ index: Int) -> ArenaObstacle {
        ArenaObstacle(
            start: toWorld(SIMD2(-netHalfWidth, netDepth), net: index),
            end: toWorld(SIMD2(netHalfWidth, netDepth), net: index),
            radius: Self.netWall
        )
    }

    /// The net a ball went all the way into between `start` and `end`, if
    /// any: its centre crossed the goal line inside the posts, coming in
    /// from the mouth.
    public func goalCrossing(from start: SIMD2<Double>, to end: SIMD2<Double>) -> Int? {
        for index in spokeAngles.indices {
            let a = toLocal(start, net: index)
            let b = toLocal(end, net: index)
            guard a.y >= goalLineY, b.y < goalLineY else { continue }
            let t = (a.y - goalLineY) / (a.y - b.y)
            let x = a.x + (b.x - a.x) * t
            if abs(x) < netInnerHalfWidth { return index }
        }
        return nil
    }

    // MARK: - MAX CROSS

    /// Every pilot's ground is the wedge of the ring round their net, gap to
    /// gap. The middle inside this radius is everyone's; past it a pilot
    /// may fly only on their own ground or a knocked-out pilot's.
    public var maxCrossRadius: Double { mouthRadius * maxCrossShare }

    /// Whose ground `point` is on: the net it shares a wedge with.
    public func ground(at point: SIMD2<Double>) -> Int { spokeIndex(nearest: point) }

    /// The bearings of net `index`'s two borders, the gaps either side.
    public func borders(of index: Int) -> (low: Double, high: Double) {
        let half = Double.pi / Double(spokeAngles.count)
        return (spokeAngles[index] - half, spokeAngles[index] + half)
    }

    /// How a pilot from net `home` at `point` gets back onside: the shortest
    /// step onto ground they may fly, or nil if they are on it. `guarded`
    /// says which nets still have a pilot defending their ground. A border
    /// between two guarded wedges is no way through: only the arc, their
    /// own ground or an unguarded wedge counts as onside.
    public func offside(_ point: SIMD2<Double>, home: Int, guarded: (Int) -> Bool) -> SIMD2<Double>? {
        let distance = simd_length(point)
        guard distance > maxCrossRadius else { return nil }
        let wedge = ground(at: point)
        guard wedge != home, guarded(wedge) else { return nil }
        var best = point * (maxCrossRadius / distance) - point
        let count = spokeAngles.count
        let (low, high) = borders(of: wedge)
        for (bearing, neighbour) in [(low, (wedge + count - 1) % count), (high, (wedge + 1) % count)]
        where neighbour == home || !guarded(neighbour) {
            let along = Self.outward(bearing)
            let step = along * max(0, simd_dot(point, along)) - point
            if simd_length(step) < simd_length(best) { best = step }
        }
        return best
    }
}

/// Every free-for-all knob a pilot can turn: how the ring flies, how hard
/// each pilot's MAX CROSS line holds, where the lines stand, and whether
/// the centre bumper is up. Online, the host's settings ride the wire so
/// every board flies the same table.
public struct RingTuning: Equatable, Sendable, Codable {
    /// The field's radius, as a multiple of the old ring's. Hulls, ball and
    /// nets keep their size: the Ring size setting is more room, drawn as
    /// smaller hulls on the same screen.
    public var size = 1.5
    /// The motor's push on the ring, as a share of the Thrust slider.
    public var speed = 0.80
    /// Velocity bled off a ring hull each second. Held thrust builds speed
    /// along 1 - e^(-drag t) toward thrust / drag, and a hull let go glides
    /// to a stop on it.
    public var hullDrag = 0.85
    /// Velocity bled off the ball each second: a puck on air.
    public var ballDrag = 0.41
    /// The share of the duel's gravity felt at the rim. Ring gravity is spin
    /// gravity: nothing at the centre, growing straight out to this.
    public var gravity = 0.45
    /// How hard a rival past a MAX CROSS line is shoved back, per unit of
    /// depth. The duel's is 18.
    public var linePush = 17.0
    /// How much speed the line steals from a rival past it. The duel's is 5.
    public var lineBrake = 0.0
    /// Where each MAX CROSS arc stands, as a share of the way out to the
    /// mouths.
    public var lineShare = 0.5
    /// A loose spring on each hull toward its own goal, harder the farther
    /// it flies. Zero leaves the MAX CROSS line as the only pull home. The
    /// puck is not pulled.
    public var goalPull = 0.0
    /// The round bumper in the middle. Off leaves the face-off clear.
    public var centreBumper = true
    /// How far each goal's bump stands in off the rim, rim to mouth, as a
    /// share of the rim radius. Zero is a plain round rim, goals flush.
    public var bumpHeight = 0.22
    /// How wide each bump's bell is: its standard deviation as a share of
    /// the rim from the goal's line to the valley. Wide enough that the
    /// wall stays up across the arc and stops just shy of the goal.
    public var bumpWidth = 0.52
    /// The puck's radius on the ring, as a multiple of the duel ball's
    /// nominal one, apart from the duel's Ball size. Its goals are cut to
    /// it, so a bigger puck is a bigger goal, and the spin it carries reads
    /// on its notch.
    public var puckSize = 2.5
    /// Every hull on the ring, hitbox and drawing together, as a multiple
    /// of its duel size. A bigger ring and a bigger puck left the hulls
    /// small beside them.
    public var hullSize = 2.0
    /// Two balls in play at once. A goal re-drops only the ball that went
    /// in; the other plays on.
    public var twoBalls = true
    /// Seconds between one bolt and the next on the ring, apart from the
    /// duel's own fire rate. A ring is a crowd, so it fires much slower.
    public var fireCooldown = 1.5
    /// A round guard in front of every goal, so a shot from anywhere does
    /// not go straight in.
    public var goalGuards = true
    /// The guards ride a track across the mouth and stay where they are
    /// shoved. Off, each stands still where the two sliders below put it.
    public var guardsSlide = true
    /// How far out from the mouth each guard stands, as a share of the way
    /// to the MAX CROSS line: 1 is just inside it.
    public var guardDistance = 1.0
    /// Where across its track each guard stands, -1 at one end to 1 at
    /// the other. Sliding, it is where the guard starts every point.
    public var guardShift = 0.0

    public init() {}

    /// One slider: what it sets, its travel, and its key in the defaults.
    public struct Knob: Identifiable {
        public let key: String
        public let title: String
        public let range: ClosedRange<Double>
        public let step: Double
        /// Shown as a percentage rather than a number.
        public let percent: Bool
        public let keyPath: WritableKeyPath<RingTuning, Double>
        /// Shown in whole degrees.
        public var degrees = false
        /// Shown in seconds.
        public var seconds = false
        public var id: String { key }
    }

    /// The defaults key for the centre bumper. Not a slider.
    public static let centreBumperKey = "ring.centreBumper"
    /// The defaults key for two balls. Not a slider.
    public static let twoBallsKey = "ring.twoBalls"
    /// The defaults key for the goal guards. Not a slider.
    public static let goalGuardsKey = "ring.goalGuards"
    /// The defaults key for sliding guards. Not a slider.
    public static let guardsSlideKey = "ring.guardsSlide"
    /// The guard sliders, which Settings shows under the Goal guards toggle.
    public static let guardKnobKeys: Set<String> = ["ring.guardLine", "ring.guardShift"]

    /// Every knob, in the order the sliders stand. Ring gravity keeps the key
    /// it had when it was the only one, so a stored setting carries over.
    public static var knobs: [Knob] {
        [
            Knob(key: "ring.size", title: "Ring size", range: 1.0 ... 2.5, step: 0.05, percent: true, keyPath: \.size),
            Knob(key: "ring.speed", title: "Thrust", range: 0.1 ... 1.2, step: 0.05, percent: true, keyPath: \.speed),
            Knob(key: "ring.hullDrag", title: "Hull drag", range: 0.05 ... 1.5, step: 0.05, percent: false, keyPath: \.hullDrag),
            Knob(key: "ring.puckSize", title: "Puck size", range: 1.5 ... 3.0, step: 0.05, percent: true, keyPath: \.puckSize),
            Knob(key: "ring.hullSize", title: "Hull size", range: 1.0 ... 3.0, step: 0.05, percent: true, keyPath: \.hullSize),
            Knob(key: "ring.ballDrag", title: "Puck drag", range: 0 ... 0.8, step: 0.01, percent: false, keyPath: \.ballDrag),
            Knob(key: "ringGravity", title: "Ring gravity", range: 0 ... 1.5, step: 0.05, percent: true, keyPath: \.gravity),
            Knob(key: "ring.linePush", title: "MAX CROSS push", range: 0 ... 30, step: 0.5, percent: false, keyPath: \.linePush),
            Knob(key: "ring.lineBrake", title: "MAX CROSS brake", range: 0 ... 8, step: 0.1, percent: false, keyPath: \.lineBrake),
            Knob(key: "ring.lineShare", title: "MAX CROSS line", range: 0.3 ... 1.0, step: 0.02, percent: true, keyPath: \.lineShare),
            Knob(key: "ring.goalPull", title: "Goal pull", range: 0 ... 2.5, step: 0.05, percent: false, keyPath: \.goalPull),
            Knob(key: "ring.bumpHeight", title: "Bump height", range: 0 ... 0.40, step: 0.01, percent: true, keyPath: \.bumpHeight),
            Knob(key: "ring.bumpWidth", title: "Bump width", range: 0.15 ... 0.70, step: 0.01, percent: true, keyPath: \.bumpWidth),
            Knob(key: "ring.fireCooldown", title: "Fire rate", range: 0.45 ... 4.0, step: 0.05, percent: false, keyPath: \.fireCooldown, seconds: true),
            Knob(key: "ring.guardLine", title: "Guard distance", range: 0.2 ... 1.0, step: 0.02, percent: true, keyPath: \.guardDistance),
            Knob(key: "ring.guardShift", title: "Guard across", range: -1 ... 1, step: 0.05, percent: true, keyPath: \.guardShift),
        ]
    }

    /// The pilot's settings, each clamped to its slider; a knob never set
    /// reads its default.
    public static func stored(in defaults: UserDefaults = .standard) -> RingTuning {
        var tuning = RingTuning()
        for knob in knobs {
            guard let value = defaults.object(forKey: knob.key) as? Double else { continue }
            tuning[keyPath: knob.keyPath] = min(knob.range.upperBound, max(knob.range.lowerBound, value))
        }
        tuning.centreBumper = defaults.object(forKey: centreBumperKey) as? Bool ?? RingTuning().centreBumper
        tuning.twoBalls = defaults.object(forKey: twoBallsKey) as? Bool ?? RingTuning().twoBalls
        tuning.goalGuards = defaults.object(forKey: goalGuardsKey) as? Bool ?? RingTuning().goalGuards
        tuning.guardsSlide = defaults.object(forKey: guardsSlideKey) as? Bool ?? RingTuning().guardsSlide
        return tuning
    }

    /// Writes every knob, or clears them all back to default when `self`
    /// is the default.
    public func store(in defaults: UserDefaults = .standard) {
        for knob in Self.knobs {
            if self[keyPath: knob.keyPath] == RingTuning()[keyPath: knob.keyPath] {
                defaults.removeObject(forKey: knob.key)
            } else {
                defaults.set(self[keyPath: knob.keyPath], forKey: knob.key)
            }
        }
        if centreBumper == RingTuning().centreBumper {
            defaults.removeObject(forKey: Self.centreBumperKey)
        } else {
            defaults.set(centreBumper, forKey: Self.centreBumperKey)
        }
        if twoBalls == RingTuning().twoBalls {
            defaults.removeObject(forKey: Self.twoBallsKey)
        } else {
            defaults.set(twoBalls, forKey: Self.twoBallsKey)
        }
        if goalGuards == RingTuning().goalGuards {
            defaults.removeObject(forKey: Self.goalGuardsKey)
        } else {
            defaults.set(goalGuards, forKey: Self.goalGuardsKey)
        }
        if guardsSlide == RingTuning().guardsSlide {
            defaults.removeObject(forKey: Self.guardsSlideKey)
        } else {
            defaults.set(guardsSlide, forKey: Self.guardsSlideKey)
        }
    }
}
