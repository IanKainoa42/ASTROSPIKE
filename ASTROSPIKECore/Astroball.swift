import Foundation

/// ASTROBALL, the volleyball court: a wall of a net up out of the floor,
/// a few touches a side to get the ball back over, and a strip of each half
/// that ends the rally the moment the ball touches it. The host's numbers
/// ride the wire with the rest of its tuning, so every board keeps the same
/// book.
public struct AstroballTuning: Equatable, Sendable, Codable {
    /// Touches a side flown by one pilot gets before the ball has to be
    /// over: 1 is one touch and over, 3 is three. A side of two always gets
    /// three.
    public var soloTouches = 3
    public static let soloTouchesRange: ClosedRange<Int> = 1 ... 3
    /// How many times running one pilot may play the ball: 2 lets a pilot
    /// press it twice, and the third is a triple hit. Holds for a pilot
    /// alone on a side too.
    public var inARow = 2
    public static let inARowRange: ClosedRange<Int> = 1 ... 3
    /// The scoring zone, as a stretch of each half's wall path: 0 is the
    /// foot of the net, 1 the roof at the side wall. The path runs along the
    /// floor, round the corner, up the wall and round into the roof.
    public var zoneStart = 0.0
    public var zoneEnd = AstroballTuning.defaultZoneEnd
    /// A second zone, by default the back of the court: the floor corner and
    /// the lower quarter of the side wall.
    public var zone2Start = AstroballTuning.defaultZone2Start
    public var zone2End = AstroballTuning.defaultZone2End
    /// How much speed the ball keeps off the walls, roof and corners. The
    /// duel's are 0.82; lower soaks a spike up instead of firing it back.
    public var wallBounce = 0.5
    public static let wallBounceRange: ClosedRange<Double> = 0.2 ... 0.82
    /// How much speed the ball keeps off the floor. Deader than the walls,
    /// so a spike that lands stays down and a wall rebound is still live;
    /// never livelier than the walls, whatever the slider says (see
    /// `clampedFloorBounce`). The duel's floor is 0.78.
    public var floorBounce = 0.3
    public static let floorBounceRange: ClosedRange<Double> = 0.1 ... 0.82
    /// The MAX CROSS line stands on the net and leans over the far half:
    /// this is how far over it reaches at the roof, as a share of a half's
    /// width. 0 is straight up off the net.
    public var crossLean = 0.3
    public static let crossLeanRange: ClosedRange<Double> = 0 ... 0.6
    /// How hard MAX CROSS flings a hull back per unit past it. Stiff and
    /// undamped, so a hull can cross but is slung home; the duel's treacle
    /// is 18 with drag.
    public static let crossSlingshot = 30.0
    /// How far above the net top the far side stays shut to a hull, and how
    /// much the lift out of it is damped so the hull rises, not bobs.
    public static let crossNetClearance = 0.1
    public static let crossLiftDamping = 4.0
    /// The two sides' colours this match. Not a setting: drawn fresh each
    /// match (`withRandomHues`) and carried on the host's tuning so every
    /// phone paints the same court.
    public var hues = TeamHues()
    /// What a hull touching the net's upper half costs: nothing, a second
    /// stunned (the default), or its side the point.
    public var netTouch = NetTouch.stun

    /// The floor nearest the net, out to 28%: straight-down spikes.
    public static let defaultZoneEnd = ArenaGeometry.astroball(doubles: false).wallPathFraction(ofFloor: 0.28)
    /// A small target low on the back wall, 7% to 13% of the way up it.
    public static let defaultZone2Start = ArenaGeometry.astroball(doubles: false).wallPathFraction(ofWall: 0.07)
    public static let defaultZone2End = ArenaGeometry.astroball(doubles: false).wallPathFraction(ofWall: 0.13)

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case soloTouches, inARow, zoneStart, zoneEnd, zone2Start, zone2End, wallBounce, floorBounce, crossLean, hues, netTouch
    }

    /// Hosts older than the second zone omit its ends: they read the default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        soloTouches = try container.decodeIfPresent(Int.self, forKey: .soloTouches) ?? soloTouches
        inARow = try container.decodeIfPresent(Int.self, forKey: .inARow) ?? inARow
        crossLean = try container.decodeIfPresent(Double.self, forKey: .crossLean) ?? crossLean
        hues = try container.decodeIfPresent(TeamHues.self, forKey: .hues) ?? hues
        netTouch = try container.decodeIfPresent(NetTouch.self, forKey: .netTouch) ?? netTouch
        zoneStart = try container.decodeIfPresent(Double.self, forKey: .zoneStart) ?? zoneStart
        zoneEnd = try container.decodeIfPresent(Double.self, forKey: .zoneEnd) ?? zoneEnd
        zone2Start = try container.decodeIfPresent(Double.self, forKey: .zone2Start) ?? zone2Start
        zone2End = try container.decodeIfPresent(Double.self, forKey: .zone2End) ?? zone2End
        wallBounce = try container.decodeIfPresent(Double.self, forKey: .wallBounce) ?? wallBounce
        floorBounce = try container.decodeIfPresent(Double.self, forKey: .floorBounce) ?? floorBounce
    }

    /// The touch cap for a side flown by `pilots` hulls.
    public func touchLimit(pilots: Int) -> Int {
        pilots > 1 ? 3 : min(Self.soloTouchesRange.upperBound, max(Self.soloTouchesRange.lowerBound, soloTouches))
    }

    /// Whether `fraction` along a half's wall path is in the zone. The two
    /// ends may arrive either way round.
    public func zoneContains(_ fraction: Double) -> Bool {
        zoneRanges.contains { $0.contains(fraction) }
    }

    /// Both zones, in order, each clamped; empty ones left out.
    public var zoneRanges: [ClosedRange<Double>] {
        [Self.range(zoneStart, zoneEnd), Self.range(zone2Start, zone2End)].compactMap { $0 }
    }

    private static func range(_ a: Double, _ b: Double) -> ClosedRange<Double>? {
        guard a.isFinite, b.isFinite else { return nil }
        let low = min(1, max(0, min(a, b)))
        let high = min(1, max(0, max(a, b)))
        return high > low ? low ... high : nil
    }

    /// The zone's ends in order, clamped to the path. Nil when it is empty
    /// or a host's numbers off the wire are not finite.
    public var zoneRange: ClosedRange<Double>? { Self.range(zoneStart, zoneEnd) }

    public static let soloTouchesKey = "astroball.soloTouches"
    public static let zoneStartKey = "astroball.zoneStart"
    public static let zoneEndKey = "astroball.zoneEnd"
    public static let zone2StartKey = "astroball.zone2Start"
    public static let zone2EndKey = "astroball.zone2End"
    public static let wallBounceKey = "astroball.wallBounce"
    public static let floorBounceKey = "astroball.floorBounce"
    public static let inARowKey = "astroball.inARow"
    public static let crossLeanKey = "astroball.crossLean"
    public static let netTouchKey = "astroball.netTouch"

    /// The pilot's settings, each clamped to its slider; one never set reads
    /// its default.
    public static func stored(in defaults: UserDefaults = .standard) -> AstroballTuning {
        var tuning = AstroballTuning()
        if let value = defaults.object(forKey: soloTouchesKey) as? Int {
            tuning.soloTouches = min(soloTouchesRange.upperBound, max(soloTouchesRange.lowerBound, value))
        }
        if let value = defaults.object(forKey: zoneStartKey) as? Double { tuning.zoneStart = min(1, max(0, value)) }
        if let value = defaults.object(forKey: zoneEndKey) as? Double { tuning.zoneEnd = min(1, max(0, value)) }
        if let value = defaults.object(forKey: zone2StartKey) as? Double { tuning.zone2Start = min(1, max(0, value)) }
        if let value = defaults.object(forKey: zone2EndKey) as? Double { tuning.zone2End = min(1, max(0, value)) }
        if let value = defaults.object(forKey: wallBounceKey) as? Double {
            tuning.wallBounce = min(wallBounceRange.upperBound, max(wallBounceRange.lowerBound, value))
        }
        if let value = defaults.object(forKey: floorBounceKey) as? Double {
            tuning.floorBounce = min(floorBounceRange.upperBound, max(floorBounceRange.lowerBound, value))
        }
        if let value = defaults.object(forKey: inARowKey) as? Int {
            tuning.inARow = min(inARowRange.upperBound, max(inARowRange.lowerBound, value))
        }
        if let value = defaults.object(forKey: crossLeanKey) as? Double {
            tuning.crossLean = min(crossLeanRange.upperBound, max(crossLeanRange.lowerBound, value))
        }
        if let value = defaults.string(forKey: netTouchKey).flatMap(NetTouch.init(rawValue:)) { tuning.netTouch = value }
        return tuning
    }

    /// Writes each setting, or clears it back to default.
    public func store(in defaults: UserDefaults = .standard) {
        let base = AstroballTuning()
        if soloTouches == base.soloTouches { defaults.removeObject(forKey: Self.soloTouchesKey) } else { defaults.set(soloTouches, forKey: Self.soloTouchesKey) }
        if zoneStart == base.zoneStart { defaults.removeObject(forKey: Self.zoneStartKey) } else { defaults.set(zoneStart, forKey: Self.zoneStartKey) }
        if zoneEnd == base.zoneEnd { defaults.removeObject(forKey: Self.zoneEndKey) } else { defaults.set(zoneEnd, forKey: Self.zoneEndKey) }
        if zone2Start == base.zone2Start { defaults.removeObject(forKey: Self.zone2StartKey) } else { defaults.set(zone2Start, forKey: Self.zone2StartKey) }
        if zone2End == base.zone2End { defaults.removeObject(forKey: Self.zone2EndKey) } else { defaults.set(zone2End, forKey: Self.zone2EndKey) }
        if wallBounce == base.wallBounce { defaults.removeObject(forKey: Self.wallBounceKey) } else { defaults.set(wallBounce, forKey: Self.wallBounceKey) }
        if floorBounce == base.floorBounce { defaults.removeObject(forKey: Self.floorBounceKey) } else { defaults.set(floorBounce, forKey: Self.floorBounceKey) }
        if inARow == base.inARow { defaults.removeObject(forKey: Self.inARowKey) } else { defaults.set(inARow, forKey: Self.inARowKey) }
        if crossLean == base.crossLean { defaults.removeObject(forKey: Self.crossLeanKey) } else { defaults.set(crossLean, forKey: Self.crossLeanKey) }
        if netTouch == base.netTouch { defaults.removeObject(forKey: Self.netTouchKey) } else { defaults.set(netTouch.rawValue, forKey: Self.netTouchKey) }
    }

    public var clampedWallBounce: Double {
        wallBounce.isFinite
            ? min(Self.wallBounceRange.upperBound, max(Self.wallBounceRange.lowerBound, wallBounce))
            : 0.5
    }

    /// The floor's bounce, clamped to its slider and never above the walls'.
    public var clampedFloorBounce: Double {
        let floor = floorBounce.isFinite
            ? min(Self.floorBounceRange.upperBound, max(Self.floorBounceRange.lowerBound, floorBounce))
            : 0.3
        return min(floor, clampedWallBounce)
    }

    /// The same-pilot cap, clamped: a host's number off the wire is not
    /// trusted to be in range.
    public var clampedInARow: Int {
        min(Self.inARowRange.upperBound, max(Self.inARowRange.lowerBound, inARow))
    }

    public var clampedCrossLean: Double {
        crossLean.isFinite ? min(Self.crossLeanRange.upperBound, max(Self.crossLeanRange.lowerBound, crossLean)) : 0.3
    }

}

/// What the rulebook needs to know about the sides each step: how many
/// hulls fly each one, and so how many touches it gets and whether the
/// same pilot may play the ball twice running.
public struct VolleyRules: Equatable, Sendable {
    public var touchLimit: SideCounts
    public var pilots: SideCounts
    /// Most times running one pilot may play it.
    public var inARow: Int

    public init(tuning: AstroballTuning, pilots: SideCounts) {
        self.pilots = pilots
        inARow = tuning.clampedInARow
        touchLimit = SideCounts(
            cyan: tuning.touchLimit(pilots: pilots.cyan),
            orange: tuning.touchLimit(pilots: pilots.orange)
        )
    }
}

public extension ArenaGeometry {
    /// How much wider than the volleyball court ASTROBALL's is, for room
    /// to set and spike. The height stays.
    static let astroballWidthScale = 1.3

    /// The ASTROBALL court: volleyball's floor-standing net on a court
    /// stretched wide, the duel's height or the doubles court's a quarter
    /// taller.
    static func astroball(doubles: Bool) -> ArenaGeometry {
        let scale = doubles ? doublesScale : 1
        var court = ArenaGeometry(
            halfWidth: standard.halfWidth * scale * astroballWidthScale,
            floorY: standard.floorY * scale,
            ceilingY: standard.ceilingY * scale,
            netStyle: .floorWall,
            netTopY: 0
        )
        let span = court.sideWallSpan
        court.wallInset = max(0, span.high - span.low) * tan(astroballWallLean)
        return court
    }

    /// How far ASTROBALL's side walls lean out from plumb as they rise.
    /// Ian: reward hitting the ball down at the floor, not just into the
    /// side walls. Off a wall leaning this far a ball leaves twice the lean
    /// steeper upward than it came in, so a bank shot climbs back into play
    /// instead of dropping into the corner.
    static let astroballWallLean = 15 * Double.pi / 180

    /// How far into the far half a hull may fly at height `y` before the
    /// MAX CROSS line shoves it back. Every court but ASTROBALL's has a
    /// straight line halfway across the far half; ASTROBALL's stands on the
    /// top of the net and leans over the far side as it rises, so a hull
    /// can reach over to spike but not fly round the net.
    func crossingLimit(atY y: Double, astroball: AstroballTuning?) -> Double {
        guard let astroball, netStyle == .floorWall else { return opponentCrossingLimit }
        let rise = ceilingY - netTopY
        guard rise > 0 else { return 0 }
        let height = min(1, max(0, (y - netTopY) / rise))
        return height * astroball.clampedCrossLean * halfWidth
    }

    /// Each half's wall path, piece by piece: floor from the net to the
    /// corner, the floor corner, the side wall, the roof corner.
    private var wallPathPieces: (floor: Double, corner: Double, wall: Double) {
        let floor = max(0, floorCornerTangentX - netHalfWidth)
        let a = cornerRadiusX
        let b = cornerRadiusY
        // A quarter of Ramanujan's ellipse perimeter.
        let corner = Double.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot()) / 4
        let rise = max(0, (ceilingY - cornerRadiusY) - (floorY + cornerRadiusY))
        // The wall's own length, which a lean stretches past its height.
        let wall = (rise * rise + wallInset * wallInset).squareRoot()
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

    /// The fraction of the path at which `share` of the straight side wall,
    /// measured up from the floor corner, ends.
    func wallPathFraction(ofWall share: Double) -> Double {
        let total = wallPathLength
        guard total > 0 else { return 0 }
        let pieces = wallPathPieces
        return (pieces.floor + pieces.corner + pieces.wall * min(1, max(0, share))) / total
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
        let floorTangent = floorCornerTangentX
        let along: Double
        if surface.y < lowArc, x < floorTangent {
            // The flat floor. Its end belongs to the corner.
            along = max(0, x - netHalfWidth)
        } else if surface.y < lowArc {
            let angle = atan2((x - floorTangent) / cornerRadiusX, (lowArc - surface.y) / cornerRadiusY)
            along = pieces.floor + pieces.corner * min(1, max(0, angle / quarter))
        } else if surface.y <= highArc {
            let share = highArc > lowArc ? (surface.y - lowArc) / (highArc - lowArc) : 0
            along = pieces.floor + pieces.corner + pieces.wall * share
        } else if x < cornerTangentX {
            // The flat roof, which the path never reaches. Its end belongs
            // to the corner, so the roof's end of the path still reads 1.
            return nil
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
                floorCornerTangentX + cornerRadiusX * sin(angle),
                floorY + cornerRadiusY - cornerRadiusY * cos(angle)
            )
        }
        along -= pieces.corner
        if along <= pieces.wall {
            let span = sideWallSpan
            let y = span.low + (span.high - span.low) * (pieces.wall > 0 ? along / pieces.wall : 0)
            return SIMD2(sideWallX(atY: y), y)
        }
        along -= pieces.wall
        let angle = min(1, along / max(pieces.corner, 0.000_001)) * quarter
        return SIMD2(
            cornerTangentX + cornerRadiusX * cos(angle),
            ceilingY - cornerRadiusY + cornerRadiusY * sin(angle)
        )
    }
}

public extension WorldState {
    /// True when `seat` playing the ball now would give the point away: its
    /// side's touches are spent, or its own run in a row is.
    func astroballTouchFaults(_ seat: Seat, tuning: AstroballTuning) -> Bool {
        let team = seat.team
        let side = ships.filter { $0.key.team == team && !$0.value.isDestroyed }.count
        if match.shipTouches[team] >= tuning.touchLimit(pilots: max(1, side)) { return true }
        return match.lastTouch == seat && match.lastTouchRun >= tuning.clampedInARow
    }

    /// The pilots who may play the ball next: those on the side whose half
    /// it is over, less any whose touch would fault. The court rings them,
    /// so a side of two can see whose ball it is.
    func astroballUp(tuning: AstroballTuning) -> [Seat] {
        let team = team(onHalfAt: ball.position.x)
        return ships.keys
            .filter { $0.team == team && ships[$0]?.isDestroyed == false && !astroballTouchFaults($0, tuning: tuning) }
            .sorted { $0.rawValue < $1.rawValue }
    }
}

/// A side's colour on screen. The rulebook only knows cyan and orange; these
/// are paint. Green and pink are ASTROPUCK's third and fourth pilots.
public enum TeamHue: Int, Codable, CaseIterable, Sendable {
    case cyan, orange, green, pink

    public var name: String {
        switch self {
        case .cyan: "CYAN"
        case .orange: "ORANGE"
        case .green: "GREEN"
        case .pink: "PINK"
        }
    }

    /// The lead's hull, and the colour the side is drawn in.
    public var rgb: SIMD3<Double> {
        switch self {
        case .cyan: SIMD3(0.0, 0.92, 1.0)
        case .orange: SIMD3(1.0, 0.45, 0.0)
        case .green: SIMD3(0.35, 1.0, 0.35)
        case .pink: SIMD3(1.0, 0.30, 0.75)
        }
    }

    /// The wing's paler hull on a side of two.
    public var wingRGB: SIMD3<Double> {
        switch self {
        case .cyan: SIMD3(0.45, 0.88, 1.0)
        case .orange: SIMD3(1.0, 0.65, 0.30)
        case .green: SIMD3(0.68, 1.0, 0.62)
        case .pink: SIMD3(1.0, 0.64, 0.88)
        }
    }
}

/// Which colour each side is painted this match.
public struct TeamHues: Equatable, Sendable, Codable {
    public var cyan: TeamHue = .cyan
    public var orange: TeamHue = .orange

    public init(cyan: TeamHue = .cyan, orange: TeamHue = .orange) {
        self.cyan = cyan
        self.orange = orange
    }

    public subscript(team: Team) -> TeamHue { team == .cyan ? cyan : orange }

    public func rgb(for seat: Seat) -> SIMD3<Double> {
        let hue = self[seat.team]
        return seat == .cyanWing || seat == .orangeWing ? hue.wingRGB : hue.rgb
    }

    /// Two different colours from the four, any order.
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> TeamHues {
        let picked = TeamHue.allCases.shuffled(using: &generator)
        return TeamHues(cyan: picked[0], orange: picked[1])
    }
}

public extension AstroballTuning {
    /// This tuning with a fresh pair of side colours, for a new match.
    func withRandomHues() -> AstroballTuning {
        var tuning = self
        var generator = SystemRandomNumberGenerator()
        tuning.hues = .random(using: &generator)
        return tuning
    }
}

/// What a hull touching the ASTROBALL net's upper half costs.
public enum NetTouch: String, Codable, CaseIterable, Sendable {
    /// Nothing: the net is only a wall.
    case off
    /// The hull's controls go dead for `SimulationEngine.netStunSeconds`.
    case stun
    /// The toucher's side loses the point.
    case point

    public var label: String {
        switch self {
        case .off: "Off"
        case .stun: "Stun"
        case .point: "Point"
        }
    }
}
