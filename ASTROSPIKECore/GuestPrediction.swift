import Foundation

// How a guest keeps its own ship under its thumb while the host keeps the
// book. The guest runs its clock ahead of the host's by a round trip, so the
// input it sends for tick T reaches the host before the host plays T. The
// host plays every input on the tick it was meant for. And when a snapshot
// lands, the guest re-runs everything since that snapshot with the inputs it
// really sent -- so, the network being quiet, the snapshot and the guest's
// own prediction agree and its ship never moves under it.
//
// All of it is here rather than beside the arena so it can be run with a
// fake network in a test, which is the only way to see it without phones.

/// A steadied round-trip time. A ping is one sample a second and a single
/// slow one is noise; steering the guest's clock by every sample made the
/// lead jump about with it.
public struct RoundTripEstimator: Equatable, Sendable {
    /// How much of each new sample is taken in.
    public static let weight = 0.2

    public private(set) var milliseconds: Double?

    public init() {}

    public mutating func record(_ sample: Double) {
        guard sample >= 0 else { return }
        milliseconds = milliseconds.map { $0 + (sample - $0) * Self.weight } ?? sample
    }

    /// The round trip in simulation ticks, rounded up. Zero before the first
    /// sample: the guest then leads by the margin alone.
    public func ticks(stepsPerSecond: Double = 120) -> UInt64 {
        guard let milliseconds else { return 0 }
        return UInt64((milliseconds * stepsPerSecond / 1000).rounded(.up))
    }

    public mutating func reset() { milliseconds = nil }
}

/// Where a guest's clock should be when a snapshot lands.
public enum GuestClock {
    /// Ticks of headroom on top of the round trip, so an input that is a
    /// little late on the wire still arrives before its tick is played.
    public static let margin: UInt64 = 4
    /// How far past its target the guest may drift before it is eased back.
    public static let slack: UInt64 = 6
    /// The longest lead ever asked for, whatever the round trip claims.
    public static let maximumLead: UInt64 = 90

    /// How far ahead of a snapshot the guest should be. The snapshot left
    /// the host half a round trip ago, and the guest's input needs half a
    /// round trip more to reach it: a whole round trip in all, plus margin.
    /// It used to be half a round trip, which put the guest level with the
    /// host's present rather than ahead of it, so every input it sent landed
    /// late and every snapshot dragged its ship back.
    public static func lead(roundTripTicks: UInt64) -> UInt64 {
        min(roundTripTicks + margin, maximumLead)
    }

    /// The tick the guest carries on from after this snapshot.
    ///
    /// A guest that has fallen behind jumps forward. One that has run too far
    /// ahead -- after a burst of lag it no longer needs -- steps back a single
    /// tick per snapshot, which nobody can see, rather than all at once.
    /// Anywhere between, it keeps its own count: a clock renumbered on every
    /// snapshot is a clock that stutters.
    public static func target(predicted: UInt64, authoritative: UInt64, roundTripTicks: UInt64) -> UInt64 {
        let desired = authoritative + lead(roundTripTicks: roundTripTicks)
        if predicted + 1 < desired { return desired }
        if predicted > desired + slack { return predicted - 1 }
        return predicted
    }
}

/// A guest's answer to a snapshot: the host's world, run forward to the
/// guest's own clock with the inputs the guest really gave.
public enum GuestRollForward {
    /// The most ticks a snapshot is ever re-run. Rolling forward costs about
    /// a microsecond a tick, so this is about a slow network, not the CPU:
    /// the old cap of 24 was shorter than a middling round trip, and past it
    /// every snapshot threw the guest back in time.
    public static let maximumTicks: UInt64 = 120

    public struct Resolution {
        /// The world to carry on from.
        public var state: WorldState
        /// The bots, stepped through the same ticks.
        public var bots: [Seat: AIController]
        /// How far the guest's own ship was from where the host's world put
        /// it, before the two were blended. Zero is the goal.
        public var localCorrection: Double
        /// The guest's clock moved, so what it did at its old tick numbers
        /// says nothing about the new ones.
        public var renumbered: Bool
    }

    /// - Parameters:
    ///   - authoritative: the host's snapshot.
    ///   - predicted: what the guest has on its own board right now.
    ///   - target: the tick to roll forward to, from `GuestClock`.
    ///   - flownSeat: the seat the guest's thumb flies, nil on the bench.
    ///   - localInput: what the guest sent for a tick.
    ///   - remoteInput: what another pilot sent for a tick, or their last word.
    public static func resolve(
        authoritative: WorldState,
        predicted: WorldState,
        target: UInt64,
        configuration: SimulationConfiguration,
        arena: ArenaGeometry,
        flownSeat: Seat?,
        bots: [Seat: AIController],
        localInput: (UInt64) -> PlayerInput,
        remoteInput: (Seat, UInt64) -> PlayerInput
    ) -> Resolution {
        var rolled = SimulationEngine(state: authoritative, configuration: configuration, arena: arena)
        rolled.followsHost = true
        var bots = bots
        let ahead = target >= authoritative.tick ? target - authoritative.tick : 0
        if ahead <= maximumTicks, [.serve, .playing].contains(authoritative.match.phase) {
            while rolled.state.tick < target {
                let tick = rolled.state.tick
                var inputs: [Seat: PlayerInput] = [:]
                if let flownSeat { inputs[flownSeat] = localInput(tick) }
                for seat in rolled.state.ships.keys where seat != flownSeat {
                    if var bot = bots[seat] {
                        inputs[seat] = bot.input(for: rolled.state, seat: seat, tick: tick)
                        bots[seat] = bot
                    } else {
                        inputs[seat] = remoteInput(seat, tick)
                    }
                }
                rolled.step(inputs: inputs)
            }
        }
        var resolved = rolled.state
        var correction = 0.0
        if let flownSeat, let mine = predicted.ships[flownSeat], let hostShip = resolved.ships[flownSeat] {
            let gap = mine.position - hostShip.position
            correction = (gap.x * gap.x + gap.y * gap.y).squareRoot()
            resolved.ships[flownSeat] = StateReconciler().reconcile(predicted: mine, authoritative: hostShip)
        }
        return Resolution(
            state: resolved,
            bots: bots,
            localCorrection: correction,
            renumbered: resolved.tick != predicted.tick
        )
    }
}
