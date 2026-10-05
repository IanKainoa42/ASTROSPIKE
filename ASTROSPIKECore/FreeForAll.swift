import Foundation

// Free-for-all: three or four pilots down one long field, one roof-hung goal
// each. There are no halves and no teams -- every other hull is a rival --
// and nobody scores points. A ball through either face of your goal costs
// you a life; lose them all and your goal turns solid and your ship leaves
// the field. The last pilot flying wins.
//
// The engine keeps this book itself, like the hoop court, and a duel never
// carries one: `WorldState.freeForAll` is nil, and nil is the switch.

public struct FreeForAllState: Codable, Equatable, Sendable {
    /// Lives each pilot starts with.
    public static let startingLives = 5

    /// The order seats take the bays, left to right. The two leads hold the
    /// ends and the wings fill the middle, so the duel's two colours keep
    /// the same ends of the field they always had.
    public static let bayOrder: [Seat] = [.cyan, .cyanWing, .orangeWing, .orange]

    /// The seats for a field of `pilots`: you, then rivals, never more than
    /// the four seats there are.
    public static func seats(pilots: Int) -> Set<Seat> {
        switch pilots {
        case ...2: [.cyan, .orange]
        case 3: [.cyan, .cyanWing, .orange]
        default: Set(Seat.allCases)
        }
    }

    /// `bays[i]` owns goal `i`, counting goals left to right.
    public var bays: [Seat]
    public var lives: [Seat: Int]
    /// Set once one pilot is left flying.
    public var winner: Seat?
    /// The goal the next serve drops from: the one that just conceded, or
    /// the nearest one still in play.
    public var serveBay: Int

    public init(seats: Set<Seat>, lives: Int = startingLives) {
        bays = Self.bayOrder.filter(seats.contains)
        self.lives = Dictionary(uniqueKeysWithValues: bays.map { ($0, lives) })
        winner = nil
        // The first ball drops from the middle of the field, nearest nobody
        // in particular, rather than under the leftmost pilot's own goal.
        serveBay = bays.count / 2
    }

    public func isOut(_ seat: Seat) -> Bool { (lives[seat] ?? 0) <= 0 }

    /// Pilots still flying, left to right.
    public var standing: [Seat] { bays.filter { !isOut($0) } }

    public func owner(ofGoal index: Int) -> Seat? {
        bays.indices.contains(index) ? bays[index] : nil
    }

    public func bay(of seat: Seat) -> Int? { bays.firstIndex(of: seat) }

    /// A goal with nobody left to defend it is closed: the ball bounces off
    /// its faces like the collar above every mouth.
    public func isSolid(goal index: Int) -> Bool {
        owner(ofGoal: index).map(isOut) ?? true
    }

    /// The bay still in play nearest `index`, for the serve after a goal
    /// that knocked its owner out.
    public func nearestOpenBay(to index: Int) -> Int {
        bays.indices
            .filter { !isSolid(goal: $0) }
            .min { abs($0 - index) < abs($1 - index) } ?? index
    }
}

/// A bot for the free-for-all field. The duel bot already knows how to put
/// a ball through a goal on a duel court, so this hands it one: the rival
/// goal nearest the ball, with the field shifted so that goal hangs at the
/// middle of a standard court, the bot's own ship the only hull in it, and
/// the bot's home half whichever side of that goal the ball is on.
///
/// Known gap: it attacks and never defends. Its own goal is only covered
/// when the ball happens to be nearer someone else's.
public struct FreeForAllPilot: Sendable {
    /// How much nearer the ball a new goal must be before the bot gives up
    /// the one it is working on, so a ball midway between two goals does not
    /// make it dither.
    static let targetHysteresis = 0.10
    /// How far past the middle of its target the ball must go before the
    /// bot switches sides of it, for the same reason.
    static let sideHysteresis = 0.15

    public let difficulty: AIDifficulty
    private var configuration: SimulationConfiguration
    private var controller: AIController
    private var targetGoal: Int?
    private var homeSide: Team = .cyan

    public init(difficulty: AIDifficulty, configuration: SimulationConfiguration) {
        self.difficulty = difficulty
        self.configuration = configuration
        controller = Self.makeController(difficulty: difficulty, configuration: configuration)
    }

    /// The duel court the bot is shown: the standard one, as wide as the real
    /// wall on the ball's side of the goal is far.
    private static func makeController(
        difficulty: AIDifficulty,
        configuration: SimulationConfiguration,
        wallDistance: Double = ArenaGeometry.standard.halfWidth
    ) -> AIController {
        var court = ArenaGeometry.standard(ballRadius: configuration.ballRadius)
        court.halfWidth = wallDistance
        var controller = AIController(
            difficulty: difficulty,
            configuration: configuration,
            arena: court
        )
        controller.freeRoam = true
        return controller
    }

    public mutating func updateConfiguration(_ configuration: SimulationConfiguration) {
        self.configuration = configuration
        controller.updateConfiguration(configuration)
    }

    public mutating func input(for state: WorldState, seat: Seat, arena: ArenaGeometry, tick: UInt64) -> PlayerInput {
        guard let field = state.freeForAll, let ship = state.ships[seat],
              let goal = chooseGoal(state: state, field: field, seat: seat, arena: arena) else {
            return .idle(tick: tick)
        }
        let centre = arena.goalCentres[goal]
        // The bot plays from whichever side of the goal the ball is on, and
        // shoots it through the face on that side. Free-for-all has no
        // halves, so it simply flies under the goal to get there.
        let ballOffset = state.ball.position.x - centre
        var side = homeSide
        if goal != targetGoal {
            side = ballOffset < 0 ? .cyan : .orange
        } else {
            if side == .cyan, ballOffset > Self.sideHysteresis { side = .orange }
            if side == .orange, ballOffset < -Self.sideHysteresis { side = .cyan }
        }
        if goal != targetGoal || side != homeSide {
            targetGoal = goal
            homeSide = side
            let wall = side == .cyan ? centre + arena.halfWidth : arena.halfWidth - centre
            controller = Self.makeController(difficulty: difficulty, configuration: configuration, wallDistance: wall)
        }
        return controller.input(for: Self.view(of: state, seat: seat, ship: ship, centre: centre, homeSide: homeSide), seat: seat, tick: tick)
    }

    /// The rival goal still open that is nearest the ball, sticking with the
    /// current one unless another is clearly nearer.
    private func chooseGoal(state: WorldState, field: FreeForAllState, seat: Seat, arena: ArenaGeometry) -> Int? {
        let ballX = state.ball.position.x
        let open = arena.goalCentres.indices.filter { index in
            !field.isSolid(goal: index) && field.owner(ofGoal: index) != seat
        }
        guard let nearest = open.min(by: { abs(arena.goalCentres[$0] - ballX) < abs(arena.goalCentres[$1] - ballX) }) else {
            return nil
        }
        if let current = targetGoal, open.contains(current),
           abs(arena.goalCentres[current] - ballX) <= abs(arena.goalCentres[nearest] - ballX) + Self.targetHysteresis {
            return current
        }
        return nearest
    }

    /// The field as a duel court around one goal: everything shifted so the
    /// goal is at x = 0, and nobody else flying.
    static func view(of state: WorldState, seat: Seat, ship: ShipState, centre: Double, homeSide: Team) -> WorldState {
        let shift = SIMD2(centre, 0.0)
        var copy = state
        var own = ship
        own.position -= shift
        own.homeSide = homeSide
        copy.ships = [seat: own]
        for index in copy.balls.indices { copy.balls[index].position -= shift }
        for index in copy.bolts.indices { copy.bolts[index].position -= shift }
        copy.bumpers = []
        copy.freeForAll = nil
        copy.sidesSwapped = false
        return copy
    }
}
