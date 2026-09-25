import Foundation
import simd

/// A ship design staged for the Hangar without assigning a sales channel.
///
/// These entries deliberately have no StoreKit product ID and do not change
/// gameplay. A later merchandising decision can promote any entry to a free
/// hull, an in-app purchase, or another store surface without rewriting the
/// design list.
public struct ShipConcept: Identifiable, Equatable, Sendable {
    public enum StorePlacement: String, Equatable, Sendable {
        /// Intentionally not a pricing or storefront decision.
        case undecided
    }

    public let id: String
    public let name: String
    public let role: String
    public let blurb: String
    public let outline: HullOutline
    public let storePlacement: StorePlacement

    init(id: String, name: String, role: String, blurb: String, outline: HullOutline) {
        self.id = id
        self.name = name
        self.role = role
        self.blurb = blurb
        self.outline = outline
        storePlacement = .undecided
    }
}

/// One hundred cosmetic hull concepts. They are intentionally separate from
/// `HullCatalog`: current matches, saved profiles, and StoreKit products keep
/// their existing contract until a concept is explicitly promoted.
public enum ShipConceptCatalog {
    public static let all: [ShipConcept] = makeAll()

    private struct Frame {
        let name: String
        let role: String
        let blurb: String
        let nose: Double
        let wing: Double
        let tail: Double
    }

    private struct Finish {
        let name: String
        let blurb: String
        let canopy: Double
        let sweep: Double
    }

    private static let frames: [Frame] = [
        .init(name: "Arrowglass", role: "Needle interceptor", blurb: "a glassy dart with a precision nose", nose: 30, wing: 9, tail: 12),
        .init(name: "Bastion", role: "Shield lander", blurb: "a plated carrier with a broad forward shield", nose: 25, wing: 20, tail: 18),
        .init(name: "Crescent", role: "Arc wing", blurb: "a moon-cut wing wrapped around a compact fuselage", nose: 27, wing: 22, tail: 10),
        .init(name: "Driftfin", role: "Sail skimmer", blurb: "a tall sailplane body with low outriggers", nose: 29, wing: 16, tail: 20),
        .init(name: "Ember", role: "Torch racer", blurb: "a hot rod pod with flared exhaust roots", nose: 26, wing: 14, tail: 22),
        .init(name: "Farsight", role: "Survey craft", blurb: "a long-eye scout with a calm, narrow spine", nose: 28, wing: 12, tail: 16),
        .init(name: "Glaive", role: "Blade fighter", blurb: "a sharp-edged cutter with a forked keel", nose: 30, wing: 18, tail: 14),
        .init(name: "Harbor", role: "Dock runner", blurb: "a friendly utility shell with stable shoulders", nose: 24, wing: 21, tail: 19),
        .init(name: "Iris", role: "Orbital courier", blurb: "a petal-like courier built around a bright canopy", nose: 26, wing: 19, tail: 13),
        .init(name: "Javelin", role: "Spearship", blurb: "a pure straight-line sprinter with a split engine rail", nose: 30, wing: 11, tail: 17),
    ]

    private static let finishes: [Finish] = [
        .init(name: "Aurora", blurb: "and aurora-panel wing tips", canopy: 8, sweep: 0),
        .init(name: "Brimstone", blurb: "and heat-scarred venting", canopy: 5, sweep: 3),
        .init(name: "Citadel", blurb: "and layered defensive ribs", canopy: 6, sweep: -2),
        .init(name: "Daybreak", blurb: "and a sunrise canopy", canopy: 10, sweep: 2),
        .init(name: "Eclipse", blurb: "and a hidden dark-glass cockpit", canopy: 4, sweep: -4),
        .init(name: "Firefly", blurb: "and tiny luminous engine marks", canopy: 9, sweep: 4),
        .init(name: "Ghostline", blurb: "and a clean ghost-white centerline", canopy: 3, sweep: -1),
        .init(name: "Halo", blurb: "and a ringed observation canopy", canopy: 11, sweep: 1),
        .init(name: "Ion", blurb: "and charged blue intake seams", canopy: 7, sweep: 5),
        .init(name: "Juniper", blurb: "and organic leaf-like panel cuts", canopy: 12, sweep: -5),
    ]

    private static func makeAll() -> [ShipConcept] {
        frames.enumerated().flatMap { frameIndex, frame in
            finishes.enumerated().map { finishIndex, finish in
                let number = frameIndex * finishes.count + finishIndex + 1
                return ShipConcept(
                    id: String(format: "concept-%03d", number),
                    name: "\(frame.name) \(finish.name)",
                    role: frame.role,
                    blurb: "\(frame.blurb) \(finish.blurb).",
                    outline: outline(frame: frame, finish: finish)
                )
            }
        }
    }

    /// A deterministic, distinct top-down cosmetic outline for every frame /
    /// finish pairing. All points remain inside `HullOutline.envelope`.
    private static func outline(frame: Frame, finish: Finish) -> HullOutline {
        func p(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(x, y) }
        let nose = min(30, frame.nose)
        let wing = min(22, frame.wing)
        let tail = min(19, frame.tail)
        let sweep = finish.sweep
        return HullOutline(
            silhouette: [
                p(0, nose), p(4 + finish.canopy / 5, nose - 10),
                p(wing, 2 + sweep), p(wing - 2, -6), p(wing, -tail),
                p(7, -tail + 3), p(0, -12 - finish.canopy / 3),
                p(-7, -tail + 3), p(-wing, -tail), p(-wing + 2, -6),
                p(-wing, 2 + sweep), p(-4 - finish.canopy / 5, nose - 10),
            ],
            details: [
                HullDetail([p(0, nose - 8), p(finish.canopy / 2, nose - 15), p(0, nose - 19), p(-finish.canopy / 2, nose - 15)], closed: true),
                HullDetail([p(-wing * 0.55, -8), p(wing * 0.55, -8)], closed: false),
            ]
        )
    }
}
