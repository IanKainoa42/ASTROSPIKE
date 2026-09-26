import Foundation
import simd

public enum WirePayload: Codable, Equatable, Sendable {
    case input(seat: Seat, value: PlayerInput)
    /// The sender's last few inputs, newest last. The channel is unreliable,
    /// so each packet repeats the ones before it: a single lost packet no
    /// longer leaves the host flying a pilot on an input they have let go of.
    case inputs(seat: Seat, values: [PlayerInput])
    case snapshot(WorldState)
    case event(SimulationEvent)
    case ready
    /// Which hull the sender flies, so the peers can draw it. Cosmetic only.
    case profile(seat: Seat, hull: Hull)
    /// The host's seating plan, Game Center player ID to seat, and the host's
    /// sliders, physics and format. Guests fly exactly this rather than
    /// negotiating or reading their own settings. `teamUp` is the host's
    /// call that its guests fly beside it: doubles, whoever turned up.
    case seating(plan: [String: Seat], tuning: FlightTuningSnapshot, teamUp: Bool)
    case ping(nanoseconds: UInt64)
    case resync(WorldState)
    /// The open table as its host keeps it: who flies the duel, who is on
    /// the bench in what order, and the night's wins. Sent whole on every
    /// change, and before every seating plan, so a pilot left out of the
    /// plan knows they are on the bench rather than lost.
    case table(OpenTable)
}

public struct WireEnvelope: Codable, Equatable, Sendable {
    // 4: MatchRuleState gained shipTouches and PointReason gained touchLimit.
    // 5: WirePayload gained profile(team:hull:).
    // 6: PlayerInput gained fire, ShipState gained fireCooldownTicks,
    //    WorldState gained bolts and nextBoltID.
    // 7: Ships, inputs and profiles keyed by Seat; seating payload for doubles.
    // 9: Host election is by role (inviter hosts, invitee never). A build 25
    //    invitee with a lower player ID seats itself as host too, so the two
    //    builds must refuse each other instead of silently double-hosting.
    // 10: seating carries setsToWin; a dropped pilot's chair is held for two
    //     minutes and a surviving guest takes over hosting, so a build 27
    //     peer would forfeit a match this build is still holding open.
    // 11: seating carries the host's whole FlightTuningSnapshot, not just
    //     setsToWin, so every board flies the host's sliders.
    // 12: PlayerInput gained tractor, ShipState gained tractorActive.
    // 13: ShipState gained ballTouchCooldownTicks -- a ball rattling between a
    //     hull and a wall now spends one touch instead of the whole allowance,
    //     so a build 51 peer would call a fault this build plays through.
    // 14: FlightTuningSnapshot gained tractorStrength, so the seating payload
    //     a build 58 peer sends no longer decodes -- and a guest that did
    //     decode it would fly a different beam from the host.
    // 15: the tractor beam conserves momentum -- reeling the ball in now
    //     pushes the hull toward it, and the grab damps the ball against the
    //     ship's frame rather than the world's. Both peers run the same
    //     deterministic engine, so a build 60 peer would decode every packet
    //     and then simulate a different rally from the same inputs.
    // 16: a bigger ball, thinner bolts that glance off an off-centre hit, and
    //     a ball wedged under a lip stays under it. Same reason: an older
    //     peer would step a different rally from the same inputs.
    // 17: the ball spins. A bolt that clips it off centre sets it turning,
    //     the spin bends its flight until the next thing it hits, and
    //     BallState carries it -- so a build 67 peer can neither decode the
    //     snapshot nor step the same rally.
    // 18: every surface grips the ball -- a bounce trades slide for spin and
    //     back, and a hull hands the ball its own motion. Same reason again:
    //     a build 68 peer would step a different rally from the same inputs.
    // 19: bolts are no longer touches and a hull on the far half spends none.
    //     A build 69 peer would call a touch fault this build plays through.
    // 20: teams change ends between sets. WorldState carries sidesSwapped
    //     and setBreak, and every floor, crossing and goal is scored by the
    //     team on that half rather than by its colour's old end.
    // 21: the ball's size is a slider, and it rides the wire with the rest
    //     of the host's tuning -- FlightTuningSnapshot carries ballRadius, so
    //     a build 77 peer cannot decode the seating plan at all, and the goal
    //     mouth is cut to the ball, so it would not score the same rally
    //     either.
    // 22: seating carries teamUp -- two friends can fly on the same side
    //     against bots, and a build 88 guest would seat itself in a duel.
    // 23: WorldState carries `balls`, an array, in place of one ball --
    //     doubles is played with two -- and a guest's engine follows the
    //     host's rulebook instead of keeping its own. A build 92 peer cannot
    //     decode a snapshot at all.
    // 24: the touch cap is gone -- a hull may play the ball as often as it
    //     likes, only the floor is a fault. FlightTuningSnapshot lost
    //     allowedTouchesPerSide and PointReason lost touchLimit, so a build
    //     93 peer cannot decode the seating plan, and one that could would
    //     call a fault this build plays through.
    // 25: open tables. WirePayload gained table(OpenTable), and a seating
    //     plan that leaves a pilot out now benches them to watch instead of
    //     being ignored -- a build 100 invitee would sit in the bay forever
    //     waiting for a seat the host is never going to give it.
    // 26: guest timing. Inputs travel in batches (inputs(seat:values:)), the
    //     host plays each on the tick it was sent for, and the guest runs a
    //     full round trip ahead. A build 25 host flies a guest's last input
    //     whatever its tick, so this guest would feel pulled around by it.
    // 27: open tables seat up to four. OpenTable gained both wings, so three
    //     pilots fly two against one and a bot. A build 26 guest would drop
    //     the wings from the table it is shown and put the wrong names on
    //     the court.
    public static let currentVersion: UInt16 = 27

    public var version: UInt16
    public var sequence: UInt64
    public var payload: WirePayload

    public init(
        version: UInt16 = WireEnvelope.currentVersion,
        sequence: UInt64,
        payload: WirePayload
    ) {
        self.version = version
        self.sequence = sequence
        self.payload = payload
    }
}

public enum WireProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case malformed
}

public struct WireCodec: Sendable {
    public init() {}

    public func encode(_ envelope: WireEnvelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    public func decode(_ data: Data) throws -> WireEnvelope {
        let envelope: WireEnvelope
        do {
            envelope = try PropertyListDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw WireProtocolError.malformed
        }
        guard envelope.version == WireEnvelope.currentVersion else {
            throw WireProtocolError.unsupportedVersion(envelope.version)
        }
        return envelope
    }
}

public struct RemoteInputBuffer: Sendable {
    public private(set) var latest: PlayerInput?
    /// When `latest` arrived, on the receiver's own clock.
    public private(set) var receivedAt: TimeInterval = 0
    /// Recent inputs, oldest first, one per tick. A guest runs ahead of the
    /// host, so its inputs arrive before the ticks they are for; the host
    /// plays each on its own tick instead of whatever came in last.
    private var recent: [PlayerInput] = []
    /// About a second of inputs at one every other tick.
    private static let depth = 64

    public init() {}

    /// Keeps an input. True when it is the newest yet; an older one that
    /// arrived out of order is still kept for its tick, but never replaces
    /// the newest.
    @discardableResult
    public mutating func accept(_ input: PlayerInput, at time: TimeInterval = 0) -> Bool {
        if !recent.contains(where: { $0.tick == input.tick }) {
            let index = recent.firstIndex { $0.tick > input.tick } ?? recent.endIndex
            recent.insert(input, at: index)
            if recent.count > Self.depth { recent.removeFirst(recent.count - Self.depth) }
        }
        guard latest == nil || input.tick > latest!.tick else { return false }
        latest = input
        receivedAt = time
        return true
    }

    /// What the pilot had under their thumb on `tick`: the newest input sent
    /// for that tick or before it, since a thumb holds between packets. Nil
    /// once the pilot has gone quiet, exactly as `current(at:expiringAfter:)`.
    public func input(forTick tick: UInt64, at time: TimeInterval, expiringAfter timeout: TimeInterval) -> PlayerInput? {
        guard latest != nil, time - receivedAt < timeout else { return nil }
        // Everything we hold is for later ticks: the earliest is the best
        // word there is on what they were doing.
        return recent.last { $0.tick <= tick } ?? recent.first
    }

    /// The pilot's last input, or nil once it is too old to fly by.
    ///
    /// A packet is a statement about one tick, not a standing order. Left to
    /// stand, the last packet from a pilot whose link died holds whatever
    /// they were doing when it died -- a burn into the roof that never lets
    /// up. Past the timeout the seat goes quiet and the ship coasts.
    public func current(at time: TimeInterval, expiringAfter timeout: TimeInterval) -> PlayerInput? {
        guard let latest, time - receivedAt < timeout else { return nil }
        return latest
    }
}

public struct AuthoritativeSnapshotGate: Sendable {
    private var latestTick: UInt64?

    public init() {}

    @discardableResult
    public mutating func accept(tick: UInt64) -> Bool {
        guard latestTick == nil || tick > latestTick! else { return false }
        latestTick = tick
        return true
    }

    public mutating func reset(to tick: UInt64? = nil) {
        latestTick = tick
    }
}

public struct MonotonicSequenceGate: Sendable {
    private var latestSequence: UInt64?

    public init() {}

    @discardableResult
    public mutating func accept(sequence: UInt64) -> Bool {
        guard latestSequence == nil || sequence > latestSequence! else { return false }
        latestSequence = sequence
        return true
    }

    public mutating func reset() {
        latestSequence = nil
    }
}

public struct StateReconciler: Sendable {
    public var snapDistance: Double
    public var blendFraction: Double

    public init(snapDistance: Double = 0.30, blendFraction: Double = 0.25) {
        self.snapDistance = snapDistance
        self.blendFraction = max(0, min(1, blendFraction))
    }

    public func reconcile(predicted: ShipState, authoritative: ShipState) -> ShipState {
        guard simd_distance(predicted.position, authoritative.position) <= snapDistance else {
            return authoritative
        }
        let retained = 1 - blendFraction
        return ShipState(
            position: predicted.position * retained + authoritative.position * blendFraction,
            velocity: predicted.velocity * retained + authoritative.velocity * blendFraction,
            angle: predicted.angle * retained + authoritative.angle * blendFraction,
            angularVelocity: predicted.angularVelocity * retained
                + authoritative.angularVelocity * blendFraction,
            isDestroyed: authoritative.isDestroyed,
            thrustLevel: authoritative.thrustLevel,
            homeSide: authoritative.homeSide,
            fireCooldownTicks: authoritative.fireCooldownTicks,
            ballTouchCooldownTicks: authoritative.ballTouchCooldownTicks
        )
    }
}
