import Foundation
import simd

/// One ship's drawing: its outline, its flame width and its look. Nothing
/// here decides who owns it or what it costs -- that stays in `HullCatalog`.
public struct ShipDesign: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var blurb: String
    /// Horizontal scale of the exhaust flame: needles burn tight, landers wide.
    public var exhaustWidth: Double
    public var outline: HullOutline
    public var look: HullLook
}

/// Every ship the game can draw -- the eight hulls, then the hundred concepts
/// in catalogue order -- read from `Ships.json` in this framework. The Ship
/// Workshop (ShipWorkshop/) seeds from the same file and exports it back;
/// `scripts/import-ships.py` checks an export and writes it here.
public struct ShipDesignFile: Codable, Equatable, Sendable {
    public static let schemaName = "astro-ships"

    public var schema: String
    public var version: Int
    public var hulls: [ShipDesign]
    public var concepts: [ShipDesign]
}

public enum ShipDesigns {
    public static let file: ShipDesignFile = {
        // A bundled file, not user data: if it is missing or malformed the
        // build is broken, and the Core tests load it first.
        guard let url = Bundle(for: BundleToken.self).url(forResource: "Ships", withExtension: "json") else {
            fatalError("Ships.json is missing from ASTROSPIKECore")
        }
        do {
            return try JSONDecoder().decode(ShipDesignFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Ships.json does not decode: \(error)")
        }
    }()

    private static let hullsByID = Dictionary(uniqueKeysWithValues: file.hulls.map { ($0.id, $0) })

    public static func design(for hull: Hull) -> ShipDesign {
        guard let design = hullsByID[hull.rawValue] else { fatalError("Ships.json has no hull \(hull.rawValue)") }
        return design
    }
}

private final class BundleToken {}
