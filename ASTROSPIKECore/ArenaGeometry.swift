import Foundation
import simd

public struct BallState: Codable, Equatable, Sendable {
    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var radius: Double

    public init(
        position: SIMD2<Double>,
        velocity: SIMD2<Double> = .zero,
        radius: Double = 0.038
    ) {
        self.position = position
        self.velocity = velocity
        self.radius = radius
    }
}

public struct ArenaGeometry: Equatable, Sendable {
    public var halfWidth: Double
    public var floorY: Double
    public var ceilingY: Double
    /// Half-thickness of the net slab.
    public var netHalfWidth: Double
    public var netTopY: Double
    /// Corner arcs are deliberately elliptical, not quarter circles: wide and
    /// shallow, so a stray ball is nudged back toward the net rather than
    /// spun around a bowl. Nobody plays the corners, so the payoff is a less
    /// predictable rebound rather than a new place to camp.
    public var cornerRadiusX: Double
    public var cornerRadiusY: Double

    public init(
        halfWidth: Double = 0.96,
        floorY: Double = -0.64,
        ceilingY: Double = 0.64,
        netHalfWidth: Double = 0.018,
        netTopY: Double = -0.385,
        cornerRadiusX: Double = 0.30,
        cornerRadiusY: Double = 0.16
    ) {
        self.halfWidth = halfWidth
        self.floorY = floorY
        self.ceilingY = ceilingY
        self.netHalfWidth = netHalfWidth
        self.netTopY = netTopY
        self.cornerRadiusX = cornerRadiusX
        self.cornerRadiusY = cornerRadiusY
    }

    public static let standard = ArenaGeometry()

    public var opponentCrossingLimit: Double { halfWidth / 2 }

    /// The net *is* the goal, and it is a portal rather than a wall: a ball
    /// driven into either face passes through and is gone. Only the rounded
    /// cap on top still rebounds, so clipping the net is a miss, not a score.
    ///
    /// One slab, dead centre, standing on the floor. Its face is the target
    /// both sides shoot at -- from their own half, flat and low, because a
    /// ball dropped from above lands on the cap instead.
    public var portalFaceHeight: Double { netTopY - floorY }

    /// Where the flat floor and ceiling end and the corner arc begins.
    public var cornerTangentX: Double { halfWidth - cornerRadiusX }

    /// Pushes a body of `radius` out of whichever corner arc it has entered.
    /// The inset is approximated by shrinking the semi-axes, which is exact for
    /// a circle and close enough for an arc this flat.
    public func cornerContact(
        position: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let semiX = cornerRadiusX - radius
        let semiY = cornerRadiusY - radius
        guard semiX > 0, semiY > 0 else { return nil }

        let signX: Double = position.x < 0 ? -1 : 1
        let signY: Double = position.y < (floorY + ceilingY) / 2 ? -1 : 1
        let origin = SIMD2(
            signX * cornerTangentX,
            signY > 0 ? ceilingY - cornerRadiusY : floorY + cornerRadiusY
        )

        let delta = position - origin
        // Only the quadrant outside the arc's own centre is rounded; the rest
        // of the wall stays flat.
        guard delta.x * signX > 0, delta.y * signY > 0 else { return nil }

        let unit = SIMD2(delta.x / semiX, delta.y / semiY)
        let distance = simd_length(unit)
        guard distance > 1 else { return nil }

        let contact = origin + SIMD2(unit.x / distance * semiX, unit.y / distance * semiY)
        let offset = contact - origin
        var normal = SIMD2(-offset.x / (semiX * semiX), -offset.y / (semiY * semiY))
        let length = simd_length(normal)
        guard length > 0.000_001 else { return nil }
        normal /= length
        return (contact, normal)
    }

    /// Who scores, for a ball that has just gone through the portal. Whoever
    /// drove it in gets the point, so entry through the left face is a shot
    /// from the cyan half.
    public func portalScorer(enteredFromLeft: Bool) -> Team {
        enteredFromLeft ? .cyan : .orange
    }
}
