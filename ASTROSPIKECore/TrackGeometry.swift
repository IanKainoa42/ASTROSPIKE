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

    /// The loop, drawn once at unit scale. Everything the circuit does with
    /// width is done by scaling these: the shape is a smooth continuous oval
    /// with no straight-to-arc joins in it, which is what keeps the tightest
    /// measured corner near its nominal radius instead of spiking at a
    /// junction. A stadium built from two straights and two caps reads a
    /// third tighter at the joins and fails the corner rule at any useful
    /// width -- this was measured, not assumed.
    public static let loopControlPoints: [SIMD2<Double>] = [
        SIMD2(0.072, -0.413),
        SIMD2(0.266, -0.420),
        SIMD2(0.387, -0.406),
        SIMD2(0.499, -0.358),
        SIMD2(0.593, -0.280),
        SIMD2(0.660, -0.178),
        SIMD2(0.696, -0.061),
        SIMD2(0.696, 0.061),
        SIMD2(0.660, 0.178),
        SIMD2(0.593, 0.280),
        SIMD2(0.499, 0.358),
        SIMD2(0.387, 0.406),
        SIMD2(0.266, 0.420),
        SIMD2(0.072, 0.413),
        SIMD2(-0.121, 0.406),
        SIMD2(-0.314, 0.400),
        SIMD2(-0.423, 0.380),
        SIMD2(-0.524, 0.332),
        SIMD2(-0.606, 0.257),
        SIMD2(-0.665, 0.163),
        SIMD2(-0.696, 0.056),
        SIMD2(-0.696, -0.056),
        SIMD2(-0.665, -0.163),
        SIMD2(-0.606, -0.257),
        SIMD2(-0.524, -0.332),
        SIMD2(-0.423, -0.380),
        SIMD2(-0.314, -0.400),
        SIMD2(-0.121, -0.406),
    ]

    /// The corridor the pilot gets by default. Wide enough to carry a slide
    /// through a corner and still have road on the far side of it: a hull is
    /// 0.096 across, so this is four and a half hulls of daylight, against
    /// three before.
    public static let defaultHalfWidth = 0.26
    /// Narrower than this and the loop grows past the arena walls; wider and
    /// the tightest corner stops being wide enough to hold the corridor.
    public static let halfWidthLimits = (minimum: 0.17, maximum: 0.26)

    /// The circuit at a given corridor width. The loop shrinks as the tarmac
    /// widens, because both are pinned to the same arena box: the outer rail
    /// stays just inside the walls whatever width is asked for, and the
    /// centreline gives up the room the corridor takes.
    public static func circuit(halfWidth: Double) -> TrackGeometry {
        let width = min(halfWidthLimits.maximum, max(halfWidthLimits.minimum, halfWidth))
        // The loop's own extents are 0.696 by 0.420. Height is the binding
        // wall -- the arena is half again as wide as it is tall -- so the
        // vertical scale is set by it and the horizontal follows, capped so
        // the ends never reach a side wall either.
        let vertical = (0.628 - width) / 0.420
        let horizontal = min(vertical * 1.023, (0.938 - width) / 0.696)
        return TrackGeometry(
            controlPoints: loopControlPoints.map { SIMD2($0.x * horizontal, $0.y * vertical) },
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
