import Foundation
import simd

/// The RC circuit: a closed ribbon of tarmac laid inside the same box the
/// arena occupies, so the track fills the screen the court already fits.
///
/// The track is defined as a tube around a curve rather than as a pair of
/// walls. That is the whole trick: a ship is on the track when it is within
/// `halfWidth` of the centreline and off it when it is not, which makes the
/// railing exact everywhere -- through the chicane, round the hairpin, and at
/// the joins -- without ever intersecting two polylines against each other.
public struct TrackGeometry: Equatable, Sendable {
    /// One point per sample of the resampled centreline.
    public struct Sample: Equatable, Sendable {
        public var point: SIMD2<Double>
        /// Unit tangent, pointing the way the cars run.
        public var tangent: SIMD2<Double>
        /// Unit normal, ninety degrees left of the tangent.
        public var normal: SIMD2<Double>
        /// Distance from the start line to this sample, along the tarmac.
        public var arcLength: Double
    }

    /// The corners as laid out: a start straight along the bottom, a long
    /// right-hand sweeper, the top straight, and a tighter hairpin back onto
    /// the bottom. Everything else is interpolated.
    public let controlPoints: [SIMD2<Double>]
    /// Half the width of the tarmac. A ship is `shipRadius` narrower than
    /// this before it touches a rail.
    public let halfWidth: Double
    public let samples: [Sample]
    public let totalLength: Double

    /// How many samples each control segment is cut into. The centreline is
    /// tested every tick and the renderer walks the same samples, so the
    /// drawn rail cannot drift from the one that penalises you.
    public static let samplesPerSegment = 18

    public init(controlPoints: [SIMD2<Double>], halfWidth: Double) {
        precondition(controlPoints.count >= 4, "a closed spline needs four points")
        self.controlPoints = controlPoints
        self.halfWidth = halfWidth

        // Catmull-Rom through every control point, wrapped, so the loop closes
        // smoothly instead of putting a kink on the start line.
        var points: [SIMD2<Double>] = []
        let count = controlPoints.count
        for index in 0 ..< count {
            let p0 = controlPoints[(index - 1 + count) % count]
            let p1 = controlPoints[index]
            let p2 = controlPoints[(index + 1) % count]
            let p3 = controlPoints[(index + 2) % count]
            for step in 0 ..< Self.samplesPerSegment {
                let t = Double(step) / Double(Self.samplesPerSegment)
                let t2 = t * t
                let t3 = t2 * t
                let a: SIMD2<Double> = p1 * 2
                let b: SIMD2<Double> = (p2 - p0) * t
                let c: SIMD2<Double> = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d: SIMD2<Double> = (p1 * 3 - p2 * 3 + p3 - p0) * t3
                points.append((a + b + c + d) * 0.5)
            }
        }

        var samples: [Sample] = []
        samples.reserveCapacity(points.count)
        var running = 0.0
        for index in 0 ..< points.count {
            let previous = points[(index - 1 + points.count) % points.count]
            let next = points[(index + 1) % points.count]
            var tangent = next - previous
            let length = simd_length(tangent)
            tangent = length > 1e-9 ? tangent / length : SIMD2(1, 0)
            samples.append(Sample(
                point: points[index],
                tangent: tangent,
                normal: SIMD2(-tangent.y, tangent.x),
                arcLength: running
            ))
            running += simd_distance(points[index], next)
        }
        self.samples = samples
        totalLength = running
    }

    /// The loop, drawn once at unit scale, half a unit tall and 1.597 wide.
    ///
    /// This is the circuit Ian drew, read as a route: a ring round the
    /// outside, closed along the top, the right and the bottom, that breaks
    /// on the left and folds twice back into the middle, so a long loop sits
    /// nested inside the ring the way his does. One closed curve cannot be a
    /// ring *and* a separate infield -- the ring has to open somewhere for
    /// the infield to join it -- and the left is where he drew the join.
    ///
    /// Four horizontal lanes have to stack inside one arena height, which
    /// fixes the lane pitch at two thirds of the half-height and the tight
    /// turns at one third of it; spacing them evenly is what makes that
    /// smallest radius as large as it can be. The one sweep that is not
    /// tight is the right-hand end of the ring, which has the full height to
    /// turn in and takes it. Every corner is a clothoid-style multi-stage
    /// ease rather than a bare arc, because a straight running straight into
    /// an arc reads a fifth tighter than its nominal radius once
    /// Catmull-Rom has been through it, and that spike is what caps the
    /// corridor width.
    public static let loopControlPoints: [SIMD2<Double>] = [
        SIMD2(-0.3994, -1.0000), SIMD2(-0.3145, -1.0000), SIMD2(-0.2297, -1.0000),
        SIMD2(-0.1448, -1.0000), SIMD2(-0.0599, -1.0000), SIMD2(+0.0250, -1.0000),
        SIMD2(+0.1099, -1.0000), SIMD2(+0.1948, -1.0000), SIMD2(+0.2797, -1.0000),
        SIMD2(+0.3646, -0.9993), SIMD2(+0.4495, -0.9972), SIMD2(+0.5343, -0.9931),
        SIMD2(+0.6188, -0.9861), SIMD2(+0.7031, -0.9754), SIMD2(+0.7866, -0.9605),
        SIMD2(+0.8691, -0.9405), SIMD2(+0.9500, -0.9149), SIMD2(+1.0287, -0.8830),
        SIMD2(+1.1043, -0.8445), SIMD2(+1.1763, -0.7996), SIMD2(+1.2441, -0.7485),
        SIMD2(+1.3071, -0.6917), SIMD2(+1.3650, -0.6296), SIMD2(+1.4172, -0.5626),
        SIMD2(+1.4633, -0.4914), SIMD2(+1.5031, -0.4164), SIMD2(+1.5361, -0.3383),
        SIMD2(+1.5622, -0.2575), SIMD2(+1.5811, -0.1748), SIMD2(+1.5927, -0.0907),
        SIMD2(+1.5970, -0.0060), SIMD2(+1.5938, +0.0788), SIMD2(+1.5832, +0.1630),
        SIMD2(+1.5653, +0.2460), SIMD2(+1.5402, +0.3271), SIMD2(+1.5081, +0.4056),
        SIMD2(+1.4693, +0.4811), SIMD2(+1.4240, +0.5529), SIMD2(+1.3727, +0.6204),
        SIMD2(+1.3156, +0.6832), SIMD2(+1.2532, +0.7408), SIMD2(+1.1861, +0.7927),
        SIMD2(+1.1147, +0.8386), SIMD2(+1.0395, +0.8780), SIMD2(+0.9612, +0.9108),
        SIMD2(+0.8806, +0.9372), SIMD2(+0.7983, +0.9580), SIMD2(+0.7149, +0.9736),
        SIMD2(+0.6307, +0.9848), SIMD2(+0.5462, +0.9923), SIMD2(+0.4614, +0.9968),
        SIMD2(+0.3765, +0.9991), SIMD2(+0.2916, +0.9999), SIMD2(+0.2067, +1.0000),
        SIMD2(+0.1218, +1.0000), SIMD2(+0.0370, +1.0000), SIMD2(-0.0479, +1.0000),
        SIMD2(-0.1328, +1.0000), SIMD2(-0.2177, +1.0000), SIMD2(-0.3026, +1.0000),
        SIMD2(-0.3875, +1.0000), SIMD2(-0.4724, +1.0000), SIMD2(-0.5573, +1.0000),
        SIMD2(-0.6422, +1.0000), SIMD2(-0.7271, +1.0000), SIMD2(-0.8120, +1.0000),
        SIMD2(-0.8969, +1.0000), SIMD2(-0.9818, +1.0000), SIMD2(-1.0667, +1.0000),
        SIMD2(-1.1516, +1.0000), SIMD2(-1.2364, +0.9981), SIMD2(-1.3206, +0.9880),
        SIMD2(-1.4017, +0.9635), SIMD2(-1.4744, +0.9201), SIMD2(-1.5333, +0.8593),
        SIMD2(-1.5744, +0.7853), SIMD2(-1.5949, +0.7032), SIMD2(-1.5934, +0.6186),
        SIMD2(-1.5700, +0.5372), SIMD2(-1.5262, +0.4648), SIMD2(-1.4651, +0.4061),
        SIMD2(-1.3910, +0.3654), SIMD2(-1.3092, +0.3432), SIMD2(-1.2248, +0.3347),
        SIMD2(-1.1399, +0.3333), SIMD2(-1.0550, +0.3333), SIMD2(-0.9701, +0.3333),
        SIMD2(-0.8852, +0.3333), SIMD2(-0.8003, +0.3333), SIMD2(-0.7154, +0.3333),
        SIMD2(-0.6305, +0.3333), SIMD2(-0.5456, +0.3333), SIMD2(-0.4607, +0.3333),
        SIMD2(-0.3758, +0.3333), SIMD2(-0.2910, +0.3333), SIMD2(-0.2061, +0.3333),
        SIMD2(-0.1212, +0.3333), SIMD2(-0.0363, +0.3333), SIMD2(+0.0486, +0.3333),
        SIMD2(+0.1335, +0.3333), SIMD2(+0.2184, +0.3333), SIMD2(+0.3033, +0.3333),
        SIMD2(+0.3882, +0.3333), SIMD2(+0.4731, +0.3333), SIMD2(+0.5580, +0.3320),
        SIMD2(+0.6424, +0.3235), SIMD2(+0.7242, +0.3014), SIMD2(+0.7984, +0.2606),
        SIMD2(+0.8595, +0.2020), SIMD2(+0.9032, +0.1296), SIMD2(+0.9267, +0.0482),
        SIMD2(+0.9283, -0.0364), SIMD2(+0.9078, -0.1185), SIMD2(+0.8667, -0.1926),
        SIMD2(+0.8078, -0.2534), SIMD2(+0.7352, -0.2968), SIMD2(+0.6541, -0.3213),
        SIMD2(+0.5699, -0.3314), SIMD2(+0.4850, -0.3333), SIMD2(+0.4001, -0.3333),
        SIMD2(+0.3152, -0.3333), SIMD2(+0.2303, -0.3333), SIMD2(+0.1454, -0.3333),
        SIMD2(+0.0605, -0.3333), SIMD2(-0.0243, -0.3333), SIMD2(-0.1092, -0.3333),
        SIMD2(-0.1941, -0.3333), SIMD2(-0.2790, -0.3333), SIMD2(-0.3639, -0.3333),
        SIMD2(-0.4488, -0.3333), SIMD2(-0.5337, -0.3333), SIMD2(-0.6186, -0.3333),
        SIMD2(-0.7035, -0.3333), SIMD2(-0.7884, -0.3333), SIMD2(-0.8733, -0.3333),
        SIMD2(-0.9582, -0.3333), SIMD2(-1.0431, -0.3333), SIMD2(-1.1280, -0.3333),
        SIMD2(-1.2128, -0.3342), SIMD2(-1.2974, -0.3413), SIMD2(-1.3798, -0.3612),
        SIMD2(-1.4554, -0.3992), SIMD2(-1.5186, -0.4556), SIMD2(-1.5650, -0.5264),
        SIMD2(-1.5914, -0.6068), SIMD2(-1.5960, -0.6913), SIMD2(-1.5786, -0.7742),
        SIMD2(-1.5402, -0.8496), SIMD2(-1.4836, -0.9125), SIMD2(-1.4126, -0.9586),
        SIMD2(-1.3323, -0.9856), SIMD2(-1.2483, -0.9973), SIMD2(-1.1635, -1.0000),
        SIMD2(-1.0786, -1.0000), SIMD2(-0.9937, -1.0000), SIMD2(-0.9088, -1.0000),
        SIMD2(-0.8239, -1.0000), SIMD2(-0.7390, -1.0000), SIMD2(-0.6541, -1.0000),
        SIMD2(-0.5692, -1.0000), SIMD2(-0.4843, -1.0000)
    ]

    /// The half-extents of `loopControlPoints`, so the scale below follows the
    /// shape instead of a pair of numbers that go stale when it changes.
    private static let loopExtent: SIMD2<Double> = loopControlPoints.reduce(SIMD2(0, 0)) {
        SIMD2(max($0.x, abs($1.x)), max($0.y, abs($1.y)))
    }

    /// The corridor the pilot gets by default, and the widest this circuit
    /// will go. An intricate track and a wide lane are the same budget spent
    /// twice: four lanes stacked in one arena height leave a 0.150 turn, and
    /// the corner rule will not carry a corridor wider than this against it.
    /// A hull is 0.096 across, so the lane is 0.218 -- a shade over two
    /// hulls -- against four and a half on the oval this replaced.
    public static let defaultHalfWidth = 0.109
    /// Narrower than the minimum and a hull has less than its own width of
    /// daylight either side of it; wider than the maximum and the tight turns
    /// stop being wide enough to hold the corridor.
    public static let halfWidthLimits = (minimum: 0.098, maximum: 0.109)

    /// The circuit at a given corridor width. The loop shrinks as the tarmac
    /// widens, because both are pinned to the same arena box: the outer rail
    /// stays just inside the walls whatever width is asked for, and the
    /// centreline gives up the room the corridor takes. The scale is uniform
    /// -- squashing one axis would change every corner radius by a different
    /// amount, and the corners here are the whole point.
    public static func circuit(halfWidth: Double) -> TrackGeometry {
        let width = min(halfWidthLimits.maximum, max(halfWidthLimits.minimum, halfWidth))
        let scale = min(
            (0.628 - width) / loopExtent.y,
            (0.938 - width) / loopExtent.x
        )
        return TrackGeometry(
            controlPoints: loopControlPoints.map { $0 * scale },
            halfWidth: width
        )
    }

    /// The circuit as raced unless the pilot has moved the lane slider.
    public static let circuit = TrackGeometry.circuit(halfWidth: defaultHalfWidth)

    /// Where the ship is relative to the tarmac. `offset` is signed: positive
    /// is left of the direction of travel, so its sign says which rail.
    public struct Placement: Equatable, Sendable {
        public var closest: SIMD2<Double>
        public var tangent: SIMD2<Double>
        public var normal: SIMD2<Double>
        public var offset: Double
        /// How far round the lap, 0 at the start line and 1 back at it.
        public var progress: Double
    }

    public func placement(of position: SIMD2<Double>) -> Placement {
        var best = Placement(
            closest: samples[0].point,
            tangent: samples[0].tangent,
            normal: samples[0].normal,
            offset: 0,
            progress: 0
        )
        var bestDistanceSquared = Double.greatestFiniteMagnitude
        for index in 0 ..< samples.count {
            let start = samples[index]
            let end = samples[(index + 1) % samples.count]
            let edge = end.point - start.point
            let lengthSquared = simd_length_squared(edge)
            var t = 0.0
            if lengthSquared > 1e-12 {
                t = min(1, max(0, simd_dot(position - start.point, edge) / lengthSquared))
            }
            let closest = start.point + edge * t
            let distanceSquared = simd_length_squared(position - closest)
            guard distanceSquared < bestDistanceSquared else { continue }
            bestDistanceSquared = distanceSquared
            var tangent = simd_mix(start.tangent, end.tangent, SIMD2(repeating: t))
            let tangentLength = simd_length(tangent)
            tangent = tangentLength > 1e-9 ? tangent / tangentLength : start.tangent
            let normal = SIMD2(-tangent.y, tangent.x)
            let away = position - closest
            let arc = start.arcLength + simd_length(edge) * t
            best = Placement(
                closest: closest,
                tangent: tangent,
                normal: normal,
                offset: simd_dot(away, normal),
                progress: totalLength > 0 ? arc / totalLength : 0
            )
        }
        return best
    }

    /// The rail on the `sign` side, as a closed polyline. Left is +1.
    public func rail(sign: Double) -> [SIMD2<Double>] {
        samples.map { $0.point + $0.normal * (halfWidth * sign) }
    }

    /// The start/finish line: straight across the tarmac at sample zero.
    public var startLine: (SIMD2<Double>, SIMD2<Double>) {
        let sample = samples[0]
        return (
            sample.point + sample.normal * halfWidth,
            sample.point - sample.normal * halfWidth
        )
    }

    /// Where a ship sits on the grid. Staggered off the centreline so two of
    /// them do not start inside each other.
    public func gridPosition(row: Int, offset: Double) -> (SIMD2<Double>, Double) {
        // A little way back from the line, so the first crossing is a real one.
        let back = 0.06 + 0.075 * Double(row)
        let index = samples.count - Int((back / max(totalLength, 1e-6)) * Double(samples.count))
        let sample = samples[index % samples.count]
        let point = sample.point + sample.normal * offset
        return (point, atan2(sample.tangent.y, sample.tangent.x))
    }
}
