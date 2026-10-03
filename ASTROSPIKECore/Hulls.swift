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

public struct HullDetail: Codable, Equatable, Sendable {
    public var points: [SIMD2<Double>]
    public var closed: Bool

    public init(_ points: [SIMD2<Double>], closed: Bool) {
        self.points = points
        self.closed = closed
    }
}

/// Ship-frame geometry, +y toward the nose, in the same units the two
/// original hulls used so nothing else in the renderer needs to move.
public struct HullOutline: Codable, Equatable, Sendable {
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

    /// Names, outlines and flame widths come from `Ships.json`; who may fly
    /// a hull stays here, so the workshop can never make a premium hull free.
    public static func spec(for hull: Hull) -> HullSpec {
        guard let spec = specs[hull] else { fatalError("No spec for \(hull)") }
        return spec
    }

    private static let specs: [Hull: HullSpec] = Dictionary(uniqueKeysWithValues: Hull.allCases.map { hull in
        let design = ShipDesigns.design(for: hull)
        let spec = HullSpec(
            hull: hull, name: design.name, role: design.role, blurb: design.blurb,
            availability: availability(for: hull), exhaustWidth: design.exhaustWidth, outline: design.outline
        )
        return (hull, spec)
    })

    private static func availability(for hull: Hull) -> HullAvailability {
        switch hull {
        case .lancet, .anvil, .manta, .kestrel: .free
        case .bulwark, .wraith, .hornet, .comet: .premium(productID: productID(for: hull))
        }
    }
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
