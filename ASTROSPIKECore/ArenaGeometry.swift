import Foundation
import simd

public struct BallState: Codable, Equatable, Sendable {
    /// The radius every ball is created with. The arena is dimensioned against
    /// it -- the portal collar in particular -- so it belongs here rather than
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

/// What stands in the middle of the court. The shipped arena hangs a portal
/// goal from the roof; the alternate courts either stand a solid net up off
/// the floor or clear the middle entirely for a hoop.
public enum NetStyle: String, Codable, Equatable, Sendable {
    /// One slab hanging from the roof hump, its faces a portal you shoot
    /// through. The original ASTROSPIKE court.
    case roofPortal
    /// A solid slab standing up from the floor, capped with a half-round.
    /// Nothing passes through it -- you play over it. Volleyball.
    case floorWall
    /// Nothing in the middle at all. Basketball puts a hoop there instead.
    case none
}

/// A rim hanging in the middle of the court: two posts with a window between
/// them. A ball that drops through the window from above is a bucket.
public struct HoopGeometry: Equatable, Sendable {
    /// The height of the rim line -- where a ball is judged to have gone in.
    public var centerY: Double
    /// Half the window between the posts. Comfortably wider than a ball, so
    /// a clean shot drops rather than wedging.
    public var innerHalfWidth: Double
    /// Radius of each rim post. The posts are hard: clipping one is a miss.
    public var rimRadius: Double
    /// How far the mesh hangs below the rim. Cosmetic; nothing collides.
    public var netDepth: Double

    public init(
        centerY: Double = 0.16,
        innerHalfWidth: Double = 0.072,
        rimRadius: Double = 0.014,
        netDepth: Double = 0.11
    ) {
        self.centerY = centerY
        self.innerHalfWidth = innerHalfWidth
        self.rimRadius = rimRadius
        self.netDepth = netDepth
    }

    /// Centre of the post on the `sign` side.
    public func postCenter(sign: Double) -> SIMD2<Double> {
        SIMD2(sign * (innerHalfWidth + rimRadius), centerY)
    }
}

public struct ArenaGeometry: Equatable, Sendable {
    public var halfWidth: Double
    public var floorY: Double
    public var ceilingY: Double
    /// Half-thickness of the net slab.
    public var netHalfWidth: Double
    /// Where the slab ends: the bottom of the mouth, and the centre of the
    /// rounded cap that closes it underneath.
    public var netBottomY: Double
    /// Corner arcs are deliberately elliptical, not quarter circles: wide and
    /// shallow, so a stray ball is nudged back toward the middle rather than
    /// spun around a bowl. Nobody plays the corners, so the payoff is a less
    /// predictable rebound rather than a new place to camp.
    ///
    /// The same arc is mirrored into the middle of the roof as the hump the
    /// net hangs from, so tuning one tunes both.
    public var cornerRadiusX: Double
    public var cornerRadiusY: Double
    /// How far the lip under each face reaches out from the slab.
    public var lipLength: Double
    /// How much higher the outer end of each lip sits than its root. That
    /// tilt is the whole point of the lip: a ball that lands on it rolls
    /// back down into the mouth instead of sitting there.
    public var lipRise: Double
    /// What stands in the middle. Switching this switches the court: the
    /// hump, the lips and the portal all belong to `.roofPortal` and are
    /// simply absent from the others.
    public var netStyle: NetStyle
    /// Top of the floor-mounted slab, and the centre of the half-round that
    /// caps it. Only read when `netStyle` is `.floorWall`.
    public var netTopY: Double
    /// The rim, when there is one. Only read when `netStyle` is `.none`.
    public var hoop: HoopGeometry?

    public init(
        halfWidth: Double = 0.96,
        floorY: Double = -0.64,
        ceilingY: Double = 0.64,
        netHalfWidth: Double = 0.018,
        // Hangs one collar below the underside of the hump (see
        // `portalMouthTopY`), which keeps the goal the same size it has
        // always been now that the top of the net is buried in the roof.
        netBottomY: Double = 0.184,
        cornerRadiusX: Double = 0.30,
        cornerRadiusY: Double = 0.16,
        // Three ball radii of ledge: big enough to catch a shot that arrives
        // a little under the mouth, small enough that it is still the mouth,
        // not the lip, that you are shooting at.
        lipLength: Double = 0.11,
        lipRise: Double = 0.035,
        netStyle: NetStyle = .roofPortal,
        // Dead level with the middle of the court, so the slab covers exactly
        // the bottom half of the arena.
        netTopY: Double = 0,
        hoop: HoopGeometry? = nil
    ) {
        self.halfWidth = halfWidth
        self.floorY = floorY
        self.ceilingY = ceilingY
        self.netHalfWidth = netHalfWidth
        self.netBottomY = netBottomY
        self.cornerRadiusX = cornerRadiusX
        self.cornerRadiusY = cornerRadiusY
        self.lipLength = lipLength
        self.lipRise = lipRise
        self.netStyle = netStyle
        self.netTopY = netTopY
        self.hoop = hoop
    }

    public static let standard = ArenaGeometry()

    /// Volleyball: the net comes down off the roof and stands up out of the
    /// floor, covering the bottom half of the arena. Nothing passes through
    /// it, so the middle is a wall you have to lift the ball over -- and the
    /// roof goes flat, because the hump only ever existed to hang a goal.
    public static let volleyball = ArenaGeometry(
        netStyle: .floorWall,
        netTopY: 0
    )

    /// Basketball: the middle is cleared entirely and a single rim hangs at
    /// centre court. Both halves shoot at the same hoop.
    public static let basketball = ArenaGeometry(
        netStyle: .none,
        hoop: HoopGeometry()
    )

    /// The hump and the lips are parts of the roof-hung goal. Without one
    /// the roof is flat and the middle is clear.
    public var hasHump: Bool { netStyle == .roofPortal }
    public var hasLips: Bool { netStyle == .roofPortal }

    public var opponentCrossingLimit: Double { halfWidth / 2 }

    /// Where the flat floor and ceiling end and the corner arc begins.
    public var cornerTangentX: Double { halfWidth - cornerRadiusX }

    // MARK: - The hump the net hangs from

    /// The corner fillet, mirrored inward and hung from the roof with the net
    /// face standing in for the side wall: horizontal where it meets the
    /// ceiling, vertical where it meets the slab. A ball riding the roof into
    /// the middle is therefore turned down and away instead of sliding along
    /// the ceiling into the goal.
    public var humpBaseX: Double { netHalfWidth + cornerRadiusX }

    /// The underside of the hump: the lowest it reaches, flat across the
    /// width of the slab.
    public var humpUndersideY: Double { ceilingY - cornerRadiusY }

    /// The face is a portal only below this line. Above it the slab is a
    /// solid collar hanging from the hump, because the underside is tangent
    /// to the face -- without the band, a ball riding down the last of the
    /// slope would be touching the portal at the exact instant it is touching
    /// the hump. One ball diameter of collar, so anything that scores is
    /// clear of the hump.
    public var portalMouthTopY: Double { humpUndersideY - BallState.nominalRadius * 2 }

    /// The net *is* the goal, and it is a portal rather than a wall: a ball
    /// driven into the open part of either face passes through and is gone.
    /// The rounded cap underneath still rebounds, so clipping the net from
    /// below is a miss.
    ///
    /// One slab, dead centre, hanging from the roof. Its mouth is the target
    /// both sides shoot at -- lifted and driven on purpose, because it is the
    /// one place in the arena a ball never wanders on its own.
    public var portalFaceHeight: Double { portalMouthTopY - netBottomY }

    // MARK: - The lips

    /// Where the lip on the `sign` side meets the slab.
    public func lipRoot(sign: Double) -> SIMD2<Double> {
        SIMD2(sign * netHalfWidth, netBottomY)
    }

    /// The outer end of the lip on the `sign` side, raised so the ledge
    /// slopes down into the mouth.
    public func lipTip(sign: Double) -> SIMD2<Double> {
        SIMD2(sign * (netHalfWidth + lipLength), netBottomY + lipRise)
    }

    /// Pushes a ball of `radius` off whichever lip it is touching. The lip is
    /// a line rather than a slab, so the ball can be on either side of it: on
    /// top, where it rolls into the mouth, or underneath, where it is simply
    /// in the way. Both sides push straight away from the ledge.
    public func lipContact(
        position: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard hasLips else { return nil }
        let mirrored = SIMD2(abs(position.x), position.y)
        let root = lipRoot(sign: 1)
        let tip = lipTip(sign: 1)
        guard mirrored.x <= tip.x + radius,
              mirrored.y >= root.y - radius,
              mirrored.y <= tip.y + radius else { return nil }

        let edge = tip - root
        let t = min(1, max(0, simd_dot(mirrored - root, edge) / simd_length_squared(edge)))
        let closest = root + edge * t
        let away = mirrored - closest
        let distance = simd_length(away)
        guard distance < radius else { return nil }

        // A ball centred exactly on the line has no side; call it the top,
        // which is where a ball that got that close was heading.
        var normal = distance > 1e-9
            ? away / distance
            : simd_normalize(SIMD2(-edge.y, edge.x))
        var contact = closest + normal * radius
        if position.x < 0 {
            contact.x = -contact.x
            normal.x = -normal.x
        }
        return (contact, normal)
    }

    /// Swept version of `lipContact`, for the same reason the hump has one:
    /// the lip is thin, and a driven ball crosses its own diameter in a tick.
    public func lipContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let travel = simd_distance(start, end)
        let steps = max(1, min(32, Int((travel / max(radius * 0.5, 1e-4)).rounded(.up))))
        for step in 1 ... steps {
            let sample = start + (end - start) * (Double(step) / Double(steps))
            if let contact = lipContact(position: sample, radius: radius) {
                return contact
            }
        }
        return nil
    }

    // MARK: - Hump surface

    /// How many segments the quarter arc is cut into.
    public static let humpArcSegments = 16

    /// Evenly spaced (sin, cos) from the face (theta = pi/2) up to the roof
    /// (theta = 0). A table rather than live trig: the hump is tested several
    /// times per body per tick, and the renderer walks the same samples, so the
    /// drawn slope cannot drift from the one balls bounce off.
    private static let arcUnit: [SIMD2<Double>] = (0 ... humpArcSegments).map { step in
        let theta = Double(humpArcSegments - step) / Double(humpArcSegments) * (.pi / 2)
        return SIMD2(sin(theta), cos(theta))
    }

    public var humpSampleCount: Int { Self.arcUnit.count }

    /// Sample `index` of the right-hand slope, running underside to roof.
    public func humpSurfacePoint(_ index: Int) -> SIMD2<Double> {
        let unit = Self.arcUnit[index]
        return SIMD2(humpBaseX - cornerRadiusX * unit.x, humpUndersideY + cornerRadiusY * unit.y)
    }

    /// The right-hand profile including the flat underside, for drawing.
    public var humpProfile: [SIMD2<Double>] {
        [SIMD2(0, humpUndersideY)] + (0 ..< humpSampleCount).map(humpSurfacePoint)
    }

    /// Pushes a body of `radius` off the hump. Tested against the sampled
    /// polyline rather than the ellipse itself: the shrink-the-semi-axes trick
    /// the corners use is only valid from the inside of a curve. Grown by a
    /// ball radius, this arc would first touch a roof-riding ball at x = 0.05
    /// -- a wall in the middle of the court, not a ramp.
    public func humpContact(
        position: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard hasHump else { return nil }
        let mirrored = SIMD2(abs(position.x), position.y)
        guard mirrored.x <= humpBaseX + radius, mirrored.y >= humpUndersideY - radius else {
            return nil
        }

        var closest = SIMD2(0.0, humpUndersideY)
        var closestNormal = SIMD2(0.0, -1.0)
        var closestDistanceSquared = Double.greatestFiniteMagnitude
        // The underside is flat across the slab, so the walk starts at the
        // middle of it: without that the 0.036-wide slot between the two
        // faces is a notch a hull can wedge into.
        var previous = SIMD2(0.0, humpUndersideY)
        for index in 0 ..< humpSampleCount {
            let current = humpSurfacePoint(index)
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
                // The profile runs underside to roof, so each segment's
                // right-hand normal points down and out of the hump.
                closestNormal = simd_normalize(
                    SIMD2(current.y - previous.y, previous.x - current.x)
                )
            }
            previous = current
        }

        var normal = closestNormal
        if !isInsideHump(mirrored) {
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
    /// you are still outside it -- but the hump is convex, and a driven ball
    /// covers three or four of its own radii a tick, so left unswept it simply
    /// teleports through.
    public func humpContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        let travel = simd_distance(start, end)
        let steps = max(1, min(32, Int((travel / max(radius * 0.5, 1e-4)).rounded(.up))))
        for step in 1 ... steps {
            let sample = start + (end - start) * (Double(step) / Double(steps))
            if let contact = humpContact(position: sample, radius: radius) {
                return contact
            }
        }
        return nil
    }

    private func isInsideHump(_ mirrored: SIMD2<Double>) -> Bool {
        guard mirrored.y > humpUndersideY else { return false }
        if mirrored.x <= netHalfWidth { return true }
        guard mirrored.x < humpBaseX else { return false }
        let unit = SIMD2(
            (mirrored.x - humpBaseX) / cornerRadiusX,
            (mirrored.y - humpUndersideY) / cornerRadiusY
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

    /// Who scores, for a ball that has just gone through the portal. The face
    /// on your side is your goal to defend, so a ball that enters through the
    /// left face -- from the cyan half -- is a point for orange.
    public func portalScorer(enteredFromLeft: Bool) -> Team {
        enteredFromLeft ? .orange : .cyan
    }

    // MARK: - The floor-mounted net

    /// The top of the slab, as a point. The cap is a half-round centred here
    /// with the slab's own half-thickness for a radius, so the net is a
    /// capsule: a rectangle from the floor up, rounded off at the top. The
    /// bottom of that capsule is buried in the floor, where nothing can reach
    /// it, which is why one shape does for the whole net.
    public var netCapCenter: SIMD2<Double> { SIMD2(0, netTopY) }

    /// Pushes a body of `radius` off the floor-mounted slab. `preferredSide`
    /// breaks the tie for a body that has ended up dead centre inside the
    /// net, where "away" has no direction of its own -- pass the side it came
    /// from, or either side if it came from neither.
    public func floorNetContact(
        position: SIMD2<Double>,
        radius: Double,
        preferredSide: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard netStyle == .floorWall else { return nil }
        let combined = netHalfWidth + radius
        // Closest point on the slab's spine: the segment from the floor up to
        // the cap centre.
        let spineY = min(netTopY, max(floorY, position.y))
        let closest = SIMD2(0, spineY)
        let away = position - closest
        let distance = simd_length(away)
        guard distance < combined else { return nil }

        let normal: SIMD2<Double>
        if distance > 0.000_001 {
            normal = away / distance
        } else {
            normal = SIMD2(preferredSide < 0 ? -1 : 1, 0)
        }
        return (closest + normal * combined, normal)
    }

    /// Swept version. The slab is thin and a driven ball crosses several of
    /// its own radii a tick, so left unswept it simply teleports through.
    public func floorNetContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard netStyle == .floorWall else { return nil }
        let preferredSide: Double = if abs(start.x) > 0.000_001 {
            start.x
        } else if abs(end.x) > 0.000_001 {
            -end.x
        } else {
            1
        }
        let travel = simd_distance(start, end)
        let steps = max(1, min(32, Int((travel / max(radius * 0.5, 1e-4)).rounded(.up))))
        for step in 1 ... steps {
            let sample = start + (end - start) * (Double(step) / Double(steps))
            if let contact = floorNetContact(
                position: sample,
                radius: radius,
                preferredSide: preferredSide
            ) {
                return contact
            }
        }
        return nil
    }

    // MARK: - The hoop

    /// Pushes a body of `radius` off whichever rim post it is touching. The
    /// posts are the only solid part of the hoop; the window between them is
    /// open, and so is everything below.
    public func hoopRimContact(
        position: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard let hoop else { return nil }
        let combined = hoop.rimRadius + radius
        let sign: Double = position.x < 0 ? -1 : 1
        let center = hoop.postCenter(sign: sign)
        let away = position - center
        let distance = simd_length(away)
        guard distance < combined, distance > 0.000_001 else { return nil }
        let normal = away / distance
        return (center + normal * combined, normal)
    }

    /// Swept version, for the same reason everything else in the middle of
    /// the court has one.
    public func hoopRimContact(
        from start: SIMD2<Double>,
        to end: SIMD2<Double>,
        radius: Double
    ) -> (position: SIMD2<Double>, normal: SIMD2<Double>)? {
        guard hoop != nil else { return nil }
        let travel = simd_distance(start, end)
        let steps = max(1, min(32, Int((travel / max(radius * 0.5, 1e-4)).rounded(.up))))
        for step in 1 ... steps {
            let sample = start + (end - start) * (Double(step) / Double(steps))
            if let contact = hoopRimContact(position: sample, radius: radius) {
                return contact
            }
        }
        return nil
    }

    /// Did the ball drop through the rim on this tick? Downward only: coming
    /// up through the hoop from underneath is not a bucket, same as the real
    /// game. Judged on the centre of the ball, and the window is wide enough
    /// that a ball whose centre clears it was never touching a post.
    public func hoopScored(from start: SIMD2<Double>, to end: SIMD2<Double>) -> Bool {
        guard let hoop else { return false }
        guard start.y > hoop.centerY, end.y <= hoop.centerY else { return false }
        let drop = start.y - end.y
        guard drop > 0.000_000_1 else { return false }
        let t = (start.y - hoop.centerY) / drop
        let crossingX = start.x + (end.x - start.x) * t
        return abs(crossingX) <= hoop.innerHalfWidth
    }
}
