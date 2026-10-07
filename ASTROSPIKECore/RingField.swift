import Foundation
import simd

/// The free-for-all field: a round air-hockey table. Every pilot's goal is
/// a slot cut flush in the rim, mouth on the circle and pocket behind it,
/// outside the play. Between each pair of goals a corner barrier fills the
/// rim: a flat face with rounded ends that meet the rim tangent, like the
/// corners of an air-hockey table, so a ball running the wall rides up the
/// end and is turned back in. An optional bumper can stand in the middle.
///
/// Each net is drawn and collided in its own frame: x across the mouth, y
/// pointing in from the back of the pocket (outside the rim), through the
/// mouth, toward the middle. Nets and corner barriers are `ArenaObstacle`
/// capsules. The ball meets a live net's frame and goes in only through the
/// mouth; the rim itself opens there. A hull meets every net shut, so
/// nobody parks behind a goal line.
public struct RingField: Equatable, Sendable {
    /// Centre to rim. The field is the size the old hub-and-spoke ring was,
    /// so nothing on screen shrank; the hub's room is now open play.
    public static let rimRadius = 1.52
    /// Each pilot's MAX CROSS line, as a share of the distance out to the
    /// mouths: the arc across each rival's ground past which the rival
    /// shoves a pilot back, as the duel's line does half way into the far
    /// half. The MAX CROSS line setting.
    public var maxCrossShare: Double
    /// Whether the round bumper in the middle is standing.
    public var centreBumper: Bool
    /// Thickness of a net's frame, as a capsule radius.
    public static let netWall = 0.014
    /// Radius of the round bumper in the middle.
    public static let centreBumperRadius = 0.09
    /// Radius of the rounded ends of each corner barrier, where its face
    /// turns down to meet the rim.
    public static let cornerFillet = 0.20
    /// How far each corner barrier's flat face stands in off the rim, after
    /// the Corners setting is held clear of the posts.
    public var cornerDepth: Double

    public var rimRadius: Double
    /// The way each net sits, out from the centre. Net 0 is at the bottom of
    /// the screen, like the duel's floor.
    public var spokeAngles: [Double]
    public var ballRadius: Double

    /// Half the net's mouth, out to the middle of each post: the ball plus a
    /// tenth of the field either side, so a bigger ball keeps the same room.
    public var netHalfWidth: Double
    /// Back of the net to the mouth, along the frame's centreline.
    public var netDepth: Double
    /// Each net's two sides, mouth to the rounded corners of the pocket.
    public var posts: [ArenaObstacle]
    /// Each net's back, post to post round the rounded corners.
    public var backs: [[ArenaObstacle]]
    /// Every corner barrier's face, rim to rim, one between each pair of
    /// goals. Empty when the Corners setting is zero: a plain round rim.
    public var corners: [ArenaObstacle]
    /// The centre bumper, when it is standing. Empty when the toggle is off.
    public var centre: [ArenaObstacle]

    public init(pilots: Int, ballRadius: Double, tuning: RingTuning = RingTuning()) {
        let count = max(2, pilots)
        self.ballRadius = ballRadius
        maxCrossShare = tuning.lineShare
        centreBumper = tuning.centreBumper
        rimRadius = Self.rimRadius
        spokeAngles = (0 ..< count).map { -.pi / 2 + Double($0) * 2 * .pi / Double(count) }
        netHalfWidth = ballRadius + 0.10 + Self.netWall
        netDepth = 2 * ballRadius + 0.07 + Self.netWall
        posts = []
        backs = []
        corners = []
        centre = []
        cornerDepth = 0
        cornerDepth = min(max(0, tuning.cornerDepth), maxCornerDepth)
        for index in spokeAngles.indices {
            let outline = Self.segments(netOutline.map { toWorld($0, net: index) }, radius: Self.netWall)
            posts += [outline[0], outline[outline.count - 1]]
            backs.append(Array(outline[1 ..< outline.count - 1]))
        }
        if cornerDepth > 0.005 {
            for index in spokeAngles.indices {
                corners += Self.segments(cornerFace(index), radius: Self.netWall)
            }
        }
        if centreBumper {
            centre = [.peg(.zero, radius: Self.centreBumperRadius)]
        }
    }

    /// What the ball meets: the corner barriers, the centre bumper, every
    /// net's frame, and a bar across the mouth of every net in `solid` (a
    /// knocked-out pilot's).
    public func ballWalls(solid: (Int) -> Bool) -> [ArenaObstacle] {
        corners + centre + posts + backs.flatMap { $0 } + spokeAngles.indices.filter(solid).map(mouthBar)
    }

    /// Every net in `solid`, shut all round: frame and mouth. A hull meets
    /// every net this way, live or not, as well as the corner barriers.
    public func closedNets(_ solid: (Int) -> Bool) -> [ArenaObstacle] {
        spokeAngles.indices.filter(solid).flatMap { index in
            [posts[2 * index], posts[2 * index + 1], mouthBar(index)] + backs[index]
        }
    }

    // MARK: - Frames

    /// Straight out from the centre at `bearing`.
    static func outward(_ bearing: Double) -> SIMD2<Double> { SIMD2(cos(bearing), sin(bearing)) }

    /// Distance from the centre to the back of every net's frame. The pocket
    /// hangs outside the rim, so the back is past it.
    public var netBackRadius: Double { mouthRadius + netDepth }

    /// Distance from the centre to the middle of every mouth. The mouth's
    /// ends sit on the rim; the middle of the chord is a hair inside, so
    /// the slot reads flush with the wall.
    public var mouthRadius: Double {
        (rimRadius * rimRadius - netHalfWidth * netHalfWidth).squareRoot()
    }

    /// How far round the rim each post stands, out to the middle of the post.
    public var postHalfAngle: Double { asin(min(0.95, netHalfWidth / rimRadius)) }

    /// How far round the rim the ball's centre may pass: inside the posts,
    /// so the opening in the wall is the slot and not the wood beside it.
    public var mouthHalfAngle: Double { asin(min(0.95, netInnerHalfWidth / rimRadius)) }

    /// True when `point` lies in an open goal's slot, the wedge the rim
    /// gives up so the ball can leave the circle into the pocket.
    public func admitsThroughRim(_ point: SIMD2<Double>, open: (Int) -> Bool) -> Bool {
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

    /// How far round from its corner each barrier reaches along the rim, to
    /// where its rounded end meets the rim tangent.
    public var cornerHalfAngle: Double {
        let r = Self.cornerFillet
        return acos(min(1, (rimRadius - cornerDepth - r) / (rimRadius - r)))
    }

    /// The deepest the Corners setting may stand a barrier: its rounded end
    /// stays a little round the rim from the post, so the slot is never
    /// crowded and the wall either side of a goal is plain rim.
    public var maxCornerDepth: Double {
        let r = Self.cornerFillet
        let reach = max(0, Double.pi / Double(spokeAngles.count) - postHalfAngle - cornerPostClearance)
        return rimRadius - r - (rimRadius - r) * cos(reach)
    }

    /// The least rim, in radians, between a barrier's end and a post: room
    /// for the ball to roll down the wall into the mouth, at any ball size.
    public var cornerPostClearance: Double {
        max(0.08, (2 * ballRadius + 2 * Self.netWall + 0.02) / rimRadius)
    }

    /// The face of the corner barrier after net `index` (anticlockwise), rim
    /// to rim: a rounded end tangent to the rim, the flat face square to the
    /// corner's bearing `cornerDepth` in off the rim, and the other rounded
    /// end back down. Each end is an arc whose centre is inside the field, so
    /// the field's edge is convex all round and nothing pinches the ball.
    public func cornerFace(_ index: Int) -> [SIMD2<Double>] {
        let bearing = gapBearings[index]
        let r = Self.cornerFillet
        let reach = cornerHalfAngle
        let steps = 8
        var points: [SIMD2<Double>] = []
        for side in [1.0, -1.0] {
            let centre = Self.outward(bearing + side * reach) * (rimRadius - r)
            for step in 0 ... steps {
                // Anticlockwise end: from the rim down to the face; the other
                // end from the face back down to the rim.
                let share = Double(step) / Double(steps)
                let angle = side > 0 ? bearing + reach * (1 - share) : bearing - reach * share
                points.append(centre + Self.outward(angle) * r)
            }
        }
        return points
    }

    /// Where a pilot starts: just inside the rim, beside their own mouth,
    /// nose to the middle. Clear of the corner barrier, so an idle hull is
    /// not a keeper parked in its own goal.
    public func spawnPoint(bay: Int) -> SIMD2<Double> {
        toWorld(SIMD2(netHalfWidth + 0.18, netDepth + 0.28), net: bay)
    }

    /// The bearings of the corners, midway between neighbouring mouths,
    /// where the barriers stand. The face-off drifts out toward one of these.
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
    /// The motor's push on the ring, as a share of the Thrust slider.
    public var speed = 0.45
    /// Velocity bled off a ring hull each second. Held thrust builds speed
    /// along 1 - e^(-drag t) toward thrust / drag, and a hull let go glides
    /// to a stop on it.
    public var hullDrag = 0.45
    /// Velocity bled off the ball each second: a puck on air.
    public var ballDrag = 0.15
    /// The share of the duel's gravity felt at the rim. Ring gravity is spin
    /// gravity: nothing at the centre, growing straight out to this.
    public var gravity = 0.0
    /// How hard a rival past a MAX CROSS line is shoved back, per unit of
    /// depth. The duel's is 18.
    public var linePush = 10.0
    /// How much speed the line steals from a rival past it. The duel's is 5.
    public var lineBrake = 2.5
    /// Where each MAX CROSS arc stands, as a share of the way out to the
    /// mouths.
    public var lineShare = 0.6
    /// The round bumper in the middle. Off leaves the face-off clear.
    public var centreBumper = false
    /// How far each corner barrier's flat face stands in off the rim. Zero
    /// is a plain round rim. Held clear of the posts whatever the setting.
    public var cornerDepth = 0.10

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
        public var id: String { key }
    }

    /// The defaults key for the centre bumper. Not a slider.
    public static let centreBumperKey = "ring.centreBumper"

    /// Every knob, in the order the sliders stand. Ring gravity keeps the key
    /// it had when it was the only one, so a stored setting carries over.
    public static var knobs: [Knob] {
        [
            Knob(key: "ring.speed", title: "Thrust", range: 0.1 ... 1.2, step: 0.05, percent: true, keyPath: \.speed),
            Knob(key: "ring.hullDrag", title: "Hull drag", range: 0.05 ... 1.5, step: 0.05, percent: false, keyPath: \.hullDrag),
            Knob(key: "ring.ballDrag", title: "Ball drag", range: 0 ... 0.8, step: 0.01, percent: false, keyPath: \.ballDrag),
            Knob(key: "ringGravity", title: "Ring gravity", range: 0 ... 1.5, step: 0.05, percent: true, keyPath: \.gravity),
            Knob(key: "ring.linePush", title: "MAX CROSS push", range: 0 ... 30, step: 0.5, percent: false, keyPath: \.linePush),
            Knob(key: "ring.lineBrake", title: "MAX CROSS brake", range: 0 ... 8, step: 0.1, percent: false, keyPath: \.lineBrake),
            Knob(key: "ring.lineShare", title: "MAX CROSS line", range: 0.3 ... 1.0, step: 0.02, percent: true, keyPath: \.lineShare),
            Knob(key: "ring.cornerDepth", title: "Corners", range: 0 ... 0.24, step: 0.01, percent: false, keyPath: \.cornerDepth),
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
        tuning.centreBumper = defaults.object(forKey: centreBumperKey) as? Bool ?? false
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
    }
}
