import Foundation
import simd

/// Every hull a pilot can fly. Hulls are cosmetic: every hull meets the ball
/// with the same `ShipHitbox.shared`, so a Bulwark and a Lancet bounce it the
/// same way. This keeps online play fair and keeps hull unlocks review-safe.
public enum Hull: String, Codable, CaseIterable, Sendable, Identifiable {
    case lancet, anvil, manta, kestrel
    case bulwark, wraith, hornet, comet

    public var id: String { rawValue }

    /// The hull a team renders with until a pilot has chosen one.
    public static func defaultHull(for team: Team) -> Hull {
        team == .cyan ? .lancet : .anvil
    }

    /// Wings default to the other two free hulls so a doubles court reads
    /// as four different ships at a glance.
    public static func defaultHull(forSeat seat: Seat) -> Hull {
        switch seat {
        case .cyan: .lancet
        case .orange: .anvil
        case .cyanWing: .manta
        case .orangeWing: .kestrel
        }
    }

    public var spec: HullSpec { HullCatalog.spec(for: self) }
}

/// How a hull is obtained. Premium hulls carry the StoreKit product identifier
/// that will unlock them once in-app purchases ship; until then they render
/// locked in the hangar with no purchase path.
public enum HullAvailability: Equatable, Sendable {
    case free
    case premium(productID: String)

    public var productID: String? {
        if case let .premium(productID) = self { return productID }
        return nil
    }
}

public struct HullDetail: Equatable, Sendable {
    public var points: [SIMD2<Double>]
    public var closed: Bool

    public init(_ points: [SIMD2<Double>], closed: Bool) {
        self.points = points
        self.closed = closed
    }
}

/// Ship-frame geometry, +y toward the nose, in the same units the two
/// original hulls used so nothing else in the renderer needs to move.
public struct HullOutline: Equatable, Sendable {
    public var silhouette: [SIMD2<Double>]
    public var details: [HullDetail]

    public init(silhouette: [SIMD2<Double>], details: [HullDetail]) {
        self.silhouette = silhouette
        self.details = details
    }

    /// Every hull stays inside this box so no silhouette strays far from the
    /// shared hitbox it is flown with.
    public static let envelope = (minX: -22.0, maxX: 22.0, minY: -19.0, maxY: 30.0)

    public var fitsEnvelope: Bool {
        let all = silhouette + details.flatMap(\.points)
        return all.allSatisfy {
            $0.x >= Self.envelope.minX && $0.x <= Self.envelope.maxX
                && $0.y >= Self.envelope.minY && $0.y <= Self.envelope.maxY
        }
    }
}

/// Where the ball meets a hull: the drawn silhouette, at the size it is drawn.
/// Every hull shares the Lancet's shape unless a developer asks for each
/// hull's own (`SimulationEngine.shipHitboxes`).
public struct ShipHitbox: Equatable, Sendable {
    /// World units per outline unit. The arena draws hulls at this scale, so
    /// a hitbox built from an outline is the ship on screen.
    public static let worldPerOutlineUnit = 1.92 / (3.4 * 473)

    /// Padding around the outline the ball meets. At the bare outline a
    /// needle nose is so thin the pilot AI returned 1 ball in 16 (9 with the
    /// old circles); this much gives back 7 and still reads as touching.
    public static let skin = 0.016

    /// UserDefaults key for the developer toggle that gives each hull its own hitbox.
    public static let perHullKey = "hullShapedHitboxes"

    /// Every hull's hitbox by default: the original, the regular ship.
    public static let shared = ShipHitbox(HullCatalog.spec(for: .lancet).outline)

    /// Silhouette in the ship frame, world units: x along the nose, y to its left.
    public let polygon: [SIMD2<Double>]

    public init(_ outline: HullOutline) {
        let s = Self.worldPerOutlineUnit
        // Outline +y is the nose and +x is starboard; the renderer turns it
        // by `angle - pi/2`, which puts outline +x on the ship's right.
        polygon = outline.silhouette.map { SIMD2($0.y * s, -$0.x * s) }
    }

    /// How far the nose reaches ahead of the ship's centre, skin included.
    public var noseReach: Double { (polygon.map(\.x).max() ?? 0) + Self.skin }

    /// The farthest point of the hull from its centre: the circle other
    /// hulls and the arena's curved parts meet.
    public var reach: Double { polygon.map { simd_length($0) }.max() ?? 0 }

    /// How far the hull sticks out along a world `direction` when the ship
    /// is turned to `angle` -- what a flat wall meets.
    public func extent(along direction: SIMD2<Double>, angle: Double) -> Double {
        let axis = SIMD2(cos(angle), sin(angle))
        let left = SIMD2(-axis.y, axis.x)
        return polygon.map { simd_dot(axis * $0.x + left * $0.y, direction) }.max() ?? 0
    }

    /// First time in 0...1 a point moving from `start` to `end` (ship frame)
    /// comes within `radius` of the hull. Nil when it never does, or when it
    /// starts already inside -- the same rule the old circle fixtures kept.
    public func sweepTime(from start: SIMD2<Double>, to end: SIMD2<Double>, radius: Double) -> Double? {
        guard distance(from: start) > radius, !contains(start) else { return nil }
        let delta = end - start
        guard simd_dot(delta, delta) > 0.000_000_1 else { return nil }
        var earliest: Double?
        func consider(_ t: Double) {
            guard (0 ... 1).contains(t), earliest.map({ t < $0 }) ?? true else { return }
            earliest = t
        }
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            // The rounded end at the corner.
            let offset = start - a
            let qa = simd_dot(delta, delta)
            let qb = 2 * simd_dot(offset, delta)
            let qc = simd_dot(offset, offset) - radius * radius
            let discriminant = qb * qb - 4 * qa * qc
            if discriminant >= 0 { consider((-qb - discriminant.squareRoot()) / (2 * qa)) }
            // The flat face, pushed out by the radius on whichever side the
            // path starts.
            let edge = b - a
            let length = simd_length(edge)
            guard length > 0 else { continue }
            let along = edge / length
            let normal = SIMD2(-along.y, along.x)
            let startSide = simd_dot(offset, normal)
            let closing = simd_dot(delta, normal)
            let side: Double = startSide >= 0 ? 1 : -1
            guard closing * side < 0 else { continue }
            let t = (side * radius - startSide) / closing
            let hit = start + delta * t - a
            let projection = simd_dot(hit, along)
            if projection >= 0, projection <= length { consider(t) }
        }
        return earliest
    }

    /// The nearest point on the hull's outline.
    public func closestPoint(to point: SIMD2<Double>) -> SIMD2<Double> {
        var best = polygon[0]
        var bestDistance = Double.infinity
        for index in polygon.indices {
            let a = polygon[index]
            let edge = polygon[(index + 1) % polygon.count] - a
            let span = simd_dot(edge, edge)
            let t = span > 0 ? min(1, max(0, simd_dot(point - a, edge) / span)) : 0
            let candidate = a + edge * t
            let d = simd_distance(point, candidate)
            if d < bestDistance { bestDistance = d; best = candidate }
        }
        return best
    }

    func distance(from point: SIMD2<Double>) -> Double {
        simd_distance(point, closestPoint(to: point))
    }

    /// Even-odd point in polygon.
    func contains(_ point: SIMD2<Double>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

public struct HullSpec: Equatable, Sendable {
    public var hull: Hull
    public var name: String
    public var role: String
    public var blurb: String
    public var availability: HullAvailability
    /// Horizontal scale of the exhaust flame: needles burn tight, landers wide.
    public var exhaustWidth: Double
    public var outline: HullOutline

    public var isPremium: Bool { availability != .free }
}

public enum HullCatalog {
    public static let all: [HullSpec] = Hull.allCases.map(spec(for:))
    public static var free: [HullSpec] { all.filter { !$0.isPremium } }
    public static var premium: [HullSpec] { all.filter(\.isPremium) }

    public static func productID(for hull: Hull) -> String {
        "com.iankainoa.ASTROSPIKE.hull.\(hull.rawValue)"
    }

    public static func spec(for hull: Hull) -> HullSpec {
        switch hull {
        case .lancet:
            HullSpec(
                hull: hull, name: "Lancet", role: "Interceptor",
                blurb: "Raked needle nose, swept wings hooked forward at the tips, split tail. The original.",
                availability: .free, exhaustWidth: 0.75, outline: lancet
            )
        case .anvil:
            HullSpec(
                hull: hull, name: "Anvil", role: "Heavy lander",
                blurb: "Blunt chisel nose, boxy shoulders and two outboard engine pods hanging wide off the hull.",
                availability: .free, exhaustWidth: 1.9, outline: anvil
            )
        case .manta:
            HullSpec(
                hull: hull, name: "Manta", role: "Delta wing",
                blurb: "One broad blended wing with a notched trailing edge. Reads wide on the screen, flies the same.",
                availability: .free, exhaustWidth: 1.3, outline: manta
            )
        case .kestrel:
            HullSpec(
                hull: hull, name: "Kestrel", role: "Forward-swept",
                blurb: "Wings that sweep the wrong way, rooted at the tail and reaching for the nose.",
                availability: .free, exhaustWidth: 0.9, outline: kestrel
            )
        case .bulwark:
            HullSpec(
                hull: hull, name: "Bulwark", role: "Armoured brick",
                blurb: "A shield plate for a nose, welded seams down the hull and skids for engines.",
                availability: .premium(productID: productID(for: hull)), exhaustWidth: 2.1, outline: bulwark
            )
        case .wraith:
            HullSpec(
                hull: hull, name: "Wraith", role: "Stealth kite",
                blurb: "Faceted diamond planform with a chevron canopy. Nothing on it is a curve.",
                availability: .premium(productID: productID(for: hull)), exhaustWidth: 1.0, outline: wraith
            )
        case .hornet:
            HullSpec(
                hull: hull, name: "Hornet", role: "Twin boom",
                blurb: "A short central pod slung between two long engine booms with a porthole up front.",
                availability: .premium(productID: productID(for: hull)), exhaustWidth: 1.6, outline: hornet
            )
        case .comet:
            HullSpec(
                hull: hull, name: "Comet", role: "Pod racer",
                blurb: "Round pressure pod on three raked fins. The friendliest silhouette in the hangar.",
                availability: .premium(productID: productID(for: hull)), exhaustWidth: 1.2, outline: comet
            )
        }
    }

    // MARK: Outlines

    private static func p(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(x, y) }

    /// Cyan original: narrow interceptor.
    static let lancet = HullOutline(
        silhouette: [
            p(0, 30), p(3.5, 14), p(7, 1), p(21, -16), p(14, -19), p(6, -11), p(0, -15),
            p(-6, -11), p(-14, -19), p(-21, -16), p(-7, 1), p(-3.5, 14),
        ],
        details: [HullDetail([p(0, 16), p(0, 4)], closed: false)]
    )

    /// Orange original: heavy lander.
    static let anvil = HullOutline(
        silhouette: [
            p(-7, 26), p(7, 26), p(13, 12), p(11, -2), p(21, -4), p(22, -19), p(12, -19), p(9, -9),
            p(-9, -9), p(-12, -19), p(-22, -19), p(-21, -4), p(-11, -2), p(-13, 12),
        ],
        details: [HullDetail([p(0, 18), p(6, 13), p(6, 5), p(0, 0), p(-6, 5), p(-6, 13)], closed: true)]
    )

    static let manta = HullOutline(
        silhouette: [
            p(0, 24), p(5, 14), p(22, -10), p(22, -15), p(12, -13), p(6, -17), p(0, -11),
            p(-6, -17), p(-12, -13), p(-22, -15), p(-22, -10), p(-5, 14),
        ],
        details: [HullDetail([p(0, 15), p(3, 8), p(0, 1), p(-3, 8)], closed: true)]
    )

    static let kestrel = HullOutline(
        silhouette: [
            p(0, 30), p(4, 18), p(5, -2), p(21, 6), p(22, 0), p(6, -14), p(9, -19), p(0, -15),
            p(-9, -19), p(-6, -14), p(-22, 0), p(-21, 6), p(-5, -2), p(-4, 18),
        ],
        details: [HullDetail([p(0, 20), p(0, 8)], closed: false)]
    )

    static let bulwark = HullOutline(
        silhouette: [
            p(-11, 26), p(11, 26), p(15, 20), p(16, -4), p(20, -8), p(20, -19), p(10, -19), p(8, -12),
            p(-8, -12), p(-10, -19), p(-20, -19), p(-20, -8), p(-16, -4), p(-15, 20),
        ],
        details: [
            HullDetail([p(-4, 17), p(4, 17), p(4, 10), p(-4, 10)], closed: true),
            HullDetail([p(-8, 22), p(-8, -6)], closed: false),
            HullDetail([p(8, 22), p(8, -6)], closed: false),
        ]
    )

    static let wraith = HullOutline(
        silhouette: [
            p(0, 30), p(6, 14), p(19, 2), p(21, -6), p(10, -9), p(7, -19), p(0, -13),
            p(-7, -19), p(-10, -9), p(-21, -6), p(-19, 2), p(-6, 14),
        ],
        details: [HullDetail([p(-7, 5), p(0, 12), p(7, 5)], closed: false)]
    )

    static let hornet = HullOutline(
        silhouette: [
            p(0, 26), p(6, 14), p(7, 2), p(13, 4), p(21, 2), p(21, -19), p(13, -19), p(13, -6),
            p(7, -8), p(4, -13), p(0, -10), p(-4, -13), p(-7, -8), p(-13, -6), p(-13, -19),
            p(-21, -19), p(-21, 2), p(-13, 4), p(-7, 2), p(-6, 14),
        ],
        details: [HullDetail([p(0, 16), p(3.5, 14), p(3.5, 10), p(0, 8), p(-3.5, 10), p(-3.5, 14)], closed: true)]
    )

    static let comet = HullOutline(
        silhouette: [
            p(0, 24), p(8, 21), p(13, 15), p(15, 9), p(13, 2), p(10, -3), p(20, -19), p(11, -19),
            p(5, -12), p(3, -14), p(0, -19), p(-3, -14), p(-5, -12), p(-11, -19), p(-20, -19),
            p(-10, -3), p(-13, 2), p(-15, 9), p(-13, 15), p(-8, 21),
        ],
        details: [HullDetail([p(0, 16), p(3.5, 14.5), p(5, 11), p(3.5, 7.5), p(0, 6), p(-3.5, 7.5), p(-5, 11), p(-3.5, 14.5)], closed: true)]
    )
}

// MARK: - Persistence

/// Which premium hulls this Apple Account owns. Free hulls are always unlocked.
/// This is the offline cache, not the ledger: `HullStore` owns the StoreKit
/// side and calls `unlock(productID:)` / `lock(productID:)` as transactions
/// and revocations arrive.
@MainActor
@Observable
public final class HullEntitlements {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "unlockedHullProductIDs"

    public private(set) var unlockedProductIDs: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unlockedProductIDs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    public func isUnlocked(_ hull: Hull) -> Bool {
        switch hull.spec.availability {
        case .free: true
        case let .premium(productID): unlockedProductIDs.contains(productID)
        }
    }

    public func unlock(productID: String) {
        guard !unlockedProductIDs.contains(productID) else { return }
        unlockedProductIDs.insert(productID)
        persist()
    }

    /// Refunded or family-sharing-revoked. Only StoreKit calls this -- the
    /// cache never revokes on its own, so a cold launch cannot strip a hull
    /// the pilot paid for.
    public func lock(productID: String) {
        guard unlockedProductIDs.contains(productID) else { return }
        unlockedProductIDs.remove(productID)
        persist()
    }

    public func revokeAll() {
        unlockedProductIDs.removeAll()
        defaults.removeObject(forKey: Self.key)
    }

    private func persist() {
        defaults.set(unlockedProductIDs.sorted(), forKey: Self.key)
    }
}

/// The pilot's own choices: which hull they fly and whether they have been
/// through the intro. Lives in Core so tests can drive it with a scratch
/// `UserDefaults` suite.
@MainActor
@Observable
public final class PilotProfileStore {
    @ObservationIgnored private let defaults: UserDefaults
    private enum Keys {
        static let hull = "pilotHull"
        static let onboarded = "hasCompletedOnboarding"
    }

    public var selectedHull: Hull {
        didSet { defaults.set(selectedHull.rawValue, forKey: Keys.hull) }
    }

    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedHull = defaults.string(forKey: Keys.hull).flatMap(Hull.init(rawValue:)) ?? .lancet
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
    }

    /// The rival's hull for a solo match: a free hull that is not yours, so
    /// the two ships never read as twins.
    public func rivalHull(seed: UInt64 = UInt64.random(in: 0 ... .max)) -> Hull {
        let candidates = HullCatalog.free.map(\.hull).filter { $0 != selectedHull }
        guard !candidates.isEmpty else { return Hull.defaultHull(for: .orange) }
        return candidates[Int(seed % UInt64(candidates.count))]
    }
}
