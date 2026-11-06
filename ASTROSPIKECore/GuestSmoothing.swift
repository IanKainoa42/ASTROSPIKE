import Foundation
import simd

/// Hides the guest's snapshot corrections of the rival ship and the Bumpers
/// pegs. Drawn raw, each arrival is a visible hop. The difference between
/// what was on screen and the corrected state is kept as an offset that
/// decays over a few frames, so the picture slides onto the truth rather
/// than jumping. A correction bigger than `snapDistance` is a real desync
/// and snaps.
///
/// The ball is not slid. It is what the guest hits: a picture that eases
/// onto the host's ball while the hull meets the corrected one is a whiff
/// the host never has to make. The local ship is left alone too -- prediction
/// and reconciliation own it.
public struct GuestSmoothing: Sendable {
    public var decayRate: Double
    public var snapDistance: Double
    private var shipOffsets: [Seat: SIMD2<Double>] = [:]
    /// Along each peg's track: a rival's shove or haul is only known to this
    /// board when the host's snapshot says so.
    private var bumperOffsets: [SIMD2<Double>] = []

    public init(decayRate: Double = 14, snapDistance: Double = 0.25) {
        self.decayRate = decayRate
        self.snapDistance = snapDistance
    }

    public var bumperError: Double { bumperOffsets.map(simd_length).max() ?? 0 }

    /// Records the gap between the frame on screen and the corrected state.
    /// The local ship is left alone: prediction and reconciliation own it.
    /// The ball is left alone too: the picture and the contact have to be
    /// the same ball.
    public mutating func capture(displayed: WorldState, corrected: WorldState, excluding local: Seat?) {
        bumperOffsets = corrected.bumpers.indices.map { index in
            guard index < displayed.bumpers.count else { return .zero }
            let offset = displayed.bumpers[index].offset - corrected.bumpers[index].offset
            return simd_length(offset) > snapDistance ? .zero : offset
        }
        for (seat, ship) in corrected.ships where seat != local {
            guard let shown = displayed.ships[seat] else { continue }
            shipOffsets[seat] = clamped(shown.position - ship.position)
        }
    }

    public mutating func decay(dt: Double) {
        let factor = exp(-decayRate * max(0, dt))
        for seat in shipOffsets.keys { shipOffsets[seat]! *= factor }
        for index in bumperOffsets.indices { bumperOffsets[index] *= factor }
    }

    public mutating func reset() {
        shipOffsets = [:]
        bumperOffsets = []
    }

    public func apply(to state: WorldState) -> WorldState {
        var shown = state
        for (seat, offset) in shipOffsets { shown.ships[seat]?.position += offset }
        for (index, offset) in bumperOffsets.enumerated() where index < shown.bumpers.count {
            shown.bumpers[index].offset += offset
        }
        return shown
    }

    private func clamped(_ offset: SIMD2<Double>) -> SIMD2<Double> {
        simd_length(offset) > snapDistance ? .zero : offset
    }
}
