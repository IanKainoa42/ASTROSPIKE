import Foundation

/// Counters a guest board uses to see how the link is behaving on-device.
/// Updated on the main actor from snapshot arrival; safe to read in the HUD.
public struct GuestIngressStats: Equatable, Sendable {
    public private(set) var snapshotsReceived: UInt64 = 0
    public private(set) var lastSnapshotTick: UInt64?
    /// Smoothed snapshots per second from recent arrivals.
    public private(set) var snapshotRateHz: Double = 0
    /// How far the guest's clock has run past the latest authoritative tick.
    public private(set) var bufferDepthTicks: UInt64 = 0
    private var recentArrivals: [TimeInterval] = []

    public init() {}

    public mutating func recordSnapshot(authoritativeTick: UInt64, guestTick: UInt64, at time: TimeInterval) {
        snapshotsReceived &+= 1
        lastSnapshotTick = authoritativeTick
        bufferDepthTicks = guestTick > authoritativeTick ? guestTick - authoritativeTick : 0
        recentArrivals.append(time)
        if recentArrivals.count > 8 { recentArrivals.removeFirst(recentArrivals.count - 8) }
        guard recentArrivals.count >= 2,
              let first = recentArrivals.first,
              let last = recentArrivals.last,
              last > first else { return }
        let span = last - first
        let arrivals = Double(recentArrivals.count - 1)
        snapshotRateHz = span > 0 ? arrivals / span : 0
    }

    public mutating func reset() {
        snapshotsReceived = 0
        lastSnapshotTick = nil
        snapshotRateHz = 0
        bufferDepthTicks = 0
        recentArrivals = []
    }
}
