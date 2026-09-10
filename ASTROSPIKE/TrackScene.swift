import ASTROSPIKECore
import SpriteKit
import UIKit

/// The circuit, drawn. It shares the arena's screen box so the track fills the
/// window exactly where the court would, and the ships on it are drawn at the
/// size they collide at. What it does not draw is the match: no ball, no net
/// and no scoreboard here.
@MainActor
final class TrackScene: SKScene {
    var snapshot: TrackState? { didSet { renderSnapshot() } }

    let track: TrackGeometry
    private let trackLayer = SKNode()
    private let skidLayer = SKNode()
    private let actorLayer = SKNode()
    private var carNodes: [TrackSeat: SKShapeNode] = [:]
    private var glowNodes: [TrackSeat: SKShapeNode] = [:]
    private var didBuild = false

    private static let tarmac = SKColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1)
    private static let railColor = SKColor(red: 0.55, green: 0.90, blue: 1.0, alpha: 1)
    private static let kerbColor = SKColor(red: 1.0, green: 0.33, blue: 0.30, alpha: 1)

    init(track: TrackGeometry = .circuit, size: CGSize = CGSize(width: 960, height: 540)) {
        self.track = track
        super.init(size: size)
        backgroundColor = SKColor(red: 0.015, green: 0.025, blue: 0.07, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(trackLayer)
        addChild(skidLayer)
        addChild(actorLayer)
        for seat in TrackSeat.allCases {
            let glow = SKShapeNode(circleOfRadius: 1)
            glow.strokeColor = .clear
            glow.zPosition = -1
            actorLayer.addChild(glow)
            glowNodes[seat] = glow

            let car = SKShapeNode()
            car.lineWidth = 1.5
            actorLayer.addChild(car)
            carNodes[seat] = car
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        didBuild = false
        buildTrack()
        renderSnapshot()
    }

    override func didMove(to view: SKView) {
        buildTrack()
    }

    // MARK: - The circuit

    private func buildTrack() {
        guard !didBuild, size.width > 1, size.height > 1 else { return }
        didBuild = true
        trackLayer.removeAllChildren()
        skidLayer.removeAllChildren()

        let width = tarmacWidthInPoints

        // The tarmac is the centreline stroked at the full width of the tube.
        // Drawing it the same way the collision measures it means what the
        // driver sees and what the railing does can never drift apart.
        let spine = closedPath(through: track.samples.map { point($0.point) })
        let surface = SKShapeNode(path: spine)
        surface.strokeColor = Self.tarmac
        surface.lineWidth = width
        surface.lineCap = .round
        surface.lineJoin = .round
        surface.fillColor = .clear
        surface.zPosition = 0
        trackLayer.addChild(surface)

        let sheen = SKShapeNode(path: spine)
        sheen.strokeColor = SKColor(white: 1, alpha: 0.045)
        sheen.lineWidth = width * 0.55
        sheen.lineCap = .round
        sheen.lineJoin = .round
        sheen.fillColor = .clear
        sheen.zPosition = 1
        trackLayer.addChild(sheen)

        // The racing line, as a hint rather than an instruction.
        let hint = SKShapeNode(path: spine)
        hint.strokeColor = SKColor(white: 1, alpha: 0.10)
        hint.lineWidth = 1
        hint.fillColor = .clear
        hint.zPosition = 2
        let dashes = spine.copy(dashingWithPhase: 0, lengths: [7, 11])
        hint.path = dashes
        trackLayer.addChild(hint)

        for sign in [1.0, -1.0] {
            addRail(sign: sign)
        }
        addStartLine()
    }

    /// A rail plus its kerb. The kerb is only laid where the road actually
    /// bends, so the corners read as corners at a glance and the straights
    /// stay clean.
    private func addRail(sign: Double) {
        let points = track.rail(sign: sign).map { point($0) }
        let path = closedPath(through: points)

        let rail = SKShapeNode(path: path)
        rail.strokeColor = Self.railColor.withAlphaComponent(0.75)
        rail.lineWidth = 2
        rail.glowWidth = 3
        rail.fillColor = .clear
        rail.zPosition = 3
        trackLayer.addChild(rail)

        let count = track.samples.count
        let kerb = CGMutablePath()
        var laid = 0
        for index in 0..<count {
            let bend = bendAt(index)
            // Kerb the inside of the bend, which is the rail on the side the
            // road is turning toward.
            guard abs(bend) > 0.9, (bend > 0) == (sign > 0) else { continue }
            laid += 1
            guard laid.isMultiple(of: 2) else { continue }
            kerb.move(to: points[index])
            kerb.addLine(to: points[(index + 1) % count])
        }
        guard !kerb.isEmpty else { return }
        let stripes = SKShapeNode(path: kerb)
        stripes.strokeColor = Self.kerbColor.withAlphaComponent(0.9)
        stripes.lineWidth = 4
        stripes.lineCap = .butt
        stripes.fillColor = .clear
        stripes.zPosition = 4
        trackLayer.addChild(stripes)
    }

    private func addStartLine() {
        let (left, right) = track.startLine
        let a = point(left)
        let b = point(right)
        let squares = 7
        let checks = CGMutablePath()
        for index in 0..<squares where index.isMultiple(of: 2) {
            let t0 = CGFloat(index) / CGFloat(squares)
            let t1 = CGFloat(index + 1) / CGFloat(squares)
            checks.move(to: CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0))
            checks.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1))
        }
        let line = SKShapeNode(path: checks)
        line.strokeColor = .white
        line.lineWidth = 6
        line.lineCap = .butt
        line.zPosition = 5
        trackLayer.addChild(line)
    }

    // MARK: - The cars

    private func renderSnapshot() {
        guard let snapshot else { return }
        buildTrack()
        let length = shipLengthInPoints
        for seat in TrackSeat.allCases {
            guard let car = snapshot.cars[seat],
                  let node = carNodes[seat],
                  let glow = glowNodes[seat] else { continue }
            let tint = Self.tint(for: seat)
            if node.path == nil {
                node.path = Self.wedge(length: length)
                glow.path = CGPath(
                    ellipseIn: CGRect(x: -length * 0.7, y: -length * 0.7,
                                      width: length * 1.4, height: length * 1.4),
                    transform: nil
                )
            }
            node.position = point(car.position)
            node.zRotation = CGFloat(car.heading)
            glow.position = node.position

            if car.isStunned {
                // A penalised car is visibly a passenger: it flashes and the
                // glow goes red, so a driver who suddenly has no controls can
                // see why rather than assuming the game broke.
                let flash = (snapshot.tick / 6).isMultiple(of: 2)
                node.fillColor = flash ? Self.kerbColor : tint.withAlphaComponent(0.35)
                node.strokeColor = Self.kerbColor
                glow.fillColor = Self.kerbColor.withAlphaComponent(0.22)
            } else {
                node.fillColor = tint.withAlphaComponent(0.85)
                node.strokeColor = .white
                let heat = CGFloat(min(1, car.speed / TrackConfiguration().paceTopSpeed))
                glow.fillColor = tint.withAlphaComponent(0.05 + 0.16 * heat)
            }
        }
    }

    func present(_ events: [TrackEvent]) {
        for event in events {
            guard case let .railStrike(_, position, speed) = event else { continue }
            burst(at: point(position), intensity: min(1, speed / 0.9))
        }
    }

    private func burst(at position: CGPoint, intensity: Double) {
        let sparks = 5 + Int(7 * intensity)
        for index in 0..<sparks {
            let spark = SKShapeNode(circleOfRadius: 1.6)
            spark.fillColor = index.isMultiple(of: 3) ? .white : Self.kerbColor
            spark.strokeColor = .clear
            spark.position = position
            spark.zPosition = 20
            skidLayer.addChild(spark)
            let angle = Double(index) / Double(sparks) * 2 * .pi
            let reach = 8 + 26 * intensity
            spark.run(.sequence([
                .group([
                    .move(by: CGVector(dx: cos(angle) * reach, dy: sin(angle) * reach), duration: 0.32),
                    .fadeOut(withDuration: 0.32),
                ]),
                .removeFromParent(),
            ]))
        }
    }

    // MARK: - Geometry

    /// Ships, sparks and the tarmac all share the court's screen box, so the
    /// track sits exactly where the arena would and the HUD above it does not
    /// have to move between modes.
    private var trackRect: CGRect { ArenaScene.arenaRect(in: size) }

    private var tarmacWidthInPoints: CGFloat {
        let rect = trackRect
        return CGFloat(track.halfWidth * 2 / (ArenaGeometry.standard.halfWidth * 2)) * rect.width
    }

    /// The ship is drawn at the size it actually collides at, not at a
    /// fraction of the tarmac. The corridor is more than twice as wide as it
    /// used to be, and a hull scaled off it would have grown with it -- what
    /// flies round here is the same 0.048-radius hull a match flies.
    private var shipLengthInPoints: CGFloat {
        let arena = ArenaGeometry.standard
        let hull = TrackConfiguration().shipRadius * 2
        return CGFloat(hull / (arena.halfWidth * 2)) * trackRect.width
    }

    private func point(_ world: SIMD2<Double>) -> CGPoint {
        let rect = trackRect
        let arena = ArenaGeometry.standard
        let worldWidth = arena.halfWidth * 2
        let worldHeight = arena.ceilingY - arena.floorY
        return CGPoint(
            x: rect.midX + CGFloat(world.x / worldWidth) * rect.width,
            y: rect.midY + CGFloat(world.y / worldHeight) * rect.height
        )
    }

    /// Signed turn per sample, for deciding where a kerb belongs.
    private func bendAt(_ index: Int) -> Double {
        let count = track.samples.count
        let here = track.samples[index].tangent
        let next = track.samples[(index + 3) % count].tangent
        return atan2(
            here.x * next.y - here.y * next.x,
            here.x * next.x + here.y * next.y
        ) * 100
    }

    private func closedPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private static func wedge(length: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: length * 0.62, y: 0))
        path.addLine(to: CGPoint(x: -length * 0.42, y: length * 0.36))
        path.addLine(to: CGPoint(x: -length * 0.24, y: 0))
        path.addLine(to: CGPoint(x: -length * 0.42, y: -length * 0.36))
        path.closeSubpath()
        return path
    }

    private static func tint(for seat: TrackSeat) -> SKColor {
        seat == .player
            ? SKColor(red: 0.30, green: 0.86, blue: 1.0, alpha: 1)
            : SKColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 1)
    }
}
