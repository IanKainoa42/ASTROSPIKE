import ASTROSPIKECore
import SpriteKit
import UIKit
import simd

@MainActor
final class ArenaScene: SKScene {
    var snapshot: WorldState? { didSet { renderSnapshot() } }
    var reduceMotion = false
    /// Warm-up bay hoops. Empty in a real match.
    var rings: [WarmupRing] = [] { didSet { renderRings() } }
    private var ringNodes: [UInt64: SKShapeNode] = [:]

    /// Everything that sits in the arena, so a hit can shake the whole court
    /// by moving one node. The vignette hangs off the scene instead: it is
    /// the lens, and the lens does not shake.
    private let worldNode = SKNode()
    private let arenaLayer = SKNode()
    private let trailLayer = SKNode()
    private let plumeLayer = SKNode()
    private let actorLayer = SKNode()
    /// The lit floor. A faint grid is always there; each light only shows up
    /// where it falls on a grid line, plus a soft pool on top.
    private let gridBase = SKSpriteNode()
    private let gridLightCrop = SKCropNode()
    private let gridLightLayer = SKNode()
    private let poolLightLayer = SKNode()
    private var gridLightSprites: [SKSpriteNode] = []
    private var poolLightSprites: [SKSpriteNode] = []
    private var transientLights: [TransientLight] = []
    private let vignette = SKSpriteNode()
    private var shakeAmount: CGFloat = 0
    private var lastRenderTime: TimeInterval?
    /// The bolt punch the engine hands a ball. A bolt hit is the one
    /// collision whose intensity is this exact number, which is how the
    /// scene tells it apart without a kind on the event.
    var boltPunch = SimulationConfiguration().boltPunch
    /// Which seats are pulling, how hard the beam has the ball, and where,
    /// for the tractor hum. Empty while nobody is holding a beam.
    private(set) var beamPulls: [Seat: BeamPull] = [:]
    struct BeamPull { var grip: Double; var x: Double }
    private var beamRigs: [Seat: BeamRig] = [:]
    private var gripRings: [SKShapeNode] = []
    private var smokeBudgets: [Seat: Double] = [:]
    private var fireCores: [Seat: [SKSpriteNode]] = [:]
    /// The court this scene draws. Set before the view appears; changing it
    /// tears the arena layer down and rebuilds it, so the drawn court can
    /// never disagree with the one the simulation is colliding against.
    var arena = ArenaGeometry.standard {
        didSet {
            guard arena != oldValue else { return }
            didBuild = false
            buildArena()
        }
    }
    /// One hull and one exhaust per seat, built up front and hidden while
    /// the seat is empty.
    private var shipNodes: [Seat: SKShapeNode] = [:]
    /// YOU and ALLY over the two ships on the pilot's side in doubles, where
    /// two hulls share a colour and nothing else says which one you fly.
    private var markerNodes: [Seat: SKLabelNode] = [:]
    var localSeat: Seat?
    private var exhaustNodes: [Seat: SKSpriteNode] = [:]
    /// The hull's own exhaust width, kept so the idle ember can be pinned
    /// narrower than a wide hull's lit plume.
    private var exhaustWidths: [Seat: CGFloat] = [:]
    /// One node per ball the engine can field. Doubles plays two; a duel
    /// plays one and the second sits hidden.
    private let balls = (0 ..< SimulationConfiguration.maximumBallCount).map { _ in BallNode() }
    private var ballSpinTick: UInt64?
    private static let tickDuration = SimulationConfiguration().stepDuration
    private var boltNodes: [UInt64: SKNode] = [:]
    /// How far the beam reaches, taken from the engine that does the pulling
    /// so the drawing can never disagree with the grab.
    var tractorRange = SimulationConfiguration().tractorRange
    private var ballTrails: [[CGPoint]] = []
    private var plumeSeed = 0
    private var didBuild = false
    /// The ends the court was last drawn for. The teams change ends between
    /// sets, so every half-coloured mark is drawn for whoever is on that half.
    private var drawnSidesSwapped = false
    private var leftTeam: Team { drawnSidesSwapped ? .orange : .cyan }
    /// The pilot's own team, so the court can say which goal is theirs to
    /// score in and which to defend. Nil in the warm-up bay.
    var localTeam: Team? {
        didSet {
            guard localTeam != oldValue else { return }
            didBuild = false
            buildArena()
        }
    }

    override init(size: CGSize = CGSize(width: 960, height: 540)) {
        super.init(size: size)
        backgroundColor = SKColor(red: 0.015, green: 0.025, blue: 0.07, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(worldNode)
        // The view ignores sibling order, so every layer here is stacked by z:
        // grid and its light at the very bottom, under the court markings.
        gridBase.zPosition = -6
        gridBase.alpha = 0.035
        worldNode.addChild(gridBase)
        gridLightCrop.zPosition = -5.8
        gridLightCrop.addChild(gridLightLayer)
        // The lab composited the lit grid at 85%.
        gridLightLayer.alpha = 0.85
        worldNode.addChild(gridLightCrop)
        poolLightLayer.zPosition = -5.6
        worldNode.addChild(poolLightLayer)
        worldNode.addChild(arenaLayer)
        worldNode.addChild(trailLayer)
        worldNode.addChild(plumeLayer)
        worldNode.addChild(actorLayer)
        vignette.zPosition = 50
        addChild(vignette)
        for seat in Seat.allCases {
            let ship = SKShapeNode()
            let exhaust = SKSpriteNode(texture: ArenaScene.puffTexture, size: CGSize(width: 30, height: 34))
            shipNodes[seat] = ship
            exhaustNodes[seat] = exhaust
            actorLayer.addChild(ship)
            // The hot core of the burn: a white-hot tongue inside an amber
            // one, flickered per frame. Only lit while the engine is.
            fireCores[seat] = [
                (SKColor(red: 1, green: 0.96, blue: 0.88, alpha: 1), CGSize(width: 15, height: 34), CGFloat(0.95)),
                (SKColor(red: 1, green: 0.78, blue: 0.47, alpha: 1), CGSize(width: 25, height: 53), CGFloat(0.8)),
            ].map { color, size, alpha in
                let core = SKSpriteNode(texture: ArenaScene.puffTexture, size: size)
                core.anchorPoint = CGPoint(x: 0.5, y: 1)
                core.position = CGPoint(x: 0, y: -16)
                core.color = color
                core.colorBlendFactor = 1
                core.blendMode = .add
                core.alpha = alpha
                core.zPosition = -0.9
                core.isHidden = true
                ship.addChild(core)
                return core
            }
            let marker = SKLabelNode(fontNamed: "Menlo-Bold")
            marker.fontSize = 11
            marker.fontColor = Self.hullColor(for: seat)
            marker.verticalAlignmentMode = .bottom
            marker.zPosition = 6
            marker.isHidden = true
            markerNodes[seat] = marker
            actorLayer.addChild(marker)
        }
        for ball in balls { actorLayer.addChild(ball) }
        for _ in balls {
            // Sits outside the ball's edge, so the silhouette stays hard.
            let ring = SKShapeNode()
            ring.strokeColor = Self.beamColor
            ring.fillColor = .clear
            ring.lineWidth = 2
            ring.glowWidth = 0
            ring.zPosition = 0.5
            ring.isHidden = true
            gripRings.append(ring)
            actorLayer.addChild(ring)
        }
        for seat in Seat.allCases {
            let rig = BeamRig()
            beamRigs[seat] = rig
            actorLayer.addChild(rig.crop)
            actorLayer.addChild(rig.tether)
        }
        configureActorNodes()
    }

    static let beamColor = SKColor(red: 0.70, green: 0.42, blue: 1.0, alpha: 1)
    /// The lab's beam gain, picked at 1.65: every part of the beam that has a
    /// brightness is multiplied by it.
    private static let beamGain: CGFloat = 1.65
    /// The lab's floor-light intensity pick.
    private static let lightIntensity: CGFloat = 1.1
    /// The lab's hit-shake pick, 0 to 1.
    private static let shakeGain: CGFloat = 0.35
    /// The lab's smoke density pick, 0 to 2.
    private static let smokeDensity: Double = 2

    /// The tractor cone ahead of each nose: a gradient cropped to the cone the
    /// engine grabs with, plus the tether drawn to a gripped ball.
    @MainActor
    final class BeamRig {
        let crop = SKCropNode()
        let mask = SKShapeNode()
        let glow = SKSpriteNode(texture: ArenaScene.beamGradientTexture)
        let tether = SKShapeNode()
        var budget = 0.0

        init() {
            mask.fillColor = .white
            mask.strokeColor = .clear
            crop.maskNode = mask
            glow.color = ArenaScene.beamColor
            glow.colorBlendFactor = 1
            glow.blendMode = .add
            glow.alpha = 0.22 * ArenaScene.beamGain
            crop.addChild(glow)
            crop.zPosition = 3
            crop.isHidden = true
            tether.strokeColor = ArenaScene.beamColor
            tether.lineWidth = 2
            tether.glowWidth = 0
            tether.blendMode = .add
            tether.zPosition = 3.2
            tether.isHidden = true
        }
    }

    private struct TransientLight {
        var position: CGPoint
        var radius: CGFloat
        var color: SKColor
        var intensity: CGFloat
        var born: TimeInterval
        var life: TimeInterval
    }

    private struct FloorLight {
        var position: CGPoint
        var radius: CGFloat
        var color: SKColor
        var intensity: CGFloat
    }

    required init?(coder aDecoder: NSCoder) { nil }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        buildVignette()
        didBuild = false
        buildArena()
        renderSnapshot()
        renderRings()
    }

    private func renderRings() {
        let live = Set(rings.map(\.id))
        for (id, node) in ringNodes where !live.contains(id) {
            node.removeFromParent()
            ringNodes[id] = nil
        }
        guard size.width > 0 else { return }
        let rect = arenaRect
        for ring in rings {
            let diameter = CGSize(
                width: CGFloat(ring.radius * 2 / (arena.halfWidth * 2)) * rect.width,
                height: CGFloat(ring.radius * 2 / (arena.ceilingY - arena.floorY)) * rect.height
            )
            let node: SKShapeNode
            if let existing = ringNodes[ring.id] {
                node = existing
                node.path = CGPath(ellipseIn: CGRect(origin: CGPoint(x: -diameter.width / 2, y: -diameter.height / 2), size: diameter), transform: nil)
            } else {
                node = SKShapeNode(ellipseOf: diameter)
                node.strokeColor = SKColor(red: 1, green: 0.86, blue: 0.3, alpha: 0.9)
                node.fillColor = SKColor(red: 1, green: 0.86, blue: 0.3, alpha: 0.07)
                node.lineWidth = 3
                node.glowWidth = 7
                node.zPosition = -0.5
                node.alpha = 0
                actorLayer.addChild(node)
                ringNodes[ring.id] = node
                node.run(.fadeIn(withDuration: 0.25))
                if !reduceMotion {
                    node.run(.repeatForever(.sequence([
                        .scale(to: 1.07, duration: 0.9),
                        .scale(to: 1.0, duration: 0.9),
                    ])))
                }
            }
            node.position = point(ring.position.x, ring.position.y)
        }
    }

    func popRing(_ ring: WarmupRing) {
        let position = point(ring.position.x, ring.position.y)
        let gold = SKColor(red: 1, green: 0.86, blue: 0.3, alpha: 1)
        sparks(at: position, color: gold)
        if !reduceMotion { flash(at: position, color: gold, scale: 1.4, life: 0.3) }
    }

    /// Team colour for a seat. Wings are a paler tint of their side so the
    /// court reads as two teams first and four ships second.
    static func hullColor(for seat: Seat) -> SKColor {
        switch seat {
        case .cyan: SKColor(red: 0.0, green: 0.92, blue: 1.0, alpha: 1)
        case .orange: SKColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 1)
        case .cyanWing: SKColor(red: 0.45, green: 0.88, blue: 1.0, alpha: 1)
        case .orangeWing: SKColor(red: 1.0, green: 0.65, blue: 0.30, alpha: 1)
        }
    }

    private func configureActorNodes() {
        for seat in Seat.allCases {
            guard let ship = shipNodes[seat], let exhaust = exhaustNodes[seat] else { continue }
            let color = Self.hullColor(for: seat)
            ship.fillColor = color
            ship.strokeColor = color
            ship.lineWidth = seat.isWing ? 2.5 : 2.0
            ship.glowWidth = 8
            ship.isHidden = true
            // A soft vapour sprite hung from the tail, anchored at its top so
            // yScale stretches it backwards along the nose axis as throttle rises.
            exhaust.anchorPoint = CGPoint(x: 0.5, y: 1)
            exhaust.position = CGPoint(x: 0, y: -16)
            exhaust.color = color
            exhaust.colorBlendFactor = 1.0
            exhaust.blendMode = .add
            exhaust.zPosition = -1
            exhaust.isHidden = true
            ship.addChild(exhaust)
            setHull(Hull.defaultHull(forSeat: seat), for: seat)
        }
    }

    private func buildArena() {
        guard !didBuild, size.width > 0, size.height > 0 else { return }
        didBuild = true
        arenaLayer.removeAllChildren()
        let frame = arenaRect
        buildLighting(in: frame)

        let leftZone = SKShapeNode(rect: CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width / 2,
            height: frame.height
        ))
        leftZone.fillColor = Self.color(leftTeam).withAlphaComponent(0.025)
        leftZone.strokeColor = .clear
        arenaLayer.addChild(leftZone)
        let rightZone = SKShapeNode(rect: CGRect(
            x: frame.midX,
            y: frame.minY,
            width: frame.width / 2,
            height: frame.height
        ))
        rightZone.fillColor = Self.color(leftTeam.opponent).withAlphaComponent(0.025)
        rightZone.strokeColor = .clear
        arenaLayer.addChild(rightZone)

        addSideLabel(for: leftTeam, at: point(-0.72, 0.68))
        addSideLabel(for: leftTeam.opponent, at: point(0.72, 0.68))
        addCrossingLimit(for: leftTeam, onHalfAt: -1)
        addCrossingLimit(for: leftTeam.opponent, onHalfAt: 1)

        for index in 0..<56 {
            let seed = Double(index * 7919 % 101) / 101
            let star = SKShapeNode(circleOfRadius: index.isMultiple(of: 9) ? 1.8 : 0.8)
            star.fillColor = .white.withAlphaComponent(0.25 + seed * 0.45)
            star.strokeColor = .clear
            star.position = CGPoint(
                x: frame.minX + CGFloat(Double(index * 37 % 97) / 97) * frame.width,
                y: frame.minY + CGFloat(Double(index * 61 % 89) / 89) * frame.height
            )
            arenaLayer.addChild(star)
        }

        let wall = SKShapeNode(path: boundsPath())
        wall.strokeColor = SKColor(white: 0.8, alpha: 0.45)
        wall.lineWidth = 3
        wall.glowWidth = 1
        arenaLayer.addChild(wall)

        let floor = CGMutablePath()
        floor.move(to: point(-arena.cornerTangentX, arena.floorY))
        floor.addLine(to: point(arena.cornerTangentX, arena.floorY))
        let floorNode = SKShapeNode(path: floor)
        floorNode.strokeColor = .white.withAlphaComponent(0.55)
        floorNode.lineWidth = 4
        floorNode.glowWidth = 1
        arenaLayer.addChild(floorNode)

        if arena.hasHump { addHump() }
        addObstacles()
        switch arena.netStyle {
        case .roofPortal: addPortalNet()
        case .floorWall: addStandingNet()
        case .none: addHoop()
        }
    }

    /// Volleyball's net: one slab standing up out of the middle of the floor,
    /// covering the bottom half of the arena, with a bright tape across the
    /// top. Nothing about it is team coloured -- it belongs to neither side,
    /// and it is not a target, it is the thing in your way.
    private func addStandingNet() {
        let half = arena.netHalfWidth
        let top = arena.netTopY

        let slab = CGMutablePath()
        slab.move(to: point(-half, arena.floorY))
        slab.addLine(to: point(-half, top))
        slab.addLine(to: point(half, top))
        slab.addLine(to: point(half, arena.floorY))
        slab.closeSubpath()
        let body = SKShapeNode(path: slab)
        body.fillColor = SKColor(white: 0.10, alpha: 0.92)
        body.strokeColor = .white.withAlphaComponent(0.45)
        body.lineWidth = 2
        body.zPosition = -1
        arenaLayer.addChild(body)

        // The mesh. Cheap horizontal rungs rather than a real weave: at this
        // width a diagonal lattice reads as noise.
        let mesh = CGMutablePath()
        var y = arena.floorY + 0.02
        while y < top {
            mesh.move(to: point(-half, y))
            mesh.addLine(to: point(half, y))
            y += 0.038
        }
        let meshNode = SKShapeNode(path: mesh)
        meshNode.strokeColor = .white.withAlphaComponent(0.22)
        meshNode.lineWidth = 1
        arenaLayer.addChild(meshNode)

        // The tape: the rounded cap the ball actually rebounds off, drawn as
        // the half-round the simulation treats it as.
        let tape = CGMutablePath()
        tape.addArc(
            center: point(0, top),
            radius: abs(point(half, top).x - point(0, top).x),
            startAngle: 0,
            endAngle: .pi,
            clockwise: false
        )
        let tapeNode = SKShapeNode(path: tape)
        tapeNode.strokeColor = .white.withAlphaComponent(0.95)
        tapeNode.lineWidth = 4
        tapeNode.glowWidth = 2
        tapeNode.fillColor = .clear
        arenaLayer.addChild(tapeNode)

        addSideLabel("NET", team: .cyan, at: point(0, top + 0.055))
    }

    /// Basketball's hoop: one rim at centre court that both halves shoot at.
    /// The posts are solid -- clip one and the shot is off -- and the window
    /// between them is the whole target.
    private func addHoop() {
        guard let hoop = arena.hoop else { return }
        let rimY = hoop.centerY

        // The mesh hanging under the rim. Purely decorative: the ball passes
        // through it untouched, the way it does through the window above.
        let mesh = CGMutablePath()
        let bottomHalf = hoop.innerHalfWidth * 0.55
        for step in 0 ... 4 {
            let t = Double(step) / 4
            let topX = -hoop.innerHalfWidth + 2 * hoop.innerHalfWidth * t
            let bottomX = -bottomHalf + 2 * bottomHalf * t
            mesh.move(to: point(topX, rimY))
            mesh.addLine(to: point(bottomX, rimY - hoop.netDepth))
        }
        for step in 1 ... 3 {
            let t = Double(step) / 4
            let halfAt = hoop.innerHalfWidth + (bottomHalf - hoop.innerHalfWidth) * t
            mesh.move(to: point(-halfAt, rimY - hoop.netDepth * t))
            mesh.addLine(to: point(halfAt, rimY - hoop.netDepth * t))
        }
        let meshNode = SKShapeNode(path: mesh)
        meshNode.strokeColor = .white.withAlphaComponent(0.35)
        meshNode.lineWidth = 1.5
        meshNode.zPosition = -1
        arenaLayer.addChild(meshNode)

        // The window: the line a ball has to drop through.
        let window = CGMutablePath()
        window.move(to: point(-hoop.innerHalfWidth, rimY))
        window.addLine(to: point(hoop.innerHalfWidth, rimY))
        let windowNode = SKShapeNode(path: window)
        windowNode.strokeColor = SKColor(red: 1, green: 0.62, blue: 0.24, alpha: 0.55)
        windowNode.lineWidth = 3
        windowNode.glowWidth = 4
        arenaLayer.addChild(windowNode)

        for sign in [-1.0, 1.0] {
            let center = hoop.postCenter(sign: sign)
            let radius = abs(point(hoop.rimRadius, 0).x - point(0, 0).x)
            let post = SKShapeNode(circleOfRadius: radius)
            post.position = point(center.x, center.y)
            post.fillColor = SKColor(red: 1, green: 0.45, blue: 0.12, alpha: 1)
            post.strokeColor = .white.withAlphaComponent(0.9)
            post.lineWidth = 2
            post.glowWidth = 2
            arenaLayer.addChild(post)
        }

        addSideLabel("HOOP", team: .orange, at: point(0, rimY + 0.075))
    }

    /// The playable boundary, with the same flattened corner arcs the
    /// simulation collides against. Sampled rather than approximated with
    /// Bezier control points so the drawn edge cannot drift from the physics.
    private func boundsPath() -> CGPath {
        let path = CGMutablePath()
        let steps = 14
        var started = false
        // Bottom-left, top-left, top-right, bottom-right.
        let corners: [(x: Double, y: Double)] = [(-1, -1), (-1, 1), (1, 1), (1, -1)]
        for corner in corners {
            let originX = corner.x * arena.cornerTangentX
            let originY = corner.y > 0
                ? arena.ceilingY - arena.cornerRadiusY
                : arena.floorY + arena.cornerRadiusY
            // Walk each arc from its vertical tangent to its horizontal one, so
            // consecutive corners join along the straight wall between them.
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let sweep = t * .pi / 2
                let goingUp = corner.y > 0
                let angle = goingUp == (corner.x < 0) ? sweep : .pi / 2 - sweep
                let x = originX + corner.x * arena.cornerRadiusX * sin(angle)
                let y = originY + corner.y * arena.cornerRadiusY * cos(angle)
                let screen = point(x, y)
                if started {
                    path.addLine(to: screen)
                } else {
                    path.move(to: screen)
                    started = true
                }
            }
        }
        path.closeSubpath()
        return path
    }

    /// The layout's cuts, ledges and pegs, drawn as the capsules the
    /// simulation collides against: the spine stroked at the obstacle's own
    /// radius, so a ball is seen to kiss exactly the edge it bounces off.
    private func addObstacles() {
        guard !arena.obstacles.isEmpty else { return }
        // Cuts run into the walls and roof so nothing can get behind them;
        // the court outline crops off the part buried in the wall.
        let crop = SKCropNode()
        // Not boundsPath(): it crosses itself at the corner tangents, so its
        // fill leaves the middle of the court out.
        let lowerLeft = point(-arena.halfWidth, arena.floorY)
        let upperRight = point(arena.halfWidth, arena.ceilingY)
        let court = CGRect(
            x: min(lowerLeft.x, upperRight.x), y: min(lowerLeft.y, upperRight.y),
            width: abs(upperRight.x - lowerLeft.x), height: abs(upperRight.y - lowerLeft.y)
        )
        let mask = SKShapeNode(path: CGPath(
            roundedRect: court,
            cornerWidth: abs(point(arena.halfWidth, 0).x - point(arena.cornerTangentX, 0).x),
            cornerHeight: abs(point(0, arena.ceilingY).y - point(0, arena.ceilingY - arena.cornerRadiusY).y),
            transform: nil
        ))
        mask.fillColor = .white
        mask.strokeColor = .clear
        crop.maskNode = mask
        crop.zPosition = 0
        arenaLayer.addChild(crop)
        for obstacle in arena.obstacles {
            // Walked in world units and mapped point by point, so a court
            // drawn wider than it is tall still lines up with the physics.
            let spine = obstacle.end - obstacle.start
            let length = simd_length(spine)
            let along = length > 1e-9 ? spine / length : SIMD2(1.0, 0)
            let heading = atan2(along.y, along.x)
            let outline = CGMutablePath()
            let arc = 16
            for (center, from) in [(obstacle.end, heading - .pi / 2), (obstacle.start, heading + .pi / 2)] {
                for step in 0 ... arc {
                    let theta = from + Double(step) / Double(arc) * .pi
                    let world = center + SIMD2(cos(theta), sin(theta)) * obstacle.radius
                    let scene = point(world.x, world.y)
                    if outline.isEmpty { outline.move(to: scene) } else { outline.addLine(to: scene) }
                }
            }
            outline.closeSubpath()
            let fill = SKShapeNode(path: outline)
            fill.strokeColor = .clear
            fill.fillColor = SKColor(white: 0.16, alpha: 1)
            fill.zPosition = -2
            crop.addChild(fill)

            let edge = SKShapeNode(path: outline)
            edge.strokeColor = .white.withAlphaComponent(0.55)
            edge.lineWidth = 3
            edge.glowWidth = 1
            edge.fillColor = .clear
            crop.addChild(edge)
        }
    }

    /// The hump the net hangs from: the corner fillet mirrored into the middle
    /// of the roof, walked from the same samples the simulation collides
    /// against so the drawn slope cannot drift from the one balls bounce off.
    private func addHump() {
        let profile = arena.humpProfile

        let hill = CGMutablePath()
        hill.move(to: point(-profile.last!.x, arena.ceilingY))
        for sample in profile.reversed() {
            hill.addLine(to: point(-sample.x, sample.y))
        }
        for sample in profile {
            hill.addLine(to: point(sample.x, sample.y))
        }
        hill.closeSubpath()

        let fill = SKShapeNode(path: hill)
        fill.strokeColor = .clear
        fill.fillColor = SKColor(white: 0.16, alpha: 1)
        fill.zPosition = -2
        arenaLayer.addChild(fill)

        let edge = SKShapeNode(path: hill)
        edge.strokeColor = .white.withAlphaComponent(0.55)
        edge.lineWidth = 4
        edge.glowWidth = 1
        edge.fillColor = .clear
        arenaLayer.addChild(edge)
    }

    /// The net is the goal, and it is a portal: drive the ball into a face and
    /// it goes through and vanishes. Each face is painted in the colour of the
    /// side that shoots at it, so the target you are aiming for is the one in
    /// front of you. The cap underneath is hard and neutral -- white, not
    /// team coloured -- because clipping it rebounds rather than scoring. The
    /// lips either side of the cap are the one part of the goal that helps:
    /// they tilt in, and a ball that lands on one rolls into the mouth.
    private func addPortalNet() {
        let half = arena.netHalfWidth
        let collarBottom = arena.portalMouthTopY

        // The collar: the part of the slab hanging from the hump, above the
        // mouth. Solid and neutral, like the cap.
        let collar = CGMutablePath()
        collar.move(to: point(-half, arena.humpUndersideY))
        collar.addLine(to: point(-half, collarBottom))
        collar.addLine(to: point(half, collarBottom))
        collar.addLine(to: point(half, arena.humpUndersideY))
        collar.closeSubpath()
        let collarNode = SKShapeNode(path: collar)
        collarNode.strokeColor = .white.withAlphaComponent(0.55)
        collarNode.lineWidth = 2
        collarNode.fillColor = SKColor(white: 0.16, alpha: 1)
        arenaLayer.addChild(collarNode)

        // The mouth: a dark slot the ball disappears into.
        let mouth = CGMutablePath()
        mouth.move(to: point(-half, collarBottom))
        mouth.addLine(to: point(-half, arena.netBottomY))
        mouth.addLine(to: point(half, arena.netBottomY))
        mouth.addLine(to: point(half, collarBottom))
        mouth.closeSubpath()
        let mouthNode = SKShapeNode(path: mouth)
        mouthNode.strokeColor = .clear
        mouthNode.fillColor = SKColor(white: 0, alpha: 0.85)
        mouthNode.zPosition = -1
        arenaLayer.addChild(mouthNode)

        for sign in [-1.0, 1.0] {
            // Coloured for the team that defends it: whoever is on that half.
            let color = Self.color(sign < 0 ? leftTeam : leftTeam.opponent)
            let face = CGMutablePath()
            face.move(to: point(half * sign, collarBottom))
            face.addLine(to: point(half * sign, arena.netBottomY))
            let faceNode = SKShapeNode(path: face)
            faceNode.strokeColor = color.withAlphaComponent(0.9)
            // Some bloom is left on the faces alone: they are the goals.
            // Everything structural around them is hard. The colour says who
            // defends a face, not who aims at it -- the SCORE and DEFEND calls
            // beside them say that.
            faceNode.lineWidth = 4
            faceNode.glowWidth = 4
            arenaLayer.addChild(faceNode)
        }
        addGoalCalls()

        // The cap: solid, neutral, and the part of the net that bounces.
        let cap = CGMutablePath()
        cap.move(to: point(-half, arena.netBottomY))
        cap.addQuadCurve(
            to: point(half, arena.netBottomY),
            control: point(0, arena.netBottomY - 0.04)
        )
        let capNode = SKShapeNode(path: cap)
        capNode.strokeColor = .white
        capNode.lineWidth = 5
        capNode.glowWidth = 0
        arenaLayer.addChild(capNode)

        // The lips: a thin ledge under each face, drawn from the same two
        // points the ball rolls along, with a sliver of body underneath so it
        // reads as a shelf rather than a stray line.
        for sign in [-1.0, 1.0] {
            let root = arena.lipRoot(sign: sign)
            let tip = arena.lipTip(sign: sign)
            let body = CGMutablePath()
            body.move(to: point(root.x, root.y))
            body.addLine(to: point(tip.x, tip.y))
            body.addLine(to: point(tip.x, tip.y - 0.014))
            body.addLine(to: point(root.x, root.y - 0.014))
            body.closeSubpath()
            let bodyNode = SKShapeNode(path: body)
            bodyNode.strokeColor = .white.withAlphaComponent(0.85)
            bodyNode.lineWidth = 2
            bodyNode.fillColor = SKColor(white: 0.16, alpha: 1)
            arenaLayer.addChild(bodyNode)

            let ledge = CGMutablePath()
            ledge.move(to: point(root.x, root.y))
            ledge.addLine(to: point(tip.x, tip.y))
            let ledgeNode = SKShapeNode(path: ledge)
            ledgeNode.strokeColor = .white
            ledgeNode.lineWidth = 5
            ledgeNode.glowWidth = 0
            arenaLayer.addChild(ledgeNode)
        }
    }

    private func addSideLabel(_ text: String, team: Team, at position: CGPoint) {
        let label = SKLabelNode(text: text)
        label.fontName = "AvenirNextCondensed-Bold"
        label.fontSize = 11
        label.fontColor = (team == .cyan ? SKColor.cyan : .orange).withAlphaComponent(0.35)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = position
        label.zPosition = 1
        arenaLayer.addChild(label)
    }

    private func addSideLabel(for team: Team, at position: CGPoint) {
        let isLocal = team == localTeam
        let label = SKLabelNode(text: "\(team.rawValue.uppercased()) SIDE" + (isLocal ? " · YOU" : ""))
        label.fontName = "AvenirNextCondensed-Bold"
        // It was 11pt at 35%, which is part of why nobody could tell whose
        // end was whose.
        label.fontSize = 14
        label.fontColor = Self.color(team).withAlphaComponent(isLocal ? 0.8 : 0.5)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = position
        label.zPosition = 1
        arenaLayer.addChild(label)
    }

    /// SCORE beside the face this pilot shoots into and DEFEND beside their
    /// own, each on the side the ball has to come in from. The face on your
    /// half is yours to defend, so the one to score in is across the net --
    /// and changes with the ends between sets.
    private func addGoalCalls() {
        guard let localTeam, let snapshot else { return }
        let mouthY = (arena.portalMouthTopY + arena.netBottomY) / 2
        let attack = snapshot.attackFaceSign(of: localTeam)
        let defend = -attack
        // Each word is pinned at its inner edge and runs away from the net,
        // so it can never be drawn over the chevron whatever its width.
        func outward(_ sign: Double) -> SKLabelHorizontalAlignmentMode { sign > 0 ? .left : .right }

        let score = SKLabelNode(text: "SCORE")
        score.fontName = "AvenirNextCondensed-Heavy"
        score.fontSize = 15
        score.fontColor = .white.withAlphaComponent(0.92)
        score.horizontalAlignmentMode = outward(attack)
        score.verticalAlignmentMode = .center
        score.position = point(attack * (arena.netHalfWidth + 0.07), mouthY)
        score.zPosition = 1
        arenaLayer.addChild(score)

        // A chevron against the face, pointing into the goal.
        let tipX = attack * (arena.netHalfWidth + 0.02)
        let armX = attack * (arena.netHalfWidth + 0.045)
        let chevron = CGMutablePath()
        chevron.move(to: point(armX, mouthY + 0.035))
        chevron.addLine(to: point(tipX, mouthY))
        chevron.addLine(to: point(armX, mouthY - 0.035))
        let chevronNode = SKShapeNode(path: chevron)
        chevronNode.strokeColor = .white.withAlphaComponent(0.92)
        chevronNode.lineWidth = 3
        chevronNode.lineCap = .round
        chevronNode.lineJoin = .round
        chevronNode.zPosition = 1
        arenaLayer.addChild(chevronNode)

        let guardLabel = SKLabelNode(text: "DEFEND")
        guardLabel.fontName = "AvenirNextCondensed-Bold"
        guardLabel.fontSize = 13
        guardLabel.fontColor = Self.color(localTeam).withAlphaComponent(0.7)
        guardLabel.horizontalAlignmentMode = outward(defend)
        guardLabel.verticalAlignmentMode = .center
        guardLabel.position = point(defend * (arena.netHalfWidth + 0.035), mouthY)
        guardLabel.zPosition = 1
        arenaLayer.addChild(guardLabel)
    }

    private static func color(_ team: Team) -> SKColor {
        team == .cyan ? .cyan : .orange
    }

    /// The crossing limit on the given half: matched to the side that owns that half
    /// so court ownership is unambiguous.
    private func addCrossingLimit(for owningTeam: Team, onHalfAt sign: Double) {
        let x = sign * arena.opponentCrossingLimit
        let color = Self.color(owningTeam)
        let path = CGMutablePath()
        var y = arena.floorY + 0.04
        while y < arena.ceilingY {
            path.move(to: point(x, y))
            path.addLine(to: point(x, min(y + 0.045, arena.ceilingY)))
            y += 0.09
        }
        let marker = SKShapeNode(path: path)
        marker.strokeColor = color.withAlphaComponent(0.28)
        marker.lineWidth = 1.5
        marker.glowWidth = 1
        arenaLayer.addChild(marker)

        let label = SKLabelNode(text: "MAX CROSS")
        label.fontName = "AvenirNextCondensed-Bold"
        label.fontSize = 8
        label.fontColor = color.withAlphaComponent(0.45)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = point(x, 0.58)
        arenaLayer.addChild(label)
    }

    private func renderSnapshot() {
        guard let snapshot else { return }
        if snapshot.sidesSwapped != drawnSidesSwapped {
            drawnSidesSwapped = snapshot.sidesSwapped
            didBuild = false
        }
        if !didBuild { buildArena() }
        // The effects below run on wall time, not ticks: there is no update
        // loop, so each drawn snapshot is one frame, and a paused match that
        // stops sending snapshots simply stops them.
        let now = CACurrentMediaTime()
        let dt = lastRenderTime.map { min(0.05, max(0, now - $0)) } ?? 0
        lastRenderTime = now
        var lights: [FloorLight] = []
        ballGrips = Array(repeating: 0, count: snapshot.balls.count)
        for seat in Seat.allCases {
            update(seat: seat, state: snapshot.ships[seat], dt: dt, lights: &lights)
        }
        // Turn each seam by however far its ball spun since the last drawn
        // snapshot, counted in engine ticks so a guest that skips a few
        // draws still shows the turn it missed.
        let spunTicks = ballSpinTick.map { snapshot.tick > $0 ? Double(min(snapshot.tick - $0, 30)) : 0 } ?? 0
        ballSpinTick = snapshot.tick
        let tint = snapshot.lastBallToucher.map { Self.color($0) }
        let fx = labScale
        for (index, node) in balls.enumerated() {
            let ring = gripRings[index]
            guard index < snapshot.balls.count else {
                node.isHidden = true
                ring.isHidden = true
                continue
            }
            let ball = snapshot.balls[index]
            node.isHidden = false
            node.position = point(ball.position.x, ball.position.y)
            // The node is built 10pt in radius; scale it to the ball's world
            // radius so what you see is what the ship hits.
            node.setScale(CGFloat(ball.radius) * pointsPerWorldUnit / 10)
            node.spin(by: ball.spin * spunTicks * Self.tickDuration)
            // Ball tint by last touch (possession cue)
            node.tint(tint)
            // The beam's hold on the ball, drawn as a rim just outside it.
            let grip = ballGrips[index]
            ring.isHidden = grip <= 0
            if grip > 0 {
                let wobble = reduceMotion ? 0 : CGFloat(sin(now * 12)) * fx
                let radius = CGFloat(ball.radius) * pointsPerWorldUnit + 4 * fx + wobble
                ring.path = CGPath(
                    ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                    transform: nil
                )
                ring.position = node.position
                ring.alpha = 0.75 * CGFloat(grip)
            }
        }
        updateTrails(snapshot)
        updateBolts(snapshot, lights: &lights)
        updateShake(dt: dt)
        drawLights(lights, now: now)
    }

    /// How hard any beam has each ball this frame, 0 to 1.
    private var ballGrips: [Double] = []

    /// The FX Lab was laid out on a 904pt-wide court; every effect size and
    /// speed below is in its units and scaled by this to the real court.
    private var labScale: CGFloat { arenaRect.width / 904 }

    // MARK: - Floor lighting

    /// The grid texture, the crop mask that confines light to its lines, and
    /// the faint always-on copy. Rebuilt with the court, since the grid is
    /// laid on the court's own rectangle.
    private func buildLighting(in frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let step = 24 * frame.width / 904
        let image = UIGraphicsImageRenderer(size: frame.size).image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(1)
            var x: CGFloat = 0.5
            while x <= frame.width {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: frame.height))
                x += step
            }
            var y = frame.height - 0.5
            while y >= 0 {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: frame.width, y: y))
                y -= step
            }
            cg.strokePath()
        }
        let texture = SKTexture(image: image)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        gridBase.texture = texture
        gridBase.size = frame.size
        gridBase.position = centre
        let mask = SKSpriteNode(texture: texture, size: frame.size)
        mask.position = centre
        gridLightCrop.maskNode = mask
    }

    /// Darkens the corners of the whole view. Built at the view's size, since
    /// it frames the screen rather than the court.
    private func buildVignette() {
        guard size.width > 0, size.height > 0 else { return }
        let scale = size.width / 960
        let bounds = size
        let image = UIGraphicsImageRenderer(size: bounds).image { context in
            let edge = UIColor(red: 2 / 255, green: 3 / 255, blue: 8 / 255, alpha: 1)
            let colors = [edge.withAlphaComponent(0).cgColor, edge.withAlphaComponent(0.85 * Self.vignetteAmount).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            else { return }
            let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: centre,
                startRadius: 180 * scale,
                endCenter: centre,
                endRadius: 620 * scale,
                options: [.drawsAfterEndLocation]
            )
        }
        vignette.texture = SKTexture(image: image)
        vignette.size = bounds
        vignette.position = .zero
    }

    /// The lab's vignette pick.
    private static let vignetteAmount: CGFloat = 0.2

    private func addLight(at position: CGPoint, radius: CGFloat, color: SKColor, intensity: CGFloat = 1, life: TimeInterval) {
        transientLights.append(TransientLight(
            position: position,
            radius: radius,
            color: color,
            intensity: intensity,
            born: CACurrentMediaTime(),
            life: life
        ))
    }

    /// One pooled sprite pair per light: a wide one seen only through the
    /// grid lines, and a soft pool over the floor.
    private func drawLights(_ frameLights: [FloorLight], now: TimeInterval) {
        transientLights.removeAll { now - $0.born >= $0.life }
        var all = frameLights
        for light in transientLights {
            let fade = 1 - CGFloat((now - light.born) / light.life)
            all.append(FloorLight(position: light.position, radius: light.radius, color: light.color, intensity: light.intensity * fade))
        }
        while gridLightSprites.count < all.count {
            for (layer, isGrid) in [(gridLightLayer, true), (poolLightLayer, false)] {
                let sprite = SKSpriteNode(texture: Self.puffTexture)
                sprite.colorBlendFactor = 1
                sprite.blendMode = .add
                layer.addChild(sprite)
                if isGrid { gridLightSprites.append(sprite) } else { poolLightSprites.append(sprite) }
            }
        }
        let gain = Self.lightIntensity
        for index in gridLightSprites.indices {
            let grid = gridLightSprites[index]
            let pool = poolLightSprites[index]
            guard index < all.count else {
                grid.isHidden = true
                pool.isHidden = true
                continue
            }
            let light = all[index]
            grid.isHidden = false
            grid.position = light.position
            grid.size = CGSize(width: light.radius * 2.4, height: light.radius * 2.4)
            grid.color = light.color
            grid.alpha = min(1, 0.9 * light.intensity * gain)
            pool.isHidden = false
            pool.position = light.position
            pool.size = CGSize(width: light.radius * 1.6, height: light.radius * 1.6)
            pool.color = light.color
            pool.alpha = 0.07 * light.intensity * gain
        }
    }

    // MARK: - Shake

    /// Shake is in lab units; the whole court moves, the vignette does not.
    private func kick(_ amount: CGFloat) {
        guard !reduceMotion else { return }
        shakeAmount = max(shakeAmount, amount * Self.shakeGain * labScale)
    }

    private func updateShake(dt: Double) {
        guard !reduceMotion, shakeAmount > 0 else {
            shakeAmount = 0
            worldNode.position = .zero
            return
        }
        worldNode.position = CGPoint(
            x: .random(in: -shakeAmount ... shakeAmount),
            y: .random(in: -shakeAmount ... shakeAmount)
        )
        shakeAmount = max(0, shakeAmount - 30 * labScale * CGFloat(dt))
    }

    // MARK: - Bolts

    /// Bolts are keyed by simulation id so a node lives exactly as long as its
    /// bolt: a new id gets a muzzle flash, a vanished id gets a ring.
    /// Plasma: a team-coloured halo round a white-hot core, shedding
    /// afterimages as it goes.
    private func updateBolts(_ snapshot: WorldState, lights: inout [FloorLight]) {
        let fx = labScale
        var live = Set<UInt64>()
        for bolt in snapshot.bolts {
            live.insert(bolt.id)
            let position = point(bolt.position.x, bolt.position.y)
            let color = Self.color(bolt.owner)
            lights.append(FloorLight(position: position, radius: 85 * fx, color: color, intensity: 0.9))
            if let node = boltNodes[bolt.id] {
                node.position = position
                if !reduceMotion {
                    flash(at: position, color: color, size: 16 * fx, grow: 0.4, life: 0.14, alpha: 0.5)
                }
                continue
            }
            let node = SKNode()
            let halo = SKSpriteNode(texture: Self.puffTexture, size: CGSize(width: 34 * fx, height: 34 * fx))
            halo.color = color
            halo.colorBlendFactor = 1
            halo.blendMode = .add
            halo.alpha = 0.85
            node.addChild(halo)
            let core = SKSpriteNode(texture: Self.puffTexture, size: CGSize(width: 13 * fx, height: 13 * fx))
            core.blendMode = .add
            core.zPosition = 0.1
            node.addChild(core)
            node.zPosition = 6
            node.position = position
            actorLayer.addChild(node)
            boltNodes[bolt.id] = node
            SoundBank.shared.play(.boltFire, positionX: Float(bolt.position.x))
            addLight(at: position, radius: 120 * fx, color: color, life: 0.14)
            if !reduceMotion {
                flash(at: position, color: color, size: 70 * fx, grow: 1.6, life: 0.2, alpha: 1)
                flash(at: position, color: .white, size: 26 * fx, grow: 1.4, life: 0.1, alpha: 1)
            }
        }
        for (id, node) in boltNodes where !live.contains(id) {
            let color = (node.children.first as? SKSpriteNode)?.color ?? .white
            ring(at: node.position, color: color)
            addLight(at: node.position, radius: 130 * fx, color: color, life: 0.18)
            node.removeFromParent()
            boltNodes[id] = nil
        }
    }

    /// A bolt that struck the ball: a hot spot left on the floor where it hit,
    /// cooling over 1.2s, and a kick through the court.
    private func boltHit(at world: SIMD2<Double>) {
        let volume: Float = 1
        SoundBank.shared.play(.boltHit, positionX: Float(world.x), volume: volume)
        kick(4)
        guard !reduceMotion else { return }
        let fx = labScale
        let position = point(world.x, world.y)
        let color = snapshot?.lastBallToucher.map { Self.color($0) } ?? .white
        for (tone, size, alpha, curve) in [
            (color, 34 * fx, CGFloat(0.5), SKActionTimingMode.linear),
            (SKColor(red: 1, green: 0.94, blue: 0.86, alpha: 1), 10 * fx, CGFloat(0.6), .easeOut),
        ] {
            let decal = SKSpriteNode(texture: Self.puffTexture, size: CGSize(width: size, height: size))
            decal.color = tone
            decal.colorBlendFactor = 1
            decal.blendMode = .add
            decal.alpha = alpha
            decal.zPosition = -1
            decal.position = position
            plumeLayer.addChild(decal)
            let fade = SKAction.fadeOut(withDuration: 1.2)
            fade.timingMode = curve
            decal.run(.sequence([fade, .removeFromParent()]))
        }
    }

    private func ring(at position: CGPoint, color: SKColor) {
        guard !reduceMotion else { return }
        let fx = labScale
        let node = SKShapeNode(circleOfRadius: 6 * fx)
        node.strokeColor = color
        node.fillColor = .clear
        node.lineWidth = 4 * fx
        node.glowWidth = 0
        node.blendMode = .add
        node.zPosition = 21
        node.position = position
        actorLayer.addChild(node)
        let life = 0.3
        node.run(.sequence([
            .customAction(withDuration: life) { node, elapsed in
                guard let shape = node as? SKShapeNode else { return }
                let k = elapsed / CGFloat(life)
                let radius = (6 + 70 * k) * fx
                shape.path = CGPath(
                    ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                    transform: nil
                )
                shape.lineWidth = (4 * (1 - k) + 0.5) * fx
                shape.alpha = 1 - k
            },
            .removeFromParent(),
        ]))
    }

    private func flash(at position: CGPoint, color: SKColor, scale: CGFloat, life: TimeInterval) {
        let puff = SKSpriteNode(texture: Self.puffTexture)
        puff.color = color
        puff.colorBlendFactor = 1
        puff.blendMode = .add
        puff.zPosition = 5
        puff.position = position
        puff.setScale(scale)
        puff.alpha = 0.9
        actorLayer.addChild(puff)
        puff.run(.sequence([.group([.scale(by: 2.4, duration: life), .fadeOut(withDuration: life)]), .removeFromParent()]))
    }

    /// A lab-style flash: `size` across at birth, `grow` times that at death,
    /// fading out linearly, optionally drifting to `destination`.
    private func flash(
        at position: CGPoint,
        color: SKColor,
        size: CGFloat,
        grow: CGFloat,
        life: TimeInterval,
        alpha: CGFloat,
        z: CGFloat = 5,
        destination: CGPoint? = nil
    ) {
        let puff = SKSpriteNode(texture: Self.puffTexture, size: CGSize(width: size, height: size))
        puff.color = color
        puff.colorBlendFactor = 1
        puff.blendMode = .add
        puff.zPosition = z
        puff.position = position
        puff.alpha = alpha
        actorLayer.addChild(puff)
        var motion: [SKAction] = [.scale(to: grow, duration: life), .fadeOut(withDuration: life)]
        if let destination { motion.append(.move(to: destination, duration: life)) }
        puff.run(.sequence([.group(motion), .removeFromParent()]))
    }

    /// A spark thrown along `angle`: a team-coloured streak with a bright
    /// core, slowing under `drag` (the fraction of speed left after a second).
    private func streak(
        at position: CGPoint,
        angle: CGFloat,
        speed: CGFloat,
        life: TimeInterval,
        core: SKColor,
        halo: SKColor,
        drag: Double
    ) {
        let fx = labScale
        let length = max(2, speed * 0.035)
        let node = SKNode()
        node.position = position
        node.zRotation = angle
        node.zPosition = 22
        for (color, width, alpha) in [(halo, 2.4 * fx, CGFloat(0.9)), (core, max(0.6, fx), CGFloat(1))] {
            let line = SKSpriteNode(color: color, size: CGSize(width: length, height: width))
            // Anchored at the head, so the streak trails behind where it is going.
            line.anchorPoint = CGPoint(x: 1, y: 0.5)
            line.blendMode = .add
            line.alpha = alpha
            node.addChild(line)
        }
        actorLayer.addChild(node)
        let travel = speed * CGFloat((1 - pow(drag, life)) / log(1 / drag))
        let move = SKAction.move(by: CGVector(dx: cos(angle) * travel, dy: sin(angle) * travel), duration: life)
        move.timingMode = .easeOut
        node.run(.sequence([
            .group([move, .scaleX(to: 0.4, duration: life), .fadeOut(withDuration: life)]),
            .removeFromParent(),
        ]))
    }

    func present(_ events: [SimulationEvent]) {
        for event in events {
            switch event {
            case let .point(scoringTeam, reason):
                ballTrails.removeAll()
                if reason == .goal {
                    // One portal, dead centre -- the ball went through it and
                    // is gone, so the burst is where it vanished.
                    let goalCenterY = (arena.portalMouthTopY + arena.netBottomY) / 2
                    goalBurst(
                        at: point(0, goalCenterY),
                        color: scoringTeam == .cyan ? .cyan : .orange
                    )
                } else if let destroyed = snapshot?.ships.first(where: { $0.key.team == scoringTeam.opponent && $0.value.isDestroyed })?.value {
                    sparks(at: point(destroyed.position.x, destroyed.position.y), color: scoringTeam.opponent == .cyan ? .cyan : .orange)
                }
            case let .destruction(team, _):
                for (seat, ship) in snapshot?.ships ?? [:] where seat.team == team && ship.isDestroyed {
                    sparks(at: point(ship.position.x, ship.position.y), color: team == .cyan ? .cyan : .orange)
                }
            case let .collisionEffect(position, intensity):
                if intensity == boltPunch {
                    boltHit(at: position)
                } else {
                    impact(at: position, intensity: intensity)
                }
            case .rallyReset, .setEnded:
                ballTrails.removeAll()
            case .matchEnded:
                break
            }
        }
    }

    /// A contact, thrown as sparks along the bounce. The event carries no
    /// kind or normal, so both are read off the snapshot: an event on a ball
    /// is a ball contact, and the ship nearest it (if any is close) is the
    /// one that hit it; anything else is a ship off a wall, the hump or
    /// another ship, and flies off the way that ship is now going.
    private func impact(at world: SIMD2<Double>, intensity: Double) {
        guard let snapshot else { return }
        let fx = labScale
        let position = point(world.x, world.y)
        // The engine gates these at 0.25 world units a second; the lab gated
        // the same contacts at 90, so its speeds are the engine's times 360.
        let speed = CGFloat(intensity * 360)
        var normal: SIMD2<Double>?
        var team: Team?
        let nearestBall = snapshot.balls.min { simd_length($0.position - world) < simd_length($1.position - world) }
        let onBall = nearestBall.map { simd_length($0.position - world) <= $0.radius * 1.5 } ?? false
        let ships = snapshot.ships.filter { !$0.value.isDestroyed }
        if onBall, let ball = nearestBall {
            let closest = ships.min { simd_length($0.value.position - ball.position) < simd_length($1.value.position - ball.position) }
            if let (seat, ship) = closest, simd_length(ship.position - ball.position) < ball.radius + 0.12 {
                team = seat.team
                normal = ball.position - ship.position
            } else {
                normal = ball.velocity
            }
        } else if let (_, ship) = ships.min(by: { simd_length($0.value.position - world) < simd_length($1.value.position - world) }),
                  simd_length(ship.position - world) < 0.1 {
            normal = ship.velocity
        }
        SoundBank.shared.play(
            onBall ? .ballHit : .wallHit,
            positionX: Float(world.x),
            volume: Float(min(1, max(0.15, speed / 500)))
        )
        let tint = team.map { Self.color($0) } ?? .white
        addLight(at: position, radius: min(140, max(60, speed * 0.3)) * fx, color: onBall ? tint : .white, life: 0.12)
        kick(min(6, max(1, speed / 90)))
        guard !reduceMotion else { return }
        let aim = normal.flatMap { simd_length($0) > 1e-6 ? CGFloat(atan2($0.y, $0.x)) : nil }
        let count = Int(min(10, max(4, speed / 60)).rounded())
        for _ in 0 ..< count {
            let angle = aim.map { $0 + .random(in: -1 ... 1) } ?? .random(in: 0 ... 2 * .pi)
            streak(
                at: position,
                angle: angle,
                speed: .random(in: 150 ... 420) * min(1.4, max(0.5, speed / 400)) * fx,
                life: .random(in: 0.18 ... 0.34),
                core: .white,
                halo: tint,
                drag: 0.04
            )
        }
    }

    private func goalBurst(at position: CGPoint, color: SKColor) {
        let ring = SKShapeNode(circleOfRadius: 18)
        ring.position = position
        ring.strokeColor = color
        ring.lineWidth = 7
        ring.glowWidth = 16
        ring.zPosition = 20
        actorLayer.addChild(ring)
        let scale = reduceMotion ? 1.6 : 4.5
        ring.run(.sequence([.group([.scale(to: scale, duration: 0.42), .fadeOut(withDuration: 0.42)]), .removeFromParent()]))
    }

    private func sparks(at position: CGPoint, color: SKColor) {
        let count = reduceMotion ? 5 : 16
        for index in 0..<count {
            let spark = SKShapeNode(circleOfRadius: reduceMotion ? 2 : 3)
            spark.position = position
            spark.fillColor = color
            spark.strokeColor = .white
            spark.glowWidth = 5
            spark.zPosition = 22
            actorLayer.addChild(spark)
            let angle = Double(index) / Double(count) * Double.pi * 2
            let distance: CGFloat = reduceMotion ? 12 : CGFloat(34 + (index % 4) * 9)
            let destination = CGPoint(
                x: position.x + CGFloat(cos(angle)) * distance,
                y: position.y + CGFloat(sin(angle)) * distance
            )
            spark.run(.sequence([.group([.move(to: destination, duration: 0.34), .fadeOut(withDuration: 0.34)]), .removeFromParent()]))
        }
    }

    private func update(seat: Seat, state: ShipState?, dt: Double, lights: inout [FloorLight]) {
        guard let shipNode = shipNodes[seat], let exhaust = exhaustNodes[seat] else { return }
        let marker = markerNodes[seat]
        guard let state else {
            shipNode.isHidden = true
            marker?.isHidden = true
            beamRigs[seat]?.crop.isHidden = true
            beamRigs[seat]?.tether.isHidden = true
            beamPulls[seat] = nil
            return
        }
        shipNode.isHidden = state.isDestroyed
        if let marker {
            let doubles = (snapshot?.ships.count ?? 0) > 2
            let text: String? = !doubles || localSeat == nil ? nil
                : seat == localSeat ? "YOU" : seat == localSeat?.partner ? "ALLY" : nil
            marker.isHidden = text == nil || state.isDestroyed
            if let text {
                marker.text = text
                let spot = point(state.position.x, state.position.y)
                marker.position = CGPoint(x: spot.x, y: spot.y + 22)
            }
        }
        shipNode.position = point(state.position.x, state.position.y)
        shipNode.zRotation = state.angle - .pi / 2
        // Drawn at the scale the ball's hitbox is built at (`ShipHitbox`).
        shipNode.setScale(CGFloat(ShipHitbox.worldPerOutlineUnit) * pointsPerWorldUnit)
        shipNode.glowWidth = 8 + min(12, state.thrustLevel * 0.65)
        // `thrustLevel` is not a dial -- `thrustRampRate` is 0 and initial
        // thrust equals maximum, so it is either 0 or whatever the slider
        // says. The old `/ 18` normalisation therefore drew a flame sized
        // for a thrust nobody flies: at 2.75 it sat at 15% of its range.
        // Engine lit is now full size and full brightness; engine off keeps
        // a dim ember burning, because the nose is hardest to read while you
        // are rotating to line up a shot and there is no plume at all.
        // Not gated on reduceMotion -- the plume is, and this is the cue
        // that has to survive it.
        // Width is the hull's own character while the engine is lit, but the
        // idle ember is capped: across the eight hulls exhaustWidth spans
        // 0.75...2.1, and at 2.1 a soft radial puff 63pt wide reads as a
        // blob the size of the ship rather than a nozzle. The facing cue has
        // to look the same whatever you fly.
        let thrusting = state.thrustLevel > 0
        let hullWidth = exhaustWidths[seat] ?? 1
        exhaust.isHidden = state.isDestroyed
        exhaust.xScale = thrusting ? hullWidth : min(hullWidth, 1)
        exhaust.yScale = thrusting ? 2.0 : 0.62
        exhaust.alpha = thrusting ? 1 : 0.38
        // The hot core, flickering in length while the engine is lit.
        for core in fireCores[seat] ?? [] {
            core.isHidden = !thrusting || state.isDestroyed
            core.xScale = hullWidth
            core.yScale = reduceMotion ? 1 : .random(in: 0.8 ... 1.2)
        }
        if !state.isDestroyed {
            let fx = labScale
            let nozzle = worldNode.convert(CGPoint(x: 0, y: -16), from: shipNode)
            if thrusting {
                let glow = worldNode.convert(CGPoint(x: 0, y: -38), from: shipNode)
                lights.append(FloorLight(position: glow, radius: 120 * fx, color: Self.color(seat.team), intensity: 0.9))
            } else {
                lights.append(FloorLight(position: nozzle, radius: 40 * fx, color: Self.color(seat.team), intensity: 0.35))
            }
        }
        emitSmoke(from: shipNode, seat: seat, state: state, dt: dt)
        updateBeam(seat: seat, state: state, dt: dt, lights: &lights)
    }

    /// The flow beam: a violet cone brightest at the nose, with motes pouring
    /// in toward the ship, and a tether and a rim on the ball it has hold of.
    /// The cone is the one the engine grabs with -- both numbers come from
    /// the engine; nothing here re-states the geometry.
    private func updateBeam(seat: Seat, state: ShipState, dt: Double, lights: inout [FloorLight]) {
        guard let rig = beamRigs[seat] else { return }
        guard state.tractorActive, !state.isDestroyed, let snapshot else {
            rig.crop.isHidden = true
            rig.tether.isHidden = true
            beamPulls[seat] = nil
            return
        }
        let fx = labScale
        let gain = Self.beamGain
        let range = tractorRange
        let cone = SimulationEngine.tractorCone
        let halfAngle = acos(cone)
        let nose = state.angle
        let heading = SIMD2(cos(nose), sin(nose))
        let tip = state.position
        let left = tip + SIMD2(cos(nose + halfAngle), sin(nose + halfAngle)) * range
        let mid = tip + heading * (range * 1.08)
        let right = tip + SIMD2(cos(nose - halfAngle), sin(nose - halfAngle)) * range
        let path = CGMutablePath()
        path.move(to: point(tip.x, tip.y))
        path.addLine(to: point(left.x, left.y))
        path.addQuadCurve(to: point(right.x, right.y), control: point(mid.x, mid.y))
        path.closeSubpath()
        rig.mask.path = path
        rig.crop.isHidden = false
        let tipPoint = point(tip.x, tip.y)
        let reach = point(tip.x + range * 1.08, tip.y + range * 1.08)
        rig.glow.position = tipPoint
        rig.glow.size = CGSize(width: 2 * (reach.x - tipPoint.x), height: 2 * (reach.y - tipPoint.y))

        // Grip: strongest close in and dead ahead, nothing outside the cone.
        var grip = 0.0
        var held: Int?
        for (index, ball) in snapshot.balls.enumerated() {
            let offset = ball.position - tip
            let distance = simd_length(offset)
            guard distance > 0, distance < range else { continue }
            let along = simd_dot(offset / distance, heading)
            guard along > cone else { continue }
            let hold = (1 - distance / range) * ((along - cone) / (1 - cone))
            if hold > grip { grip = hold; held = index }
        }
        beamPulls[seat] = BeamPull(grip: grip, x: tip.x)
        let centre = tip + heading * (range * 0.5)
        lights.append(FloorLight(
            position: point(centre.x, centre.y),
            radius: 110 * fx,
            color: Self.beamColor,
            intensity: 0.35 + 0.5 * CGFloat(grip)
        ))

        if let held, grip > 0 {
            ballGrips[held] = max(ballGrips[held], grip)
            let ball = snapshot.balls[held].position
            let ahead = point(tip.x + heading.x, tip.y + heading.y)
            let span = hypot(ahead.x - tipPoint.x, ahead.y - tipPoint.y)
            let from = CGPoint(
                x: tipPoint.x + (ahead.x - tipPoint.x) / span * 18 * fx,
                y: tipPoint.y + (ahead.y - tipPoint.y) / span * 18 * fx
            )
            let to = point(ball.x, ball.y)
            let now = CACurrentMediaTime()
            let wobble: CGFloat = reduceMotion ? 0 : 6 * fx
            let tether = CGMutablePath()
            tether.move(to: from)
            tether.addQuadCurve(to: to, control: CGPoint(
                x: (from.x + to.x) / 2 + CGFloat(sin(now * 9)) * wobble,
                y: (from.y + to.y) / 2 + CGFloat(cos(now * 7)) * wobble
            ))
            rig.tether.path = tether
            rig.tether.alpha = 0.45 * CGFloat(grip) * gain
            rig.tether.isHidden = false
        } else {
            rig.tether.isHidden = true
        }

        guard !reduceMotion else { return }
        // Motes pour in from the far part of the cone toward the nose,
        // carried along with the ship.
        let pointsPerUnit = pointsPerWorldUnit
        rig.budget += dt * 120
        while rig.budget >= 1 {
            rig.budget -= 1
            let angle = nose + .random(in: -halfAngle ... halfAngle)
            let reachOut = Double.random(in: 0.6 ... 1) * range
            let start = point(tip.x + cos(angle) * reachOut, tip.y + sin(angle) * reachOut)
            let distance = hypot(start.x - tipPoint.x, start.y - tipPoint.y)
            let speed = CGFloat.random(in: 180 ... 280) * fx
            let life = TimeInterval(distance / max(speed, 1))
            let end = CGPoint(
                x: tipPoint.x + CGFloat(state.velocity.x) * pointsPerUnit * CGFloat(life),
                y: tipPoint.y + CGFloat(state.velocity.y) * pointsPerUnit * CGFloat(life)
            )
            let size = CGFloat.random(in: 5 ... 9) * fx
            flash(
                at: start,
                color: Double.random(in: 0 ... 1) < 0.2 ? .white : Self.beamColor,
                size: size,
                grow: 0.2,
                life: life,
                alpha: 0.5 * gain,
                z: 3.1,
                destination: end
            )
        }
    }

    /// Fire and smoke: the burn throws grey smoke back along the nose axis
    /// (drawn with ordinary alpha, which is what makes it read as smoke and
    /// not light) with a few hot sparks; an idle engine lets a thin wisp
    /// rise. Density tracks wall time, not frame rate.
    private func emitSmoke(from shipNode: SKShapeNode, seat: Seat, state: ShipState, dt: Double) {
        guard !reduceMotion, !state.isDestroyed, dt > 0 else { return }
        let fx = labScale
        let density = Self.smokeDensity
        let thrusting = state.thrustLevel > 0
        var budget = (smokeBudgets[seat] ?? 0) + dt * (thrusting ? 26 : 3 * density)
        let nozzle = worldNode.convert(CGPoint(x: 0, y: -16), from: shipNode)
        let back = CGVector(dx: -cos(state.angle), dy: -sin(state.angle))
        let pointsPerUnit = pointsPerWorldUnit
        let carried = CGVector(dx: CGFloat(state.velocity.x) * pointsPerUnit, dy: CGFloat(state.velocity.y) * pointsPerUnit)
        while budget >= 1 {
            budget -= 1
            if thrusting {
                let push = CGFloat.random(in: 60 ... 110) * fx
                smokePuff(
                    at: CGPoint(
                        x: nozzle.x + back.dx * 10 * fx + .random(in: -3 ... 3) * fx,
                        y: nozzle.y + back.dy * 10 * fx + .random(in: -3 ... 3) * fx
                    ),
                    velocity: CGVector(
                        dx: back.dx * push + carried.dx * 0.25 + .random(in: -15 ... 15) * fx,
                        dy: back.dy * push + carried.dy * 0.25 + .random(in: -15 ... 15) * fx
                    ),
                    size: .random(in: 9 ... 14) * fx,
                    grow: .random(in: 4 ... 6),
                    life: .random(in: 1.1 ... 1.6),
                    peak: 0.2 * CGFloat(density),
                    rise: 0.12,
                    drag: 0.9
                )
                if Double.random(in: 0 ... 1) < 0.35 {
                    let thrown = CGVector(
                        dx: back.dx * .random(in: 160 ... 300) * fx + .random(in: -40 ... 40) * fx,
                        dy: back.dy * .random(in: 160 ... 300) * fx + .random(in: -40 ... 40) * fx
                    )
                    streak(
                        at: nozzle,
                        angle: atan2(thrown.dy, thrown.dx),
                        speed: hypot(thrown.dx, thrown.dy),
                        life: .random(in: 0.12 ... 0.25),
                        core: SKColor(red: 1, green: 0.9, blue: 0.71, alpha: 1),
                        halo: Self.color(seat.team),
                        drag: 0.05
                    )
                }
            } else {
                smokePuff(
                    at: nozzle,
                    velocity: CGVector(dx: .random(in: -8 ... 8) * fx, dy: .random(in: 4 ... 14) * fx),
                    size: 6 * fx,
                    grow: 4,
                    life: 1.4,
                    peak: 0.1 * CGFloat(density),
                    rise: 0.3,
                    drag: 0.95
                )
            }
        }
        smokeBudgets[seat] = budget
    }

    private func smokePuff(
        at position: CGPoint,
        velocity: CGVector,
        size: CGFloat,
        grow: CGFloat,
        life: TimeInterval,
        peak: CGFloat,
        rise: Double,
        drag: Double
    ) {
        let puff = SKSpriteNode(texture: Self.smokeTexture, size: CGSize(width: size, height: size))
        puff.color = Self.smokeColor
        puff.colorBlendFactor = 1
        puff.blendMode = .alpha
        puff.alpha = 0
        puff.zPosition = -2.5
        puff.position = position
        plumeLayer.addChild(puff)
        // Distance covered by a velocity that keeps `drag` of itself a second.
        let travel = CGFloat((1 - pow(drag, life)) / log(1 / drag))
        let move = SKAction.move(by: CGVector(dx: velocity.dx * travel, dy: velocity.dy * travel), duration: life)
        move.timingMode = .easeOut
        puff.run(.sequence([
            .group([
                move,
                .scale(to: grow, duration: life),
                .sequence([
                    .fadeAlpha(to: peak, duration: life * rise),
                    .fadeOut(withDuration: life * (1 - rise)),
                ]),
            ]),
            .removeFromParent(),
        ]))
    }

    private static let smokeColor = SKColor(red: 0.50, green: 0.53, blue: 0.61, alpha: 1)

    /// Soft radial falloff, built once. Sprites are far cheaper than one
    /// SKShapeNode per puff, and a gradient reads as vapour rather than a disc.
    private static let puffTexture = radialTexture(stops: [(0, 1), (0.45, 0.35), (1, 0)])
    /// Smoke keeps more body further out than a light does.
    private static let smokeTexture = radialTexture(stops: [(0, 0.9), (0.55, 0.45), (1, 0)])
    /// The beam's cone fill: full at the nose, a seventh of that at the rim.
    private static let beamGradientTexture = radialTexture(stops: [(0, 1), (1, 0.03 / 0.22)], clipOutside: true)

    private static func radialTexture(stops: [(CGFloat, CGFloat)], clipOutside: Bool = false) -> SKTexture {
        let side: CGFloat = 64
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = stops.map { UIColor(white: 1, alpha: $0.1).cgColor } as CFArray
            var locations = stops.map(\.0)
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: &locations
            ) else { return }
            let centre = CGPoint(x: side / 2, y: side / 2)
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: centre,
                startRadius: 0,
                endCenter: centre,
                endRadius: side / 2,
                options: clipOutside ? [] : []
            )
        }
        return SKTexture(image: image)
    }

    private func updateTrails(_ snapshot: WorldState) {
        guard !reduceMotion else {
            trailLayer.removeAllChildren()
            plumeLayer.removeAllChildren()
            ballTrails.removeAll()
            return
        }
        if ballTrails.count != snapshot.balls.count {
            ballTrails = Array(repeating: [], count: snapshot.balls.count)
        }
        trailLayer.removeAllChildren()
        let trailColor: SKColor = snapshot.lastBallToucher.map { Self.color($0) } ?? .white
        for (index, ball) in snapshot.balls.enumerated() {
            ballTrails[index].append(point(ball.position.x, ball.position.y))
            ballTrails[index] = Array(ballTrails[index].suffix(16))
            let ballTrailNode = trail(points: ballTrails[index], color: trailColor)
            ballTrailNode.lineWidth = 2 + min(6, hypot(ball.velocity.x, ball.velocity.y) * 0.25)
            ballTrailNode.glowWidth = 0
            trailLayer.addChild(ballTrailNode)
        }
    }

    private func trail(points: [CGPoint], color: SKColor) -> SKShapeNode {
        let path = CGMutablePath()
        if let first = points.first { path.move(to: first) }
        for point in points.dropFirst() { path.addLine(to: point) }
        let node = SKShapeNode(path: path)
        node.strokeColor = color.withAlphaComponent(0.32)
        node.lineWidth = 3
        node.glowWidth = 0
        return node
    }

    /// Swaps the drawn silhouette without touching the simulation: every hull
    /// shares one collision envelope. Both scales of the exhaust are driven
    /// per frame by thrust; the width is recorded here for that.
    func setHull(_ hull: Hull, for seat: Seat) {
        guard let ship = shipNodes[seat], let exhaust = exhaustNodes[seat] else { return }
        ship.path = hull.spec.outline.cgPath
        exhaustWidths[seat] = CGFloat(hull.spec.exhaustWidth)
        exhaust.xScale = CGFloat(hull.spec.exhaustWidth)
    }

    /// Mostly aspect-fit, blended toward stretch-to-fill (the old iPhone
    /// look) so the court still fills more of a tall/wide view instead of
    /// full letterboxing. `stretchAmount` 0 = pure aspect-fit, 1 = old
    /// independently-scaled stretch; tuned closer to the iPhone side.
    private var arenaRect: CGRect { Self.arenaRect(in: size, arena: arena) }

    /// Centred on the scene origin. Also used by the touch controls to find
    /// the margins either side of the court, so the pads and the drawn
    /// court can never disagree about where its edge is.
    static func arenaRect(in size: CGSize, arena: ArenaGeometry = .standard) -> CGRect {
        let inset = min(size.width, size.height) * 0.055
        let availableWidth = size.width - inset * 2
        let availableHeight = size.height - inset * 2
        let worldWidth = arena.halfWidth * 2
        let worldHeight = arena.ceilingY - arena.floorY
        let scaleX = availableWidth / CGFloat(worldWidth)
        let scaleY = availableHeight / CGFloat(worldHeight)
        let uniform = min(scaleX, scaleY)
        let stretchAmount: CGFloat = 0.6
        let blendedScaleX = uniform + (scaleX - uniform) * stretchAmount
        let blendedScaleY = uniform + (scaleY - uniform) * stretchAmount
        // In landscape the outer strips are the thumb pads' home: the court
        // never grows into them, so a thumb in the corner reaches the pads
        // without ever having to cross the court's edge.
        let landscape = size.width > size.height
        let sideInset = landscape ? max(inset, size.width * controlMarginFraction) : inset
        let width = min(CGFloat(worldWidth) * blendedScaleX, size.width - sideInset * 2)
        let height = CGFloat(worldHeight) * blendedScaleY
        return CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    }

    /// Share of the window width kept clear of the court on each side in
    /// landscape, safe area included. Sized so a pad still fits beside an
    /// iPhone's rounded corners.
    static let controlMarginFraction: CGFloat = 0.20

    /// Points per world unit for things drawn round (ball, hulls). The court
    /// is stretched a little differently on each axis; the geometric mean
    /// splits that so a hit from the side and one from above both look close.
    private var pointsPerWorldUnit: CGFloat {
        let rect = arenaRect
        let x = rect.width / CGFloat(arena.halfWidth * 2)
        let y = rect.height / CGFloat(arena.ceilingY - arena.floorY)
        return (x * y).squareRoot()
    }

    /// Derived from the geometry rather than hardcoded, so shortening the
    /// court cannot silently desync the render from the simulation.
    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let rect = arenaRect
        let worldWidth = arena.halfWidth * 2
        let worldHeight = arena.ceilingY - arena.floorY
        return CGPoint(x: rect.midX + CGFloat(x / worldWidth) * rect.width,
                       y: rect.midY + CGFloat(y / worldHeight) * rect.height)
    }
}

/// The ball as drawn: an opaque body, a machined rim, a lit face turned
/// up-left and a seam that turns with the spin. It is built to read as a
/// hard object -- no glow anywhere on it, because a halo blurs the very edge
/// you are trying to hit. Built 10pt in radius and scaled to the world.
final class BallNode: SKShapeNode {
    /// The one mark on the ball that turns with it. The lit face and the
    /// shine stay where the light is; only the seam shows the spin.
    private let seam = SKShapeNode()
    private var spinAngle = 0.0

    override init() {
        super.init()
        path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        fillColor = SKColor(white: 0.72, alpha: 1)
        strokeColor = SKColor(white: 0.30, alpha: 1)
        lineWidth = 2
        glowWidth = 0
        // The lit face: a second disc offset toward the light. Two flat tones
        // with a crisp step between them read as a sphere without any blur.
        let lit = SKShapeNode(circleOfRadius: 8)
        lit.position = CGPoint(x: -1.4, y: 1.7)
        lit.fillColor = SKColor(white: 0.97, alpha: 1)
        lit.strokeColor = .clear
        lit.glowWidth = 0
        // The view ignores sibling order, so the layers on the ball are
        // stacked by z rather than by the order they were added.
        lit.zPosition = 0.1
        addChild(lit)
        // The seam: an S across the face, dark enough to read on both tones.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -8.2, y: 0))
        path.addCurve(
            to: CGPoint(x: 8.2, y: 0),
            control1: CGPoint(x: -3, y: 6.5),
            control2: CGPoint(x: 3, y: -6.5)
        )
        seam.path = path
        seam.strokeColor = SKColor(white: 0.36, alpha: 0.9)
        seam.lineWidth = 2
        seam.lineCap = .round
        seam.glowWidth = 0
        seam.zPosition = 0.2
        addChild(seam)
        // The S looks the same after half a turn, so on its own a spinning
        // ball can look still. One dot in one lobe breaks the symmetry.
        let mark = SKShapeNode(circleOfRadius: 1.8)
        mark.position = CGPoint(x: -4.2, y: -3.4)
        mark.fillColor = SKColor(white: 0.30, alpha: 0.95)
        mark.strokeColor = .clear
        mark.glowWidth = 0
        seam.addChild(mark)
        // The specular: small, hard, and off to one side.
        let shine = SKShapeNode(circleOfRadius: 2.6)
        shine.position = CGPoint(x: -3.6, y: 4.2)
        shine.fillColor = .white
        shine.strokeColor = .clear
        shine.glowWidth = 0
        shine.zPosition = 0.3
        addChild(shine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func spin(by radians: Double) {
        guard radians != 0 else { return }
        spinAngle = (spinAngle + radians).truncatingRemainder(dividingBy: 2 * .pi)
        seam.zRotation = CGFloat(spinAngle)
    }

    /// Rim colour by whoever touched a ball last: the possession cue.
    func tint(_ color: SKColor?) {
        if let color {
            strokeColor = color.withAlphaComponent(0.95)
            lineWidth = 3
        } else {
            strokeColor = SKColor(white: 0.30, alpha: 1)
            lineWidth = 2
        }
        glowWidth = 0
    }
}
