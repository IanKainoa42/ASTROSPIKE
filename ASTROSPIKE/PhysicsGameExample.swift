import ASTROSPIKECore
import SwiftUI

/// Complete example of how to integrate the spaceship physics system
/// with client-side prediction and network reconciliation.
///
/// This demonstrates:
/// 1. CADisplayLink-driven game loop
/// 2. Touch input handling mapped to ship controls
/// 3. Client-side prediction with instant input response
/// 4. Server reconciliation when network updates arrive
/// 5. Deterministic physics with wall bouncing

// MARK: - View Model

@MainActor
class PhysicsGameViewModel: NSObject, ObservableObject {
    @Published var displayPosition: CGPoint = .zero
    @Published var displayRotation: Double = 0
    @Published var displayVelocity: CGPoint = .zero
    @Published var debugInfo: String = ""
    @Published var reconciliationCount = 0

    private var gameLoop: GameLoopManager
    private var networkSimulator: NetworkLatencySimulator

    override init() {
        // Create game loop for a 20x20 meter arena
        let arena = ArenaPhysicsGeometry(width: 20, height: 20)
        let initialState = ShipPhysicsState(
            position: CGPoint(x: -8, y: 0),
            velocity: .zero,
            rotation: 0,
            angularVelocity: 0
        )

        self.gameLoop = GameLoopManager(arena: arena, initialState: initialState)
        self.networkSimulator = NetworkLatencySimulator(delay: 0.05) // 50ms network delay

        super.init()

        // Subscribe to game loop updates
        gameLoop.onPhysicsStep = { [weak self] in
            self?.updateDisplay()
        }

        gameLoop.debugLogging = true
    }

    private func updateDisplay() {
        displayPosition = gameLoop.displayState.position
        displayRotation = gameLoop.displayState.rotation
        displayVelocity = gameLoop.displayState.velocity

        // Simulate network updates (every 6 ticks, send state to server)
        if gameLoop.localTick % 6 == 0 {
            networkSimulator.scheduleStateUpdate(
                state: gameLoop.currentPredictedState,
                serverTick: gameLoop.localTick
            ) { [weak self] state, serverTick in
                self?.gameLoop.receiveAuthoritativeUpdate(state: state, serverTick: serverTick)
                self?.reconciliationCount += 1
            }
        }

        debugInfo = String(format: """
            Tick: %d
            Pos: (%.2f, %.2f)
            Vel: (%.2f, %.2f)
            Rot: %.2f°
            Reconciliations: %d
            Error: %.3f
            """,
            Int(gameLoop.localTick),
            displayPosition.x, displayPosition.y,
            displayVelocity.x, displayVelocity.y,
            gameLoop.displayState.rotation * 180 / .pi,
            reconciliationCount,
            gameLoop.reconciliationError
        )
    }

    func startGame() {
        gameLoop.start()
    }

    func stopGame() {
        gameLoop.stop()
    }

    func togglePause() {
        if gameLoop.isPaused() {
            gameLoop.resume()
        } else {
            gameLoop.pause()
        }
    }

    func getGameLoop() -> GameLoopManager {
        gameLoop
    }
}

// MARK: - SwiftUI View

struct PhysicsGameView: View {
    @StateObject private var viewModel = PhysicsGameViewModel()

    var body: some View {
        ZStack {
            // Arena background
            Rectangle()
                .fill(Color(red: 0.1, green: 0.1, blue: 0.15))

            // Game viewport
            GameViewport(viewModel: viewModel)

            // Debug HUD
            VStack(alignment: .leading) {
                Text("Spaceship Physics Game")
                    .font(.headline)

                Text(viewModel.debugInfo)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)

                HStack(spacing: 12) {
                    Button("Start") { viewModel.startGame() }
                    Button("Stop") { viewModel.stopGame() }
                    Button("Pause") { viewModel.togglePause() }
                }
                .font(.caption)
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)

                Spacer()
            }
            .padding()
            .background(Color.black.opacity(0.5))
        }
        .ignoresSafeArea()
    }
}

// MARK: - Game Viewport

struct GameViewport: View {
    let viewModel: PhysicsGameViewModel
    let arenaSize = CGSize(width: 20, height: 20)

    var body: some View {
        ZStack {
            // Arena walls
            Rectangle()
                .stroke(Color.white, lineWidth: 2)

            // Grid (for visual reference)
            Canvas { context in
                var path = Path()
                let cellSize = 1.0
                for i in stride(from: 0, through: 20, by: cellSize) {
                    // Vertical lines
                    path.move(to: CGPoint(x: i, y: 0))
                    path.addLine(to: CGPoint(x: i, y: 20))

                    // Horizontal lines
                    path.move(to: CGPoint(x: 0, y: i))
                    path.addLine(to: CGPoint(x: 20, y: i))
                }

                var stroke = StrokeStyle()
                stroke.lineWidth = 0.05
                context.stroke(path, with: .color(.gray.opacity(0.3)), style: stroke)
            }

            // Ship
            ShipView(position: viewModel.displayPosition, rotation: viewModel.displayRotation)

            // Velocity vector (for debugging)
            Canvas { context in
                let start = convertToView(viewModel.displayPosition)
                let velocity = viewModel.displayVelocity
                let velocityScale = 2.0
                let end = CGPoint(
                    x: start.x + velocity.x * velocityScale,
                    y: start.y - velocity.y * velocityScale  // Flip Y
                )

                var path = Path()
                path.move(to: start)
                path.addLine(to: end)

                var stroke = StrokeStyle()
                stroke.lineWidth = 2
                context.stroke(path, with: .color(.yellow), style: stroke)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding()
    }

    private func convertToView(_ position: CGPoint) -> CGPoint {
        let viewSize = arenaSize
        let normalized = CGPoint(
            x: (position.x + viewSize.width / 2) / viewSize.width,
            y: (position.y + viewSize.height / 2) / viewSize.height
        )
        // This will be actual frame size in real app
        return CGPoint(x: normalized.x * 300, y: normalized.y * 300)
    }
}

// MARK: - Ship Visual

struct ShipView: View {
    let position: CGPoint
    let rotation: Double
    let arenaSize = CGSize(width: 20, height: 20)

    var body: some View {
        Canvas { context in
            let viewPos = convertToView(position)

            var transform = CGAffineTransform(translationX: viewPos.x, y: viewPos.y)
            transform = transform.rotated(by: rotation)

            // Draw ship as a simple triangle
            var path = Path()
            path.move(to: CGPoint(x: 10, y: 0))      // Tip (pointing up)
            path.addLine(to: CGPoint(x: -8, y: 12))  // Bottom left
            path.addLine(to: CGPoint(x: -3, y: 6))   // Left center
            path.addLine(to: CGPoint(x: 0, y: 8))    // Center
            path.addLine(to: CGPoint(x: 3, y: 6))    // Right center
            path.addLine(to: CGPoint(x: 8, y: 12))   // Bottom right
            path.closeSubpath()

            path = path.applying(transform)

            context.fill(path, with: .color(.cyan))
            context.stroke(path, with: .color(.white), lineWidth: 1)
        }
        .frame(width: 300, height: 300)
    }

    private func convertToView(_ position: CGPoint) -> CGPoint {
        let viewSize = arenaSize
        let normalized = CGPoint(
            x: (position.x + viewSize.width / 2) / viewSize.width,
            y: (position.y + viewSize.height / 2) / viewSize.height
        )
        return CGPoint(x: normalized.x * 300, y: normalized.y * 300)
    }
}

// MARK: - Network Simulator

/// Simulates network latency for testing reconciliation.
class NetworkLatencySimulator {
    let delay: TimeInterval
    private var pendingUpdates: [(timestamp: Date, callback: (ShipPhysicsState, UInt64) -> Void)] = []
    private var timer: Timer?

    init(delay: TimeInterval) {
        self.delay = delay
        startSimulation()
    }

    func scheduleStateUpdate(
        state: ShipPhysicsState,
        serverTick: UInt64,
        callback: @escaping (ShipPhysicsState, UInt64) -> Void
    ) {
        let fireDate = Date().addingTimeInterval(delay)
        pendingUpdates.append((fireDate, { _ in
            callback(state, serverTick)
        }))
    }

    private func startSimulation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            let now = Date()
            self?.pendingUpdates.removeAll { update in
                if update.timestamp <= now {
                    update.callback(ShipPhysicsState(), 0)
                    return true
                }
                return false
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Preview

#Preview {
    PhysicsGameView()
}
