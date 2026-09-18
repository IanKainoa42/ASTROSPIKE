import Combine
import CoreGraphics
import QuartzCore
import UIKit

/// Manages the game loop: input, physics, prediction, and rendering coordination.
/// Uses CADisplayLink for frame-perfect timing and synchronization with screen refresh.
@MainActor
final class GameLoopManager: NSObject, ObservableObject {
    // MARK: - Published State

    /// Current displayed game state.
    @Published private(set) var displayState: ShipPhysicsState

    /// Latest reconciliation error magnitude (for debugging).
    @Published private(set) var reconciliationError: Double = 0

    // MARK: - Components

    private let physicsEngine: DeterministicPhysicsEngine
    private let prediction: ClientSidePredictionManager
    private let inputHandler: TouchInputHandler

    // MARK: - Timing

    /// Display link for frame-synchronous updates.
    private var displayLink: CADisplayLink?

    /// Fixed physics time step (typically 1/60 or 1/120 seconds).
    let fixedDeltaTime: Double = 1.0 / 60.0

    /// Accumulated time (for fixed timestep integration).
    private var accumulator: Double = 0.0

    /// Previous timestamp from display link.
    private var previousTimestamp: CFTimeInterval = 0

    // MARK: - Configuration

    /// Enable debug logging of reconciliation events.
    var debugLogging = false

    var onPhysicsStep: (() -> Void)?
    var onNetworkUpdate: ((ShipPhysicsState) -> Void)?

    init(
        arena: ArenaPhysicsGeometry,
        initialState: ShipPhysicsState
    ) {
        self.physicsEngine = DeterministicPhysicsEngine(arena: arena)
        self.prediction = ClientSidePredictionManager(
            physicsEngine: physicsEngine,
            initialState: initialState
        )
        self.inputHandler = TouchInputHandler()
        self.displayState = initialState

        super.init()

        // Setup input change handler
        inputHandler.onInputChanged = { [weak self] in
            self?.onInputChanged()
        }

        // Setup prediction callbacks
        prediction.onReconciliation = { [weak self] error in
            self?.reconciliationError = error.magnitude
            if self?.debugLogging == true {
                print("[GameLoop] Reconciliation error: \(error.magnitude)")
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the game loop.
    func start() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(
            target: self,
            selector: #selector(tick(_:))
        )
        // Request 60 FPS (adjust preferred for 120 Hz capable devices)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link

        previousTimestamp = 0
        accumulator = 0.0

        if debugLogging {
            print("[GameLoop] Started")
        }
    }

    /// Stop the game loop.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil

        if debugLogging {
            print("[GameLoop] Stopped")
        }
    }

    /// Resume a paused game loop.
    func resume() {
        guard displayLink != nil else { start(); return }
        displayLink?.isPaused = false
    }

    /// Pause the game loop.
    func pause() {
        displayLink?.isPaused = true
    }

    func isPaused() -> Bool {
        displayLink?.isPaused ?? true
    }

    // MARK: - Display Link Callback

    @objc private func tick(_ link: CADisplayLink) {
        if previousTimestamp == 0 {
            previousTimestamp = link.timestamp
            return
        }

        let currentTime = link.timestamp
        let deltaTime = min(currentTime - previousTimestamp, 0.1)
        previousTimestamp = currentTime

        frame(deltaTime: deltaTime)
    }

    /// Main game loop frame: input → physics → display update.
    private func frame(deltaTime: Double) {
        // Step 1: Accumulate delta time
        accumulator += deltaTime

        // Step 2: Process fixed physics steps
        while accumulator >= fixedDeltaTime {
            accumulator -= fixedDeltaTime
            physicsStep()
        }

        // Step 3: Update display state
        displayState = prediction.displayState

        // Step 4: Fire callbacks
        onPhysicsStep?()
    }

    /// Single fixed timestep of physics simulation.
    private func physicsStep() {
        let currentInput = inputHandler.currentInput
        currentInput.tick = prediction.localTick

        // Apply local input and predict immediately
        prediction.applyLocalInput(currentInput, deltaTime: fixedDeltaTime)

        if debugLogging, prediction.localTick % 60 == 0 {
            let pos = prediction.predictedState.position
            print("[Physics] Tick \(prediction.localTick): pos=(\(pos.x), \(pos.y))")
        }
    }

    // MARK: - Input

    private func onInputChanged() {
        // Input is automatically applied each physics step
    }

    /// Register a view to handle touch input.
    func installTouchInputIn(_ view: UIView) {
        let view = view as! TouchableGameView
        view.touchInputHandler = inputHandler
    }

    // MARK: - Network Reconciliation

    /// Called when server sends an authoritative state update.
    /// This reconciles local prediction with server reality.
    func receiveAuthoritativeUpdate(
        state: ShipPhysicsState,
        serverTick: UInt64
    ) {
        prediction.reconcileWithAuthoritative(
            authoritativeState: state,
            serverTick: serverTick
        )

        if debugLogging {
            print("[Reconciliation] Server tick: \(serverTick), Local tick: \(prediction.localTick)")
        }

        onNetworkUpdate?(state)
    }

    // MARK: - State Access

    var currentPredictedState: ShipPhysicsState {
        prediction.predictedState
    }

    var currentAuthoritativeState: ShipPhysicsState {
        prediction.authoritativeState
    }

    var localTick: UInt64 {
        prediction.localTick
    }

    /// Reset to a known state (typically after match restart).
    func reset(to state: ShipPhysicsState) {
        prediction.reset(to: state)
        displayState = state
        accumulator = 0.0
    }
}

// MARK: - UIView Integration

/// A UIView subclass that integrates with the game loop for touch input.
/// Subclass this or add touch handling via delegates.
@MainActor
open class TouchableGameView: UIView {
    var touchInputHandler: TouchInputHandler?

    override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        touchInputHandler?.handleTouchesBegan(touches, in: self)
    }

    override open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        touchInputHandler?.handleTouchesMoved(touches, in: self)
    }

    override open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touchInputHandler?.handleTouchesEnded(touches, in: self)
    }

    override open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchInputHandler?.handleTouchesCancelled(touches, in: self)
    }
}

// MARK: - Integration Helper

/// Simple container to manage all game loop systems together.
@MainActor
struct GameLoopSetup {
    let loopManager: GameLoopManager
    let inputHandler: TouchInputHandler
    let physicsEngine: DeterministicPhysicsEngine

    static func create(arenaSize: CGSize) -> GameLoopSetup {
        let arena = ArenaPhysicsGeometry(width: arenaSize.width, height: arenaSize.height)
        let initialState = ShipPhysicsState(
            position: CGPoint(x: 0, y: 0),
            velocity: .zero,
            rotation: 0,
            angularVelocity: 0
        )

        let loopManager = GameLoopManager(arena: arena, initialState: initialState)

        return GameLoopSetup(
            loopManager: loopManager,
            inputHandler: loopManager.inputHandler,
            physicsEngine: arena.physics
        )
    }
}

extension ArenaPhysicsGeometry {
    var physics: DeterministicPhysicsEngine {
        DeterministicPhysicsEngine(arena: self)
    }
}
