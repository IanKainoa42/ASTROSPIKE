import Foundation
import Testing
@testable import ASTROSPIKECore

/// A host and a guest joined by a fake network: every packet takes
/// `latency` ticks to arrive, and a share of the guest's input packets never do.
/// This is the guest's side of an online match with the phones taken out,
/// so how far its own ship is pulled about can be measured instead of felt.
private struct Netplay {
    enum Scheme {
        /// How it shipped: the host flies a guest's last input whatever its
        /// tick, the guest leads a snapshot by half a round trip, samples its
        /// thumb every tick, and rolls forward at most 24 ticks.
        case legacy
        /// Round-trip lead, inputs played on their own tick in batches, and
        /// the thumb sampled on the ticks it is sent.
        case current
    }

    let scheme: Scheme
    let latency: Int
    /// The share of the guest's input packets that never arrive.
    let loss: Double

    private(set) var host: SimulationEngine
    private(set) var guest: SimulationEngine
    private var hostSeesGuest = RemoteInputBuffer()
    private var guestSeesHost = RemoteInputBuffer()
    private var guestHistory: [UInt64: PlayerInput] = [:]
    private var guestSent: [PlayerInput] = []
    private var toHost: [(at: Int, inputs: [PlayerInput])] = []
    private var toGuest: [(at: Int, inputs: [PlayerInput])] = []
    private var snapshots: [(at: Int, state: WorldState)] = []
    /// A fixed-seed generator, so a lossy run loses the same packets every
    /// time -- and not in step with the send schedule, which a plain
    /// "every nth packet" does.
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private(set) var corrections: [Double] = []

    init(scheme: Scheme, latency: Int, loss: Double = 0) {
        self.scheme = scheme
        self.latency = latency
        self.loss = loss
        var engine = SimulationEngine.testing()
        let configuration = SimulationConfiguration()
        engine.updateConfiguration(configuration)
        engine.updateArena(ArenaGeometry.standard(ballRadius: configuration.ballRadius))
        engine.configureRoster(Seat.singles)
        engine.beginPlay()
        host = engine
        guest = SimulationEngine(state: engine.state, configuration: engine.configuration, arena: engine.arena)
        guest.followsHost = true
    }

    /// Two pilots weaving about their own halves, on a schedule so every run
    /// flies the same. A function of the tick, so the same tick always means
    /// the same thumb.
    private static func thumb(_ tick: UInt64, phase: Double) -> PlayerInput {
        let t = Double(tick)
        return PlayerInput(
            tick: tick,
            torque: sin(t / 23 + phase) * 0.9,
            thrust: (tick / 17 + UInt64(phase * 10)) % 3 != 0
        )
    }

    private var roundTripTicks: UInt64 { UInt64(2 * latency) }
    private var now: TimeInterval { Double(host.state.tick) / 120 }

    private mutating func lost() -> Bool {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53) < loss
    }

    mutating func run(ticks: Int, warmUp: Int) {
        for clock in 0 ..< ticks {
            deliver(at: clock, measuring: clock >= warmUp)
            stepGuest(at: clock)
            stepHost(at: clock)
        }
    }

    private mutating func deliver(at clock: Int, measuring: Bool) {
        for packet in toHost where packet.at == clock {
            for input in packet.inputs { hostSeesGuest.accept(input, at: now) }
        }
        toHost.removeAll { $0.at <= clock }
        for packet in toGuest where packet.at == clock {
            for input in packet.inputs { guestSeesHost.accept(input, at: now) }
        }
        toGuest.removeAll { $0.at <= clock }
        for snapshot in snapshots where snapshot.at == clock {
            receive(snapshot.state, measuring: measuring)
        }
        snapshots.removeAll { $0.at <= clock }
    }

    private func hostInput(_ tick: UInt64) -> PlayerInput {
        switch scheme {
        case .legacy: guestSeesHost.current(at: now, expiringAfter: 0.5) ?? .idle(tick: tick)
        case .current: guestSeesHost.input(forTick: tick, at: now, expiringAfter: 0.5) ?? .idle(tick: tick)
        }
    }

    private mutating func stepGuest(at clock: Int) {
        let tick = guest.state.tick
        // The current scheme flies what it sends: the thumb as of the last
        // sent tick. The old one sampled every tick and sent every other.
        let sampled = scheme == .current ? tick - tick % 2 : tick
        let thumb = Self.thumb(sampled, phase: 1.3)
        let input = PlayerInput(tick: tick, torque: thumb.torque, thrust: thumb.thrust)
        guestHistory[tick] = input
        guest.step(inputs: [.orange: input, .cyan: hostInput(tick)])
        guard tick.isMultiple(of: 2) else { return }
        guestSent.append(input)
        if guestSent.count > 3 { guestSent.removeFirst() }
        let batch = scheme == .current ? guestSent : [input]
        if !lost() { toHost.append((clock + latency, batch)) }
    }

    private mutating func stepHost(at clock: Int) {
        let tick = host.state.tick
        let fromGuest: PlayerInput = switch scheme {
        case .legacy: hostSeesGuest.current(at: now, expiringAfter: 0.5) ?? .idle(tick: tick)
        case .current: hostSeesGuest.input(forTick: tick, at: now, expiringAfter: 0.5) ?? .idle(tick: tick)
        }
        let mine = Self.thumb(tick - tick % 2, phase: 0)
        host.step(inputs: [.cyan: PlayerInput(tick: tick, torque: mine.torque, thrust: mine.thrust), .orange: fromGuest])
        if tick.isMultiple(of: 2) { toGuest.append((clock + latency, [mine])) }
        if tick.isMultiple(of: 6) { snapshots.append((clock + latency, host.state)) }
    }

    private mutating func receive(_ snapshot: WorldState, measuring: Bool) {
        let predicted = guest.state
        let target: UInt64
        let maximum: UInt64
        switch scheme {
        case .legacy:
            let lead = min(24, UInt64(latency) + 3)
            target = max(predicted.tick, snapshot.tick + lead)
            maximum = 24
        case .current:
            target = GuestClock.target(predicted: predicted.tick, authoritative: snapshot.tick, roundTripTicks: roundTripTicks)
            maximum = GuestRollForward.maximumTicks
        }
        guard target - snapshot.tick <= maximum else {
            // Too far behind to roll: the old code snapped to the host.
            if measuring, let mine = predicted.ships[.orange], let theirs = snapshot.ships[.orange] {
                let gap = mine.position - theirs.position
                corrections.append((gap.x * gap.x + gap.y * gap.y).squareRoot())
            }
            guest = SimulationEngine(state: snapshot, configuration: guest.configuration, arena: guest.arena)
            guest.followsHost = true
            return
        }
        let history = guestHistory
        let hostSees = guestSeesHost
        let now = now
        let scheme = scheme
        let resolution = GuestRollForward.resolve(
            authoritative: snapshot,
            predicted: predicted,
            target: target,
            configuration: guest.configuration,
            arena: guest.arena,
            flownSeat: .orange,
            bots: [:],
            localInput: { history[$0] ?? .idle(tick: $0) },
            remoteInput: { _, tick in
                switch scheme {
                case .legacy: hostSees.current(at: now, expiringAfter: 0.5) ?? .idle(tick: tick)
                case .current: hostSees.input(forTick: tick, at: now, expiringAfter: 0.5) ?? .idle(tick: tick)
                }
            }
        )
        if measuring { corrections.append(resolution.localCorrection) }
        guest = SimulationEngine(state: resolution.state, configuration: guest.configuration, arena: guest.arena)
        guest.followsHost = true
    }
}

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

@Suite("Guest prediction")
struct GuestPredictionTests {
    @Test("On a clean link the guest's own ship is never pulled back")
    func cleanLinkNeedsNoCorrection() {
        // 100 ms each way: a 200 ms round trip, ordinary for Game Center.
        var link = Netplay(scheme: .current, latency: 12)
        link.run(ticks: 2400, warmUp: 360)
        #expect(!link.corrections.isEmpty)
        #expect((link.corrections.max() ?? 1) < 0.001, "largest correction \(link.corrections.max() ?? -1)")
    }

    @Test("The old timing pulled the guest's ship about on the same link")
    func legacyTimingCorrectedConstantly() {
        var legacy = Netplay(scheme: .legacy, latency: 12)
        legacy.run(ticks: 2400, warmUp: 360)
        var current = Netplay(scheme: .current, latency: 12)
        current.run(ticks: 2400, warmUp: 360)
        #expect(mean(legacy.corrections) > 0.01, "legacy mean \(mean(legacy.corrections))")
        #expect(mean(current.corrections) * 50 < mean(legacy.corrections))
    }

    @Test("A slow link past the old 24-tick cap still rolls forward")
    func slowLinkStillRollsForward() {
        // 175 ms each way: the old code snapped back to the host on every
        // snapshot here.
        var link = Netplay(scheme: .current, latency: 21)
        link.run(ticks: 2400, warmUp: 480)
        #expect((link.corrections.max() ?? 1) < 0.001, "largest correction \(link.corrections.max() ?? -1)")
    }

    @Test("A lost input packet is covered by the next one")
    func lostPacketsAreCovered() {
        // One input packet in five never arrives -- a rough cellular link.
        // Each packet repeats the two before it, so a tick is only lost when
        // three packets in a row are.
        var link = Netplay(scheme: .current, latency: 12, loss: 0.2)
        link.run(ticks: 2400, warmUp: 360)
        var legacy = Netplay(scheme: .legacy, latency: 12, loss: 0.2)
        legacy.run(ticks: 2400, warmUp: 360)
        #expect(mean(link.corrections) < 0.002, "mean correction \(mean(link.corrections))")
        #expect(mean(link.corrections) * 10 < mean(legacy.corrections))
    }

    @Test("The host plays each input on the tick it was sent for")
    func inputsArePlayedOnTheirTick() {
        var buffer = RemoteInputBuffer()
        buffer.accept(PlayerInput(tick: 10, torque: 1, thrust: false), at: 0)
        buffer.accept(PlayerInput(tick: 14, torque: -1, thrust: true), at: 0)
        // Tick 12 is still under the tick-10 thumb, though 14 has arrived.
        #expect(buffer.input(forTick: 12, at: 0, expiringAfter: 0.5)?.tick == 10)
        #expect(buffer.input(forTick: 14, at: 0, expiringAfter: 0.5)?.tick == 14)
        #expect(buffer.input(forTick: 99, at: 0, expiringAfter: 0.5)?.tick == 14)
        // Before anything for the tick arrived, the earliest word we have.
        #expect(buffer.input(forTick: 3, at: 0, expiringAfter: 0.5)?.tick == 10)
        // Quiet for too long: nothing, as with the latest input.
        #expect(buffer.input(forTick: 14, at: 0.6, expiringAfter: 0.5) == nil)
    }

    @Test("An input that arrives out of order still counts for its tick")
    func reorderedInputFillsItsTick() {
        var buffer = RemoteInputBuffer()
        buffer.accept(PlayerInput(tick: 14, torque: -1, thrust: true), at: 0)
        let late = buffer.accept(PlayerInput(tick: 12, torque: 0.5, thrust: false), at: 0)
        #expect(!late)
        #expect(buffer.latest?.tick == 14)
        #expect(buffer.input(forTick: 13, at: 0, expiringAfter: 0.5)?.tick == 12)
    }

    @Test("The guest leads a snapshot by a whole round trip")
    func guestLeadsByARoundTrip() {
        #expect(GuestClock.lead(roundTripTicks: 24) == 24 + GuestClock.margin)
        #expect(GuestClock.lead(roundTripTicks: 10_000) == GuestClock.maximumLead)
        // Behind: jump to the lead.
        #expect(GuestClock.target(predicted: 100, authoritative: 100, roundTripTicks: 24) == 128)
        // Near it: keep counting, never renumber for a tick of jitter.
        #expect(GuestClock.target(predicted: 127, authoritative: 100, roundTripTicks: 24) == 127)
        #expect(GuestClock.target(predicted: 133, authoritative: 100, roundTripTicks: 24) == 133)
        // Far past it: ease back one tick.
        #expect(GuestClock.target(predicted: 150, authoritative: 100, roundTripTicks: 24) == 149)
    }

    @Test("One slow ping does not swing the round trip")
    func roundTripIsSteadied() {
        var estimator = RoundTripEstimator()
        #expect(estimator.ticks() == 0)
        estimator.record(200)
        #expect(estimator.ticks() == 24)
        estimator.record(1000)
        // A fifth of the way to the spike, not all of it.
        #expect(estimator.milliseconds == 360)
        estimator.reset()
        #expect(estimator.milliseconds == nil)
    }

    @Test("A batch of inputs survives the wire")
    func inputBatchRoundTrip() throws {
        let envelope = WireEnvelope(sequence: 3, payload: .inputs(seat: .orange, values: [
            PlayerInput(tick: 8, torque: 0.5, thrust: true),
            PlayerInput(tick: 10, torque: -0.25, thrust: false, fire: true),
        ]))
        #expect(try WireCodec().decode(WireCodec().encode(envelope)) == envelope)
    }
}
