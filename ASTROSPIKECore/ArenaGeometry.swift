import Foundation
import simd

public struct BallState: Codable, Equatable, Sendable {
    /// The radius every ball is created with. The arena is dimensioned against
    /// it -- the portal sill in particular -- so it belongs here rather than
    /// buried as a literal in the initialiser.
    public static let nominalRadius = 0.038

    public var position: SIMD2<Double>
    public var velocity: SIMD2<Double>
    public var radius: Double

    public init(
        position: SIMD2<Double>,
        velocity: SIMD2<Double> = .zero,
        radius: Double = BallState.nominalRadius
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
    ///
    /// The same arc is mirrored into the middle as the hill the net stands on,
    /// so tuning one tunes both.
    public var cornerRadiusX: Double
    public var cornerRadiusY: Double

    public init(
        halfWidth: Double = 0.96,
        floorY: Double = -0.64,
        ceilingY: Double = 0.64,
        netHalfWidth: Double = 0.018,
        // Sits one portal-mouth above the crest of the hill (see
        // `portalMouthFloorY`), which is what keeps the goal the same size it
        // has always been now that the bottom of the net is buried.
        netTopY: Double = -0.184,
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

    /// Where the flat floor and ceiling end and the corner arc begins.
    public var cornerTangentX: Double { halfWidth - cornerRadiusX }

    // MARK: - The hill under the net

    /// The corner fillet, mirrored inward with the net face standing in for the
    /// side wall: horizontal where it meets the floor, vertical where it meets
    /// the post. A ball driven along the floor into the middle therefore ramps
    /// and pops up instead of rolling into the goal.
    public var moundBaseX: Double { netHalfWidth + cornerRadiusX }

    /// Top of the hill, flat across the width of the post.
    public var moundCrestY: Double { floorY + cornerRadiusY }

    /// The face is a portal only above this line. Below it the slab is a solid
    /// post standing on the crest, because the crest is tangent to the face --
    /// without the band, a ball riding up the last of the slope would be
    /// touching the portal at the exact instant it is touching the hill.
    /// One ball diameter of sill, so anything that scores is clear of the hill.
    public var portalMouthFloorY: Double { moundCrestY + BallState.nominalRadius * 2 }

    /// The net *is* the goal, and it is a portal rather than a wall: a ball
    /// driven into the open part of either face passes through and is gone.
    /// The rounded cap on top still rebounds, so clipping the net is a miss.
    ///
    /// One slab, dead centre, standing on the hill. Its mouth is the target
    /// both sides shoot at -- from their own half, flat and low, because a
    /// ball dropped from above lands on the cap instead.
    public var portalFaceHeight: Double { netTopY - portalMouthFloorY }

    /// How many segments the quarter arc is cut into.
    public static let moundArcSegments = 16

    /// Evenly spaced (sin, cos) from the face (theta = pi/2) down to the floor
    /// (theta = 0). A table rather than live trig: the hill is tested several
    /// times per body per tick, and the renderer walks the same samples, so the
    /// drawn slope cannot drift from the one balls bounce off.
    private static let arcUnit: [SIMD2<Double>] = (0 ... moundArcSegments).map { step in
        let theta = Double(moundArcSegments - step) / Double(moundArcSegments) * (.pi / 2)
        return SIMD2(sin(theta), cos(theta))
    }

    public var moundSampleCount: Int { Self.arcUnit.count }

    /// Sample `index` of the right-hand slope, running crest to base.
    public func moundSurfacePoint(_ index: Int) -> SIMD2<Double> {
        let unit = Self.arcUnit[index]
        return SIMD2(moundBaseX - cornerRadiusX * unit.x, moundCrestY - cornerRadiusY * unit.y)
    }

    /// The right-hand profile including the flat crest, for drawing.
    public var moundProfile: [SIMD2<Double>] {
        [SIMD2(0, moundCrestY)] + (0 ..< moundSampleCount).map(moundSurfacePoint)
    }

    /// Pushes a body of `radius` off the hill. Tested against the sampled
    /// polyline rather than the ellipse itself: the shrink-the-semi-axes trick
    /// the corners use is only valid from the inside of a curve. Grown by a
    /// ball radius, this arc would first touch a floor-rolling ball at x = 0.05
    /// -- a wall in the middle of the court, not a ramp.
    public func moundContact(
        position: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let mirrored = SIMD2(abs(position.x), position.y)
        guard mirrored.x <= moundBaseX + radius, mirrored.y <= moundCrestY + radius else {
            return nil
        }

        var closest = SIMD2(0.0, moundCrestY)
        var closestNormal = SIMD2(0.0, 1.0)
        var closestDistanceSquared = Double.greatestFiniteMagnitude
        // The crest is flat across the post, so the walk starts at the middle
        // of the plateau: without it the 0.036-wide slot between the two faces
        // is a notch a hull can drop into.
        var previous = SIMD2(0.0, moundCrestY)
        for index in 0 ..< moundSampleCount {
            let current = moundSurfacePoint(index)
            let edge = current - previous
            let lengthSquared = simd_length_squared(edge)
            var point = previous
            if lengthSquared > 1e-12 {
                let t = min(1, max(0, simd_dot(mirrored - previous, edge) / lengthSquared))
                point = previous + edge * t
            }
            let distanceSquared = simd_length_squared(mirrored - point)
            if distanceSquared < closestDistanceSquared {
                closestDistanceSquared = distanceSquared
                closest = point
                // The profile runs crest to base, so each segment's left-hand
                // normal points up and out of the hill.
                closestNormal = simd_normalize(
                    SIMD2(previous.y - current.y, current.x - previous.x)
                )
            }
            previous = current
        }

        var normal = closestNormal
        if !isUnderMound(mirrored) {
            guard closestDistanceSquared < radius * radius else { return nil }
            let away = mirrored - closest
            let length = simd_length(away)
            if length > 1e-9 { normal = away / length }
        }
        // Buried bodies keep the segment normal: from inside, the direction
        // back toward the surface says nothing about which way is out.

        var contact = closest + normal * radius
        if position.x < 0 {
            contact.x = -contact.x
            normal.x = -normal.x
        }
        return (contact, normal)
    }

    /// Steps along the motion in radius-sized slices. Static tests are enough
    /// for the walls and the corner arcs -- overshoot a concave boundary and
    /// you are still outside it -- but the hill is convex, and a driven ball
    /// covers three or four of its own radii a tick, so left unswept it simply
    /// teleports over the crest.
    public func moundContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let travel = simd_distance(start, end)
        let steps = max(1, min(32, Int((travel / max(radius * 0.5, 1e-4)).rounded(.up))))
        for step in 1 ... steps {
            let sample = start + (end - start) * (Double(step) / Double(steps))
            if let contact = moundContact(position: sample, radius: radius) {
                return contact
            }
        }
        return nil
    }

    private func isUnderMound(_ mirrored: SIMD2<Double>) -> Bool {
        guard mirrored.y < moundCrestY else { return false }
        if mirrored.x <= netHalfWidth { return true }
        guard mirrored.x < moundBaseX else { return false }
        let unit = SIMD2(
            (mirrored.x - moundBaseX) / cornerRadiusX,
            (mirrored.y - moundCrestY) / cornerRadiusY
        )
        return simd_length_squared(unit) > 1
    }

    // MARK: - Corners

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
