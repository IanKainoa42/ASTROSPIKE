import ASTROSPIKECore
import SpriteKit
import UIKit
import simd

/// The circuit, drawn. It shares the arena's screen box so the track fills the
/// window exactly where the court would, and the ships on it are drawn at the
/// size they collide at. What it does not draw is the match: no ball, no net
/// and no scoreboard here.
@MainActor
final class TrackScene: SKScene {
    var snapshot: TrackState? { didSet { renderSnapshot() } }

    /// The corridor, live. Widening it from the pause overlay has to redraw
    /// the tarmac, or the road the driver sees and the railing that hits them
    /// are two different roads.
    var track: TrackGeometry {
        didSet {
            guard track != oldValue else { return }
            didBuild = false
            buildTrack()
            renderSnapshot()
        }
    }

    /// The hulls on the grid -- the pilot's own ship and the pace ship, the
    /// same two hulls a match would put on court.
    var hulls: [TrackSeat: Hull] {
        didSet {
            guard hulls != oldValue else { return }
            for node in carNodes.values { node.path = nil }
            hullExtents.removeAll()
            renderSnapshot()
        }
    }

    private let trackLayer = SKNode()
    private let skidLayer = SKNode()
    private let actorLayer = SKNode()
    private var carNodes: [TrackSeat: SKShapeNode] = [:]
    /// How wide each hull actually came out, in points, so the glow and the
    /// lightning fit the ship that was drawn rather than a nominal one.
    private var hullExtents: [TrackSeat: CGFloat] = [:]
    private var glowNodes: [TrackSeat: SKShapeNode] = [:]
    private var didBuild = false

    private static let tarmac = SKColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1)
    private static let railColor = SKColor(red: 0.55, green: 0.90, blue: 1.0, alpha: 1)
    private static let kerbColor = SKColor(red: 1.0, green: 0.33, blue: 0.30, alpha: 1)
    /// The colour of a hull arcing after a scrape.
    private static let arcColor = SKColor(red: 0.72, green: 0.92, blue: 1.0, alpha: 1)

    init(
        track: TrackGeometry = .circuit,
        hulls: [TrackSeat: Hull] = [:],
        size: CGSize = CGSize(width: 960, height: 540)
    ) {
        self.track = track
        self.hulls = hulls
        super.init(size: size)
        // The scene resizes to the window instead of being stretched into it.
        // Left on the default the corridor is laid out for 960x540 and then
        // squeezed into a 956x440 phone, which widens every hull by a fifth --
        // a ship drawn as an ellipse is not the ship you picked in the hangar.
        scaleMode = .resizeFill
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
        // The hulls are scaled once, when their path is cut, against the track
        // rect of the moment. A new size means a new rect, so the paths go too
        // -- otherwise the corridor redraws and the ships in it keep the size
        // they had for a window that no longer exists.
        for node in carNodes.values { node.path = nil }
        for glow in glowNodes.values { glow.path = nil }
        hullExtents.removeAll()
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
        let scale = hullScale
        for seat in TrackSeat.allCases {
            guard let car = snapshot.cars[seat],
                  let node = carNodes[seat],
                  let glow = glowNodes[seat] else { continue }
            let tint = Self.tint(for: seat)
            if node.path == nil {
                // The circuit flies the match's ships, so it draws them the
                // match's way: same outline, same scale, off the same arena
                // rect. A hull a third bigger than the one in the hangar is a
                // different ship however faithful its outline, and scaling off
                // the tarmac instead would have grown every ship the moment
                // the pilot widened the lane.
                let hull = hulls[seat] ?? Hull.defaultHull(for: seat == .player ? .cyan : .orange)
                let outline = hull.spec.outline
                node.path = outline.cgPath
                node.setScale(scale)
                let length = Self.radius(of: outline) * scale * 2
                hullExtents[seat] = length
                glow.path = CGPath(
                    ellipseIn: CGRect(x: -length * 0.7, y: -length * 0.7,
                                      width: length * 1.4, height: length * 1.4),
                    transform: nil
                )
            }
            let length = hullExtents[seat] ?? 0
            node.position = point(car.position)
            // The hull outlines point up; the engine's heading points right.
            node.zRotation = CGFloat(car.heading) - .pi / 2
            glow.position = node.position

            if car.isDamaged {
                // A damaged ship arcs. It is still the pilot's ship -- it
                // answers every pad, it is just down on power -- so it keeps
                // its own colour and gets lightning over it rather than the
                // red of a car that has been taken away from its driver.
                let arcing = (snapshot.tick / 4).isMultiple(of: 2)
                node.fillColor = tint.withAlphaComponent(0.85)
                node.strokeColor = arcing ? Self.arcColor : .white
                node.glowWidth = arcing ? 2.5 : 0
                glow.fillColor = Self.arcColor.withAlphaComponent(arcing ? 0.30 : 0.12)
                if (snapshot.tick % 7) == 0 {
                    arc(at: node.position, reach: length * 0.9)
                }
            } else {
                node.fillColor = tint.withAlphaComponent(0.85)
                node.strokeColor = .white
                node.glowWidth = 0
                let heat = CGFloat(min(1, car.speed / TrackConfiguration().paceTopSpeed))
                glow.fillColor = tint.withAlphaComponent(0.05 + 0.16 * heat)
            }
        }
    }

    /// One lightning fork off a damaged hull. Short-lived and cheap: the point
    /// is that the ship visibly reads as hurt, not that it is on fire.
    private func arc(at position: CGPoint, reach: CGFloat) {
        let path = CGMutablePath()
        let start = Double.random(in: 0 ..< 2 * .pi)
        path.move(to: position)
        var tip = position
        for step in 1 ... 3 {
            let angle = start + Double.random(in: -0.7 ... 0.7)
            let hop = reach * CGFloat(step) / 3
            tip = CGPoint(x: position.x + cos(angle) * hop, y: position.y + sin(angle) * hop)
            path.addLine(to: tip)
        }
        let bolt = SKShapeNode(path: path)
        bolt.strokeColor = Self.arcColor
        bolt.lineWidth = 1.2
        bolt.glowWidth = 2
        bolt.zPosition = 25
        skidLayer.addChild(bolt)
        bolt.run(.sequence([.fadeOut(withDuration: 0.12), .removeFromParent()]))
    }

    /// The outline's own circumscribed radius, in the units it is drawn in.
    /// Dividing the collision radius by this inscribes the drawn hull exactly
    /// in the circle the engine bounces off.
    private static func radius(of outline: HullOutline) -> CGFloat {
        let longest = outline.silhouette.reduce(0.0) { max($0, simd_length($1)) }
        return CGFloat(max(1, longest))
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

    /// The match's own hull scale, to the character. `ArenaScene` sizes a
    /// ship as `unit / 473` off the same arena rect; the circuit uses the very
    /// same number so the hull the pilot chose is the hull they see, at the
    /// size they chose it at.
    private var hullScale: CGFloat {
        let rect = trackRect
        return min(rect.width / 2, rect.height) / 1.7 / 473
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

    private static func tint(for seat: TrackSeat) -> SKColor {
        seat == .player
            ? SKColor(red: 0.30, green: 0.86, blue: 1.0, alpha: 1)
            : SKColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 1)
    }
}
