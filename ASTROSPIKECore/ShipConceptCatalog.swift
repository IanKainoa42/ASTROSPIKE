import Foundation
import simd

/// A ship design staged for the Hangar without assigning a sales channel.
/// These entries have no StoreKit product ID and do not alter gameplay.
public struct ShipConcept: Identifiable, Equatable, Sendable {
    public enum StorePlacement: String, Equatable, Sendable { case undecided }

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

/// One hundred actual cosmetic silhouettes. This is deliberately not a set of
/// paint jobs: five collections each use five different planforms, with four
/// structural variations per planform. They remain unassigned to a sales path.
public enum ShipConceptCatalog {
    private enum Collection: CaseIterable {
        case race, utility, bio, retro, cinema

        var role: String {
            switch self {
            case .race: "Interceptor / racer"
            case .utility: "Utility / freighter"
            case .bio: "Alien / bioform"
            case .retro: "Retro-future craft"
            case .cinema: "Original genre homage"
            }
        }

        var blurb: String {
            switch self {
            case .race: "A fast, tournament-ready silhouette."
            case .utility: "A hard-working ship with a completely different outline."
            case .bio: "An organic silhouette designed to look grown rather than built."
            case .retro: "A playful future imagined by old arcade cabinets and pulp covers."
            case .cinema: "An original silhouette that nods to space opera, animation, and arcade fiction without copying a named craft."
            }
        }
    }

    private static let names: [(Collection, [String])] = [
        (.race, [
            "Needle Wasp", "Redline", "Sparrowhawk", "Quickthorn", "Forkstar",
            "Crosswind", "Mistral", "Razorwing", "Kitebreak", "Vesper",
            "Lanceback", "Sunstreak", "Harrier", "Talons", "Pinwheel",
            "Gyroflash", "Twinflare", "Railbird", "Sickle", "Voltscythe",
        ]),
        (.utility, [
            "Dock Mule", "Pallet Jack", "Towline", "Porter", "Brickbird",
            "Hearth", "Waystation", "Habitat", "Freight Kite", "Lifeboat",
            "Railcar", "Pipe Dream", "Switchyard", "Lantern", "Surveyor",
            "Cratewing", "Moontruck", "Tanker", "Beacon", "Skylift",
        ]),
        (.bio, [
            "Manta Bloom", "Night Ray", "Tidewing", "Velvet Ray", "Scarab",
            "Stag Beetle", "Firebug", "Shellback", "Petalship", "Orchid",
            "Lotus", "Thornflower", "Spore", "Puffball", "Jellyknife",
            "Lanternfish", "Wyrm", "Cobra Coil", "Kestrel Moth", "Cicada",
        ]),
        (.retro, [
            "Orbit Saucer", "Bubbletop", "Saturnette", "Tin Comet", "Bottle Rocket",
            "Astro Sled", "Raygun", "Nova Pop", "Lunar Lander", "Tripod",
            "Survey Hopper", "Dust Devil", "Boomerang", "Space Banana", "Cosmic V",
            "Lucky Horseshoe", "Capsule", "Dartboard", "Chrome Egg", "Atomic Wedge",
        ]),
        (.cinema, [
            "Trench Runner", "Sunlance", "Void Viper", "Rebel Kite", "Mecha Sparrow",
            "Comet Frame", "Iron Petrel", "Star Ronin", "Pulp Pursuit", "Silver Scout",
            "Planetary Surveyor", "Rocket Detective", "Arcade Ace", "Pixel Raider", "Boss Beetle",
            "Neon Courier", "Laser Taxi", "Midnight Chaser", "Moon Palace", "Dream Skiff",
        ]),
    ]

    public static let all: [ShipConcept] = makeAll()

    private static func makeAll() -> [ShipConcept] {
        names.enumerated().flatMap { collectionIndex, entry in
            let collection = entry.0
            return entry.1.enumerated().map { index, name in
                ShipConcept(
                    id: String(format: "concept-%03d", collectionIndex * 20 + index + 1),
                    name: name,
                    role: collection.role,
                    blurb: collection.blurb,
                    outline: outline(collection: collection, planform: index % 5, variation: index / 5)
                )
            }
        }
    }

    private static func outline(collection: Collection, planform: Int, variation: Int) -> HullOutline {
        func p(_ x: Double, _ y: Double) -> SIMD2<Double> { SIMD2(x, y) }
        func points(_ values: [Double]) -> [SIMD2<Double>] {
            stride(from: 0, to: values.count, by: 2).map { p(values[$0], values[$0 + 1]) }
        }

        let base: [SIMD2<Double>]
        switch (collection, planform) {
        // Racing: needle, cross, diamond, twin boom and sickle.
        case (.race, 0): base = points([0,30, 3,15, 7,2, 14,-16, 5,-13, 0,-19, -5,-13, -14,-16, -7,2, -3,15])
        case (.race, 1): base = points([0,27, 6,12, 19,5, 15,-3, 7,-8, 12,-19, 0,-14, -12,-19, -7,-8, -15,-3, -19,5, -6,12])
        case (.race, 2): base = points([0,29, 9,13, 19,3, 11,-5, 7,-19, 0,-12, -7,-19, -11,-5, -19,3, -9,13])
        case (.race, 3): base = points([0,25, 6,18, 16,12, 21,-4, 13,-7, 17,-19, 6,-14, 0,-18, -6,-14, -17,-19, -13,-7, -21,-4, -16,12, -6,18])
        case (.race, _): base = points([0,28, 5,15, 18,9, 12,1, 19,-12, 7,-10, 0,-19, -7,-10, -19,-12, -12,1, -18,9, -5,15])
        // Utility: brick, cargo delta, rail, pod and lift frame.
        case (.utility, 0): base = points([-9,25, 9,25, 14,13, 12,0, 19,-5, 19,-18, 8,-18, 5,-10, -5,-10, -8,-18, -19,-18, -19,-5, -12,0, -14,13])
        case (.utility, 1): base = points([0,26, 9,20, 16,8, 21,0, 17,-9, 10,-6, 8,-19, 0,-15, -8,-19, -10,-6, -17,-9, -21,0, -16,8, -9,20])
        case (.utility, 2): base = points([-5,27, 5,27, 10,15, 8,-2, 16,-9, 16,-19, 7,-19, 0,-10, -7,-19, -16,-19, -16,-9, -8,-2, -10,15])
        case (.utility, 3): base = points([0,24, 12,17, 18,5, 16,-4, 21,-11, 13,-19, 5,-12, 0,-16, -5,-12, -13,-19, -21,-11, -16,-4, -18,5, -12,17])
        case (.utility, _): base = points([0,23, 10,19, 19,8, 18,-3, 12,-8, 17,-17, 7,-19, 0,-12, -7,-19, -17,-17, -12,-8, -18,-3, -19,8, -10,19])
        // Bioforms: ray, scarab, petal, spore and serpent.
        case (.bio, 0): base = points([0,25, 7,19, 21,3, 20,-8, 12,-11, 6,-19, 0,-13, -6,-19, -12,-11, -20,-8, -21,3, -7,19])
        case (.bio, 1): base = points([0,28, 8,20, 17,8, 19,-4, 13,-13, 5,-16, 0,-19, -5,-16, -13,-13, -19,-4, -17,8, -8,20])
        case (.bio, 2): base = points([0,24, 7,17, 18,12, 14,3, 20,-5, 10,-8, 8,-19, 0,-12, -8,-19, -10,-8, -20,-5, -14,3, -18,12, -7,17])
        case (.bio, 3): base = points([0,27, 11,17, 19,4, 14,-2, 20,-13, 10,-15, 0,-19, -10,-15, -20,-13, -14,-2, -19,4, -11,17])
        case (.bio, _): base = points([0,29, 6,18, 17,13, 18,0, 11,-5, 15,-16, 5,-12, 0,-18, -5,-12, -15,-16, -11,-5, -18,0, -17,13, -6,18])
        // Retro: saucer, rocket, lander, boomerang and capsule.
        case (.retro, 0): base = points([0,25, 12,20, 20,9, 21,-2, 14,-12, 6,-18, 0,-19, -6,-18, -14,-12, -21,-2, -20,9, -12,20])
        case (.retro, 1): base = points([0,30, 6,18, 17,3, 10,-5, 13,-19, 4,-13, 0,-18, -4,-13, -13,-19, -10,-5, -17,3, -6,18])
        case (.retro, 2): base = points([0,28, 7,17, 13,5, 21,-4, 13,-9, 15,-19, 6,-16, 0,-10, -6,-16, -15,-19, -13,-9, -21,-4, -13,5, -7,17])
        case (.retro, 3): base = points([0,23, 12,19, 21,8, 16,-1, 8,-5, 12,-17, 0,-12, -12,-17, -8,-5, -16,-1, -21,8, -12,19])
        case (.retro, _): base = points([0,26, 8,17, 18,7, 19,-5, 10,-10, 7,-19, 0,-15, -7,-19, -10,-10, -19,-5, -18,7, -8,17])
        // Original genre homages: space opera, animation, pulp, arcade, neon noir.
        case (.cinema, 0): base = points([0,30, 5,15, 16,9, 13,2, 21,-7, 12,-12, 8,-19, 0,-14, -8,-19, -12,-12, -21,-7, -13,2, -16,9, -5,15])
        case (.cinema, 1): base = points([0,27, 9,18, 20,4, 14,-1, 17,-15, 7,-12, 0,-19, -7,-12, -17,-15, -14,-1, -20,4, -9,18])
        case (.cinema, 2): base = points([0,25, 7,17, 18,10, 20,-2, 11,-6, 14,-19, 4,-14, 0,-18, -4,-14, -14,-19, -11,-6, -20,-2, -18,10, -7,17])
        case (.cinema, 3): base = points([0,29, 10,16, 17,3, 11,-3, 20,-12, 9,-11, 6,-19, 0,-13, -6,-19, -9,-11, -20,-12, -11,-3, -17,3, -10,16])
        case (.cinema, _): base = points([0,24, 11,18, 21,5, 16,-3, 9,-7, 13,-18, 4,-13, 0,-19, -4,-13, -13,-18, -9,-7, -16,-3, -21,5, -11,18])
        }

        // Variation changes wing span, nose height and the rear cut-out. Its
        // asymmetric offsets make each daily drop a separate outline even in
        // a shared planform family.
        let v = Double(variation)
        let silhouette = base.enumerated().map { index, point in
            let wingPoint = abs(point.x) > 10
            let x = point.x + (wingPoint ? (point.x.sign == .minus ? -v : v) : (index.isMultiple(of: 3) ? v * 0.45 : 0))
            let y = point.y + (point.y > 15 ? v * 0.8 : (point.y < -10 && index.isMultiple(of: 2) ? -v * 0.55 : 0))
            return p(max(-22, min(22, x)), max(-19, min(30, y)))
        }
        let detail = HullDetail([p(0, min(20 + v, 23)), p(0, -7 - v)], closed: false)
        return HullOutline(silhouette: silhouette, details: [detail])
    }
}
