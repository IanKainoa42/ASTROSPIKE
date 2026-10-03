import Foundation
import simd

/// Each hull's signature effects: the colours and shapes of its bolts, its
/// tractor beam, its flame and its smoke. Drawing only -- nothing here is
/// read by the simulation, so a premium hull's look can never be an edge.
/// The team still reads from the hull's own fill colour, which this leaves
/// alone.
public struct HullLook: Codable, Equatable, Sendable {
    /// What a bolt looks like in flight.
    public enum BoltShape: String, Codable, CaseIterable, Sendable {
        /// A long thin streak laid along its line.
        case needle
        /// A fat glowing slug shedding embers.
        case slug
        /// A flattened ellipse that wobbles as it flies.
        case wave
        /// An arrowhead pointing where it is going.
        case chevron
        /// A square that tumbles end over end.
        case block
        /// A diamond splinter that flickers.
        case shard
        /// Two small orbs side by side.
        case twin
        /// A round orb throwing sparkles.
        case orb
    }

    /// How the beam's tether and motes are drawn.
    public enum BeamPattern: String, Codable, CaseIterable, Sendable {
        /// Dashes racing down the tether toward the nose.
        case dashes
        /// A thick tether throbbing in slow beats.
        case pulses
        /// A wide, lazily waving tether and soft motes.
        case ripples
        /// Long dashes and arrowhead motes flowing in.
        case chevrons
        /// A thick hard tether and a heavy cone edge.
        case heavy
        /// A tether that cuts in and out.
        case glitch
        /// Two parallel tethers.
        case twin
        /// Twinkling motes and a glittering tether.
        case sparkle
    }

    /// What the engine leaves behind it.
    public enum SmokeStyle: String, Codable, CaseIterable, Sendable {
        /// Thin pale vapour.
        case vapour
        /// Heavy dark soot.
        case soot
        /// Hollow rings rising like bubbles.
        case bubbles
        /// Quick short-lived wisps.
        case wisps
        /// Glowing glitter that lights up instead of darkening.
        case glitter
    }

    /// The beam, the bolt halo, the tether. RGB, 0...1.
    public var primary: SIMD3<Double>
    /// Accents: bolt cores, mote highlights, sparks.
    public var secondary: SIMD3<Double>
    /// The lit plume.
    public var flame: SIMD3<Double>
    /// The white-hot tongue inside it.
    public var flameCore: SIMD3<Double>
    public var smoke: SIMD3<Double>
    public var bolt: BoltShape
    public var beam: BeamPattern
    public var smokeStyle: SmokeStyle
    /// Multiplies each puff's size.
    public var smokeSize: Double
    /// Multiplies how long each puff lingers.
    public var smokeLife: Double
    /// Multiplies how thick each puff is.
    public var smokeOpacity: Double
    /// Multiplies how many puffs the engine throws.
    public var smokeAmount: Double
    /// Multiplies the lit plume's length.
    public var flameLength: Double
    /// How far the hot core's length jumps frame to frame, 0...1.
    public var flicker: Double
    /// Nozzles side by side across the tail, 1...3.
    public var nozzles: Int
    /// Outline units between neighbouring nozzles.
    public var nozzleSpacing: Double
    /// Outline units: where the nozzles sit, below the centre.
    public var nozzleY: Double

    /// Each nozzle's x in outline units, centred on the keel.
    public var nozzleOffsets: [Double] {
        (0 ..< nozzles).map { (Double($0) - Double(nozzles - 1) / 2) * nozzleSpacing }
    }

    /// What a look may hold. The Ship Workshop's sliders stop at the same
    /// values (tools/ship-workshop/src/game-link.js), so nothing it exports can
    /// leave these.
    public static let limits = (
        smokeSize: 0.2 ... 3.0, smokeLife: 0.2 ... 3.0, smokeOpacity: 0.1 ... 2.0, smokeAmount: 0.0 ... 3.0,
        flameLength: 0.3 ... 2.5, flicker: 0.0 ... 0.5, nozzles: 1 ... 3, nozzleSpacing: 0.0 ... 40.0,
        nozzleY: -19.0 ... 0.0, exhaustWidth: 0.3 ... 3.0
    )
}

extension Hull {
    /// From `Ships.json`, edited in the Ship Workshop.
    public var look: HullLook { ShipDesigns.design(for: self).look }
}
