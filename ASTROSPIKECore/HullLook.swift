import Foundation
import simd

/// Each hull's signature effects: the colours and shapes of its bolts, its
/// tractor beam, its flame and its smoke. Drawing only -- nothing here is
/// read by the simulation, so a premium hull's look can never be an edge.
/// The team still reads from the hull's own fill colour, which this leaves
/// alone.
public struct HullLook: Equatable, Sendable {
    /// What a bolt looks like in flight.
    public enum BoltShape: CaseIterable, Sendable {
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
    public enum BeamPattern: CaseIterable, Sendable {
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
    public enum SmokeStyle: Sendable {
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
    /// Multiplies the lit plume's length.
    public var flameLength: Double
    /// How far the hot core's length jumps frame to frame, 0...1.
    public var flicker: Double
    /// Two nozzles side by side, for a twin-boom hull.
    public var twinNozzles: Bool
}

extension Hull {
    public var look: HullLook {
        switch self {
        case .lancet:
            // Ion: electric blue, needle bolts, a fast clean jet.
            HullLook(
                primary: [0.35, 0.75, 1.0], secondary: [0.9, 0.97, 1.0],
                flame: [0.45, 0.7, 1.0], flameCore: [0.92, 0.97, 1.0], smoke: [0.72, 0.8, 0.92],
                bolt: .needle, beam: .dashes, smokeStyle: .vapour,
                smokeSize: 0.7, smokeLife: 0.8, smokeOpacity: 0.6,
                flameLength: 1.25, flicker: 0.1, twinNozzles: false
            )
        case .anvil:
            // Forge: molten orange, slugs, a wide amber burn and soot.
            HullLook(
                primary: [1.0, 0.45, 0.12], secondary: [1.0, 0.85, 0.3],
                flame: [1.0, 0.5, 0.12], flameCore: [1.0, 0.88, 0.55], smoke: [0.26, 0.24, 0.24],
                bolt: .slug, beam: .pulses, smokeStyle: .soot,
                smokeSize: 1.35, smokeLife: 1.3, smokeOpacity: 1.3,
                flameLength: 0.9, flicker: 0.25, twinNozzles: false
            )
        case .manta:
            // Tide: teal into deep blue, waves, bubbles.
            HullLook(
                primary: [0.15, 1.0, 0.75], secondary: [0.2, 0.45, 1.0],
                flame: [0.2, 0.9, 0.85], flameCore: [0.8, 1.0, 0.95], smoke: [0.45, 0.75, 0.8],
                bolt: .wave, beam: .ripples, smokeStyle: .bubbles,
                smokeSize: 0.9, smokeLife: 1.1, smokeOpacity: 0.9,
                flameLength: 1.0, flicker: 0.15, twinNozzles: false
            )
        case .kestrel:
            // Raptor: gold, arrowheads, a sharp flickering flame.
            HullLook(
                primary: [1.0, 0.8, 0.25], secondary: [1.0, 0.97, 0.85],
                flame: [1.0, 0.72, 0.2], flameCore: [1.0, 0.95, 0.75], smoke: [0.62, 0.58, 0.5],
                bolt: .chevron, beam: .chevrons, smokeStyle: .wisps,
                smokeSize: 0.75, smokeLife: 0.7, smokeOpacity: 0.8,
                flameLength: 1.15, flicker: 0.35, twinNozzles: false
            )
        case .bulwark:
            // Iron: red and steel, tumbling blocks, thick black smoke.
            HullLook(
                primary: [1.0, 0.22, 0.2], secondary: [0.75, 0.8, 0.88],
                flame: [1.0, 0.3, 0.15], flameCore: [1.0, 0.75, 0.6], smoke: [0.17, 0.17, 0.19],
                bolt: .block, beam: .heavy, smokeStyle: .soot,
                smokeSize: 1.5, smokeLife: 1.2, smokeOpacity: 1.4,
                flameLength: 0.85, flicker: 0.12, twinNozzles: false
            )
        case .wraith:
            // Phantom: violet and magenta, shards, a beam that glitches.
            HullLook(
                primary: [0.72, 0.38, 1.0], secondary: [1.0, 0.35, 0.85],
                flame: [0.6, 0.3, 1.0], flameCore: [0.95, 0.8, 1.0], smoke: [0.3, 0.2, 0.4],
                bolt: .shard, beam: .glitch, smokeStyle: .wisps,
                smokeSize: 0.8, smokeLife: 0.55, smokeOpacity: 0.9,
                flameLength: 0.95, flicker: 0.4, twinNozzles: false
            )
        case .hornet:
            // Stinger: lime and yellow, twin everything off the twin booms.
            HullLook(
                primary: [0.72, 1.0, 0.2], secondary: [1.0, 0.95, 0.2],
                flame: [0.75, 1.0, 0.25], flameCore: [0.95, 1.0, 0.8], smoke: [0.5, 0.55, 0.4],
                bolt: .twin, beam: .twin, smokeStyle: .vapour,
                smokeSize: 0.8, smokeLife: 1.0, smokeOpacity: 0.9,
                flameLength: 1.05, flicker: 0.2, twinNozzles: true
            )
        case .comet:
            // Stardust: pink and white, sparkling orbs, glitter.
            HullLook(
                primary: [1.0, 0.42, 0.8], secondary: [1.0, 1.0, 1.0],
                flame: [1.0, 0.5, 0.85], flameCore: [1.0, 0.9, 0.97], smoke: [1.0, 0.6, 0.9],
                bolt: .orb, beam: .sparkle, smokeStyle: .glitter,
                smokeSize: 0.8, smokeLife: 1.0, smokeOpacity: 0.7,
                flameLength: 1.1, flicker: 0.2, twinNozzles: false
            )
        }
    }
}
