import Foundation

public enum OnlineSessionPhase: Equatable, Sendable {
    case playing
    case reconnecting(deadlineTick: UInt64)
    case forfeited(winner: Team)
}

public enum OnlineSessionAction: Equatable, Sendable {
    case pause
    case requestFullResync
    case startCountdown
    case forfeit(winner: Team)
}

public struct OnlineSessionStateMachine: Equatable, Sendable {
    public private(set) var phase: OnlineSessionPhase = .playing

    private let localTeam: Team
    private let reconnectWindowTicks: UInt64

    public init(localTeam: Team, ticksPerSecond: UInt64) {
        self.localTeam = localTeam
        reconnectWindowTicks = ticksPerSecond * 10
    }

    public mutating func remoteDisconnected(at tick: UInt64) -> [OnlineSessionAction] {
        guard case .playing = phase else { return [] }
        phase = .reconnecting(deadlineTick: tick + reconnectWindowTicks)
        return [.pause]
    }

    public mutating func advance(to tick: UInt64) -> [OnlineSessionAction] {
        guard case let .reconnecting(deadlineTick) = phase,
              tick >= deadlineTick else {
            return []
        }

        phase = .forfeited(winner: localTeam)
        return [.forfeit(winner: localTeam)]
    }

    public mutating func remoteReconnected(at tick: UInt64) -> [OnlineSessionAction] {
        guard case let .reconnecting(deadlineTick) = phase,
              tick < deadlineTick else {
            return advance(to: tick)
        }

        phase = .playing
        return [.requestFullResync, .startCountdown]
    }
}
