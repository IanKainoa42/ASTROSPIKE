import Foundation
import simd

/// The free-for-all field: a round air-hockey table. Every pilot's goal is
/// a net standing in from the rim with its mouth turned out to face it, so
/// a goal has to be banked in: off the rim and back into the mouth. A live
/// net is only netting -- the ball flows straight through its back and
/// sides, so a shot from the middle runs through the net, off the rim and
/// back in. Between neighbouring nets a fin rises off the rim, its flanks
/// curving up from the floor like the duel's corners, so a ball running
/// round the rim is turned back into the middle.
///
/// Each net is drawn and collided in its own frame: x across the mouth, y
/// pointing out from the back of the net, through the mouth, toward the
/// rim. The nets and fins are all `ArenaObstacle` capsules. Hulls, bolts
/// and the ball pass through a live net and meet only the fins; a
/// knocked-out pilot's net is shut all round to all of them.
public struct RingField: Equatable, Sendable {
    /// Centre to rim. The field is the size the old hub-and-spoke ring was,
    /// so nothing on screen shrank; the hub's room is now open play.
    public static let rimRadius = 1.52
    /// Room between every mouth and the rim, past the ball's width: the
    /// lane a banked shot comes back through. The net is hung from there
    /// inward, so a bigger ball's deeper net reaches further in. The Net to
    /// rim setting.
    public var rimClearance: Double
    /// Each pilot's MAX CROSS line, as a share of the distance out to the
    /// backs of the nets: the arc across each rival's ground past which the
    /// rival shoves a pilot back, as the duel's line does half way into the
    /// far half. The MAX CROSS line setting.
    public var maxCrossShare: Double
    /// Thickness of a net's frame, as a capsule radius.
    public static let netWall = 0.014
    /// Thickness of a fin's flank.
    public static let finWall = 0.014
    /// Half the angle of rim a fin stands on, and how far its tip reaches
    /// in. The flanks are arcs tangent to the rim, so the climb starts flat.
    public static let finHalfAngle = 0.30
    public static let finHeight = 0.36

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
    /// Each net's two sides, mouth to the rounded corners.
    public var posts: [ArenaObstacle]
    /// Each net's back, post to post round the rounded corners.
    public var backs: [[ArenaObstacle]]
    public var fins: [ArenaObstacle]

    public init(pilots: Int, ballRadius: Double, tuning: RingTuning = RingTuning()) {
        let count = max(2, pilots)
        self.ballRadius = ballRadius
        rimClearance = tuning.rimRoom
        maxCrossShare = tuning.lineShare
        rimRadius = Self.rimRadius
        spokeAngles = (0 ..< count).map { -.pi / 2 + Double($0) * 2 * .pi / Double(count) }
        netHalfWidth = ballRadius + 0.10 + Self.netWall
        netDepth = 2 * ballRadius + 0.07 + Self.netWall
        posts = []
        backs = []
        fins = []
        for index in spokeAngles.indices {
            let outline = Self.segments(netOutline.map { toWorld($0, net: index) }, radius: Self.netWall)
            posts += [outline[0], outline[outline.count - 1]]
            backs.append(Array(outline[1 ..< outline.count - 1]))
        }
        for index in spokeAngles.indices { fins += fin(at: spokeAngles[index] + .pi / Double(count)) }
    }

    /// What the ball meets: the fins and every net in `solid` (a knocked-out
    /// pilot's net is shut all round). A live net it flows straight through.
    public func ballWalls(solid: (Int) -> Bool) -> [ArenaObstacle] {
        fins + closedNets(solid)
    }

    /// Every net in `solid`, shut all round: frame and mouth. A hull meets
    /// these as well as the fins; a live net it flies straight through.
    public func closedNets(_ solid: (Int) -> Bool) -> [ArenaObstacle] {
        spokeAngles.indices.filter(solid).flatMap { index in
            [posts[2 * index], posts[2 * index + 1], mouthBar(index)] + backs[index]
        }
    }

    // MARK: - Frames

    /// Straight out from the centre at `bearing`.
    static func outward(_ bearing: Double) -> SIMD2<Double> { SIMD2(cos(bearing), sin(bearing)) }

    /// The lane between every mouth and the rim: a ball and some.
    public var rimGap: Double { 2 * ballRadius + rimClearance }

    /// Distance from the centre to every net's mouth.
    public var mouthRadius: Double { rimRadius - rimGap }

    /// Distance from the centre to the back of every net's frame, its side
    /// toward the middle.
    public var netBackRadius: Double { mouthRadius - netDepth }

    /// Net `index`'s frame point `local` in the world.
    public func toWorld(_ local: SIMD2<Double>, net index: Int) -> SIMD2<Double> {
        let out = Self.outward(spokeAngles[index])
        let across = SIMD2(-out.y, out.x)
        return out * (netBackRadius + local.y) + across * local.x
    }

    /// A world point in net `index`'s frame.
    public func toLocal(_ point: SIMD2<Double>, net index: Int) -> SIMD2<Double> {
        let out = Self.outward(spokeAngles[index])
        let across = SIMD2(-out.y, out.x)
        return SIMD2(simd_dot(point, across), simd_dot(point, out) - netBackRadius)
    }

    /// Where the ball's centre meets the rim straight out along net
    /// `index`'s centre line, in that net's frame: the bank behind it.
    public var rimLineY: Double { rimRadius - ballRadius - netBackRadius }

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
    /// the ball.
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
    /// from the mouth -- back toward the middle, off the rim. A ball running
    /// out through the net from the middle crosses the line going the other
    /// way and does not count.
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

    /// Every pilot's ground is the wedge of the ring round their net, fin to
    /// fin. The middle inside this radius is everyone's; past it a pilot
    /// may fly only on their own ground or a knocked-out pilot's.
    public var maxCrossRadius: Double { netBackRadius * maxCrossShare }

    /// Whose ground `point` is on: the net it shares a wedge with.
    public func ground(at point: SIMD2<Double>) -> Int { spokeIndex(nearest: point) }

    /// The bearings of net `index`'s two borders, the fins either side.
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

    // MARK: - Fins

    /// One flank of the fin at `bearing`, rim to tip: an arc tangent to the
    /// rim where it starts, curving up to meet the other flank at the tip.
    /// `side` is +1 for the flank anticlockwise of the fin's centre line.
    public func finFlank(at bearing: Double, side: Double) -> [SIMD2<Double>] {
        let alpha = Self.finHalfAngle
        let r = rimRadius
        // The arc's radius is solved so its tip lands at `finHeight`: the
        // circle is tangent to the rim at the base, so its centre sits on the
        // base radius, `rho` in from the rim.
        func tipDistance(_ rho: Double) -> Double {
            let offset = (r - rho) * sin(alpha)
            return (r - rho) * cos(alpha) + max(0, rho * rho - offset * offset).squareRoot()
        }
        var low = r * sin(alpha) / (1 + sin(alpha)) + 1e-9
        var high = r
        for _ in 0 ..< 60 {
            let mid = (low + high) / 2
            if tipDistance(mid) > r - Self.finHeight { high = mid } else { low = mid }
        }
        let rho = (low + high) / 2
        let centre = SIMD2(cos(alpha), sin(alpha)) * (r - rho)
        let tip = SIMD2(tipDistance(rho), 0.0)
        let startAngle = alpha
        let endAngle = atan2(tip.y - centre.y, tip.x - centre.x)
        let steps = 10
        let turn = SIMD2(cos(bearing), sin(bearing))
        return (0 ... steps).map { step in
            var sweep = endAngle - startAngle
            sweep = remainder(sweep, 2 * .pi)
            let angle = startAngle + sweep * Double(step) / Double(steps)
            var p = centre + SIMD2(cos(angle), sin(angle)) * rho
            p.y *= side
            return SIMD2(p.x * turn.x - p.y * turn.y, p.x * turn.y + p.y * turn.x)
        }
    }

    private func fin(at bearing: Double) -> [ArenaObstacle] {
        [1.0, -1.0].flatMap { Self.segments(finFlank(at: bearing, side: $0), radius: Self.finWall) }
    }

    /// Where the fins stand, between each pair of nets.
    public var finBearings: [Double] {
        spokeAngles.map { $0 + .pi / Double(spokeAngles.count) }
    }
}

/// Every free-for-all knob a pilot can turn: how the ring flies, how hard
/// each pilot's MAX CROSS line holds, and where the nets and lines stand.
/// A pilot's preferences, set in Settings or on the pause card mid-match;
/// the ring is offline only, so none of it rides the wire.
public struct RingTuning: Equatable, Sendable {
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
    /// backs of the nets.
    public var lineShare = 0.6
    /// Room between every mouth and the rim past the ball's width: the lane
    /// a banked shot comes back through.
    public var rimRoom = 0.40

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
        public var id: String { key }
    }

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
            Knob(key: "ring.rimRoom", title: "Net to rim", range: 0.1 ... 0.6, step: 0.01, percent: false, keyPath: \.rimRoom),
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
    }
}
