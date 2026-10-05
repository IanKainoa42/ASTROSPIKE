import Foundation
import simd

/// The free-for-all field: a round air-hockey table. Every pilot's goal is
/// a net set into the rim, mouth to the middle, at the back of its own
/// cove: a walled bay cut into a block that juts in off the rim. The cove's
/// walls flare a little toward the middle, so a goal goes in straight down
/// the cove or off one of its walls. Between neighbouring coves a fin rises
/// off the rim, its flanks curving up from the floor like the duel's
/// corners, so a ball running round the rim is turned back into the middle.
///
/// Each net is drawn and collided in its own frame: x across the mouth, y
/// pointing in from the back of the net (against the rim), through the
/// mouth, toward the middle. Nets, coves and fins are all `ArenaObstacle`
/// capsules. The ball meets a live net's frame and goes in only through the
/// mouth; a hull meets every net shut, so nobody parks behind a goal line,
/// but flies into a cove to keep it.
public struct RingField: Equatable, Sendable {
    /// Centre to rim. The field is the size the old hub-and-spoke ring was,
    /// so nothing on screen shrank; the hub's room is now open play.
    public static let rimRadius = 1.52
    /// How far each cove runs in from the mouth to its entrance. The Cove
    /// depth setting.
    public var coveDepth: Double
    /// How far each cove wall leans out from straight, in radians: a wider
    /// entrance than mouth. The Cove flare setting.
    public var coveFlare: Double
    /// Each pilot's MAX CROSS line, as a share of the distance out to the
    /// cove entrances: the arc across each rival's ground past which the
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
    /// Every cove's two walls (mouth to entrance) and the block's two outer
    /// faces (entrance back out to the rim). Solid to everything.
    public var coves: [ArenaObstacle]
    public var fins: [ArenaObstacle]

    public init(pilots: Int, ballRadius: Double, tuning: RingTuning = RingTuning()) {
        let count = max(2, pilots)
        self.ballRadius = ballRadius
        coveDepth = tuning.coveDepth
        coveFlare = tuning.coveFlare * .pi / 180
        maxCrossShare = tuning.lineShare
        rimRadius = Self.rimRadius
        spokeAngles = (0 ..< count).map { -.pi / 2 + Double($0) * 2 * .pi / Double(count) }
        netHalfWidth = ballRadius + 0.10 + Self.netWall
        netDepth = 2 * ballRadius + 0.07 + Self.netWall
        posts = []
        backs = []
        coves = []
        fins = []
        for index in spokeAngles.indices {
            let outline = Self.segments(netOutline.map { toWorld($0, net: index) }, radius: Self.netWall)
            posts += [outline[0], outline[outline.count - 1]]
            backs.append(Array(outline[1 ..< outline.count - 1]))
            for side in [-1.0, 1.0] {
                let block = coveBlock(side: side).map { toWorld($0, net: index) }
                coves += Self.segments([block[0], block[1]], radius: Self.netWall)
                coves += Self.segments([block[block.count - 1], block[0]], radius: Self.netWall)
            }
        }
        for index in spokeAngles.indices { fins += fin(at: spokeAngles[index] + .pi / Double(count)) }
    }

    /// What the ball meets: the fins, the coves, every net's frame, and a
    /// bar across the mouth of every net in `solid` (a knocked-out pilot's).
    public func ballWalls(solid: (Int) -> Bool) -> [ArenaObstacle] {
        fins + coves + posts + backs.flatMap { $0 } + spokeAngles.indices.filter(solid).map(mouthBar)
    }

    /// Every net in `solid`, shut all round: frame and mouth. A hull meets
    /// every net this way, live or not, as well as the coves and fins.
    public func closedNets(_ solid: (Int) -> Bool) -> [ArenaObstacle] {
        spokeAngles.indices.filter(solid).flatMap { index in
            [posts[2 * index], posts[2 * index + 1], mouthBar(index)] + backs[index]
        }
    }

    // MARK: - Frames

    /// Straight out from the centre at `bearing`.
    static func outward(_ bearing: Double) -> SIMD2<Double> { SIMD2(cos(bearing), sin(bearing)) }

    /// Distance from the centre to the back of every net's frame, against
    /// the rim: the frame's outer edge just touches it, so nothing gets
    /// behind a net.
    public var netBackRadius: Double { rimRadius - 2 * Self.netWall }

    /// Distance from the centre to every net's mouth.
    public var mouthRadius: Double { netBackRadius - netDepth }

    /// Distance from the centre to every cove's entrance, the open end
    /// toward the middle.
    public var coveEntranceRadius: Double { mouthRadius - coveDepth }

    /// Half the cove's width at its entrance, out to the middle of each wall.
    public var coveEntranceHalfWidth: Double { netHalfWidth + coveDepth * tan(coveFlare) }

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

    /// One side's block, in the net's frame: the cove entrance, the mouth
    /// post, the back of the post at the rim, then round the rim to where
    /// the block's outer face comes back in to the entrance. `side` is +1
    /// or -1 across the mouth. The outer face leaves the rim a little wider
    /// than the entrance, so it stands near square to the rim and turns a
    /// ball running along the rim back in, like a fin.
    public func coveBlock(side: Double) -> [SIMD2<Double>] {
        let entrance = SIMD2(side * coveEntranceHalfWidth, netDepth + coveDepth)
        let post = SIMD2(side * netHalfWidth, netDepth)
        let base = SIMD2(side * netHalfWidth, 0.0)
        // The rim, in this frame: the circle about (0, netBackRadius).
        func onRim(x: Double) -> SIMD2<Double> {
            SIMD2(x, netBackRadius - (rimRadius * rimRadius - x * x).squareRoot())
        }
        let outer = side * (coveEntranceHalfWidth + Self.coveShoulder)
        let steps = 6
        let rim = (0 ... steps).map { step in
            onRim(x: side * netHalfWidth + (outer - side * netHalfWidth) * Double(step) / Double(steps))
        }
        return [entrance, post, base] + rim
    }

    /// How much wider than the cove's entrance the block meets the rim.
    public static let coveShoulder = 0.04

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

    /// Every pilot's ground is the wedge of the ring round their net, fin to
    /// fin. The middle inside this radius is everyone's; past it a pilot
    /// may fly only on their own ground or a knocked-out pilot's.
    public var maxCrossRadius: Double { coveEntranceRadius * maxCrossShare }

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
    /// cove entrances.
    public var lineShare = 0.6
    /// How far each cove runs in from its mouth.
    public var coveDepth = 0.30
    /// How far each cove wall leans out from straight, in degrees.
    public var coveFlare = 15.0

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
            Knob(key: "ring.coveDepth", title: "Cove depth", range: 0 ... 0.4, step: 0.01, percent: false, keyPath: \.coveDepth),
            Knob(key: "ring.coveFlare", title: "Cove flare", range: 0 ... 20, step: 1, percent: false, keyPath: \.coveFlare, degrees: true),
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
