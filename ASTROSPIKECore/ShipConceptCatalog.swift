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
    public let exhaustWidth: Double
    public let look: HullLook
    public let storePlacement: StorePlacement

    init(_ design: ShipDesign) {
        id = design.id
        name = design.name
        role = design.role
        blurb = design.blurb
        outline = design.outline
        exhaustWidth = design.exhaustWidth
        look = design.look
        storePlacement = .undecided
    }
}

/// One hundred cosmetic silhouettes from `Ships.json`, in five collections
/// of twenty. Ian redraws them in the Ship Workshop before any is released;
/// they remain unassigned to a sales path.
public enum ShipConceptCatalog {
    public static let all: [ShipConcept] = ShipDesigns.file.concepts.map(ShipConcept.init)
}
