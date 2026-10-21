import Foundation

/// ASTROBALL, the volleyball court: a wall of a net up out of the floor,
/// a few touches a side to get the ball back over, and a strip of each half
/// that ends the rally the moment the ball touches it. The host's numbers
/// ride the wire with the rest of its tuning, so every board keeps the same
/// book.
public struct AstroballTuning: Equatable, Sendable, Codable {
    /// Touches a side flown by one pilot gets before the ball has to be
    /// over: 1 is one touch and over, 3 is three. A side of two always gets
    /// three, and neither pilot may play it twice running.
    public var soloTouches = 3
    public static let soloTouchesRange: ClosedRange<Int> = 1 ... 3
    /// The scoring zone, as a stretch of each half's wall path: 0 is the
    /// foot of the net, 1 the roof at the side wall. The path runs along the
    /// floor, round the corner, up the wall and round into the roof.
    public var zoneStart = 0.0
    public var zoneEnd = AstroballTuning.defaultZoneEnd
    /// How much speed the ball keeps off the walls, roof and corners. The
    /// duel's are 0.82; lower soaks a spike up instead of firing it back.
    public var wallBounce = 0.5
    public static let wallBounceRange: ClosedRange<Double> = 0.2 ... 0.82

    /// The half of the floor nearest the net.
    public static let defaultZoneEnd = ArenaGeometry.volleyball.wallPathFraction(ofFloor: 0.5)

    public init() {}

    /// The touch cap for a side flown by `pilots` hulls.
    public func touchLimit(pilots: Int) -> Int {
        pilots > 1 ? 3 : min(Self.soloTouchesRange.upperBound, max(Self.soloTouchesRange.lowerBound, soloTouches))
    }

    /// Whether `fraction` along a half's wall path is in the zone. The two
    /// ends may arrive either way round.
    public func zoneContains(_ fraction: Double) -> Bool {
        guard let zone = zoneRange else { return false }
        return zone.contains(fraction)
    }

    /// The zone's ends in order, clamped to the path. Nil when it is empty
    /// or a host's numbers off the wire are not finite.
    public var zoneRange: ClosedRange<Double>? {
        guard zoneStart.isFinite, zoneEnd.isFinite else { return nil }
        let low = min(1, max(0, min(zoneStart, zoneEnd)))
        let high = min(1, max(0, max(zoneStart, zoneEnd)))
        return high > low ? low ... high : nil
    }

    public static let soloTouchesKey = "astroball.soloTouches"
    public static let zoneStartKey = "astroball.zoneStart"
    public static let zoneEndKey = "astroball.zoneEnd"
    public static let wallBounceKey = "astroball.wallBounce"

    /// The pilot's settings, each clamped to its slider; one never set reads
    /// its default.
    public static func stored(in defaults: UserDefaults = .standard) -> AstroballTuning {
        var tuning = AstroballTuning()
        if let value = defaults.object(forKey: soloTouchesKey) as? Int {
            tuning.soloTouches = min(soloTouchesRange.upperBound, max(soloTouchesRange.lowerBound, value))
        }
        if let value = defaults.object(forKey: zoneStartKey) as? Double { tuning.zoneStart = min(1, max(0, value)) }
        if let value = defaults.object(forKey: zoneEndKey) as? Double { tuning.zoneEnd = min(1, max(0, value)) }
        if let value = defaults.object(forKey: wallBounceKey) as? Double {
            tuning.wallBounce = min(wallBounceRange.upperBound, max(wallBounceRange.lowerBound, value))
        }
        return tuning
    }

    /// Writes each setting, or clears it back to default.
    public func store(in defaults: UserDefaults = .standard) {
        let base = AstroballTuning()
        if soloTouches == base.soloTouches { defaults.removeObject(forKey: Self.soloTouchesKey) } else { defaults.set(soloTouches, forKey: Self.soloTouchesKey) }
        if zoneStart == base.zoneStart { defaults.removeObject(forKey: Self.zoneStartKey) } else { defaults.set(zoneStart, forKey: Self.zoneStartKey) }
        if zoneEnd == base.zoneEnd { defaults.removeObject(forKey: Self.zoneEndKey) } else { defaults.set(zoneEnd, forKey: Self.zoneEndKey) }
        if wallBounce == base.wallBounce { defaults.removeObject(forKey: Self.wallBounceKey) } else { defaults.set(wallBounce, forKey: Self.wallBounceKey) }
    }

    public var clampedWallBounce: Double {
        wallBounce.isFinite
            ? min(Self.wallBounceRange.upperBound, max(Self.wallBounceRange.lowerBound, wallBounce))
            : 0.5
    }
}

/// What the rulebook needs to know about the sides each step: how many
/// hulls fly each one, and so how many touches it gets and whether the
/// same pilot may play the ball twice running.
public struct VolleyRules: Equatable, Sendable {
    public var touchLimit: SideCounts
    public var pilots: SideCounts

    public init(tuning: AstroballTuning, pilots: SideCounts) {
        self.pilots = pilots
        touchLimit = SideCounts(
            cyan: tuning.touchLimit(pilots: pilots.cyan),
            orange: tuning.touchLimit(pilots: pilots.orange)
        )
    }
}

public extension ArenaGeometry {
    /// The ASTROBALL court: volleyball's floor-standing net, on the duel's
    /// court or the doubles court a quarter bigger.
    static func astroball(doubles: Bool) -> ArenaGeometry {
        guard doubles else { return .volleyball }
        return ArenaGeometry(
            halfWidth: standard.halfWidth * doublesScale,
            floorY: standard.floorY * doublesScale,
            ceilingY: standard.ceilingY * doublesScale,
            netStyle: .floorWall,
            netTopY: 0
        )
    }

    /// Each half's wall path, piece by piece: floor from the net to the
    /// corner, the floor corner, the side wall, the roof corner.
    private var wallPathPieces: (floor: Double, corner: Double, wall: Double) {
        let floor = max(0, cornerTangentX - netHalfWidth)
        let a = cornerRadiusX
        let b = cornerRadiusY
        // A quarter of Ramanujan's ellipse perimeter.
        let corner = Double.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot()) / 4
        let wall = max(0, (ceilingY - cornerRadiusY) - (floorY + cornerRadiusY))
        return (floor, corner, wall)
    }

    private var wallPathLength: Double {
        let pieces = wallPathPieces
        return pieces.floor + 2 * pieces.corner + pieces.wall
    }

    /// The fraction of the path at which `share` of the flat floor, measured
    /// out from the net, ends.
    func wallPathFraction(ofFloor share: Double) -> Double {
        let total = wallPathLength
        guard total > 0 else { return 0 }
        return wallPathPieces.floor * min(1, max(0, share)) / total
    }

    /// Where along its half's wall path a point on the court's skin sits,
    /// 0 at the foot of the net to 1 at the roof. Nil for the flat of the
    /// roof, which the path never reaches.
    func wallPathFraction(at surface: SIMD2<Double>) -> Double? {
        let total = wallPathLength
        guard total > 0 else { return nil }
        let pieces = wallPathPieces
        let x = abs(surface.x)
        let lowArc = floorY + cornerRadiusY
        let highArc = ceilingY - cornerRadiusY
        let quarter = Double.pi / 2
        let along: Double
        if x < cornerTangentX {
            // The flat floor, or the flat roof. Their ends belong to the
            // corners, so the roof's end of the path still reads 1.
            guard surface.y < (floorY + ceilingY) / 2 else { return nil }
            along = max(0, x - netHalfWidth)
        } else if surface.y < lowArc {
            let angle = atan2((x - cornerTangentX) / cornerRadiusX, (lowArc - surface.y) / cornerRadiusY)
            along = pieces.floor + pieces.corner * min(1, max(0, angle / quarter))
        } else if surface.y <= highArc {
            along = pieces.floor + pieces.corner + (surface.y - lowArc)
        } else {
            let angle = atan2((surface.y - highArc) / cornerRadiusY, (x - cornerTangentX) / cornerRadiusX)
            along = pieces.floor + pieces.corner + pieces.wall + pieces.corner * min(1, max(0, angle / quarter))
        }
        return min(1, along / total)
    }

    /// Where `fraction` along the path sits, for the Settings readout:
    /// how far out the floor, or which bend of the wall.
    func wallPathPlace(at fraction: Double) -> String {
        let pieces = wallPathPieces
        let along = min(1, max(0, fraction)) * wallPathLength
        if along <= pieces.floor {
            let share = pieces.floor > 0 ? along / pieces.floor : 0
            return "FLOOR \(Int((share * 100).rounded()))%"
        }
        if along <= pieces.floor + pieces.corner { return "FLOOR CORNER" }
        if along <= pieces.floor + pieces.corner + pieces.wall {
            let share = pieces.wall > 0 ? (along - pieces.floor - pieces.corner) / pieces.wall : 0
            return "SIDE WALL \(Int((share * 100).rounded()))%"
        }
        return fraction >= 1 ? "ROOF" : "ROOF CORNER"
    }

    /// The point `fraction` of the way along the right half's wall path, for
    /// the board to draw the zone. Mirror x for the left half.
    func wallPathPoint(at fraction: Double) -> SIMD2<Double> {
        let pieces = wallPathPieces
        var along = min(1, max(0, fraction)) * wallPathLength
        if along <= pieces.floor { return SIMD2(netHalfWidth + along, floorY) }
        along -= pieces.floor
        let quarter = Double.pi / 2
        if along <= pieces.corner {
            let angle = along / pieces.corner * quarter
            return SIMD2(
                cornerTangentX + cornerRadiusX * sin(angle),
                floorY + cornerRadiusY - cornerRadiusY * cos(angle)
            )
        }
        along -= pieces.corner
        if along <= pieces.wall { return SIMD2(halfWidth, floorY + cornerRadiusY + along) }
        along -= pieces.wall
        let angle = min(1, along / max(pieces.corner, 0.000_001)) * quarter
        return SIMD2(
            cornerTangentX + cornerRadiusX * cos(angle),
            ceilingY - cornerRadiusY + cornerRadiusY * sin(angle)
        )
    }
}
