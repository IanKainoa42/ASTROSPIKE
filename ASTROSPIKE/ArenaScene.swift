import ASTROSPIKECore
import SpriteKit
import UIKit

@MainActor
final class ArenaScene: SKScene {
    var snapshot: WorldState? { didSet { renderSnapshot() } }
    var reduceMotion = false
    /// Warm-up bay hoops. Empty in a real match.
    var rings: [WarmupRing] = [] { didSet { renderRings() } }
    private var ringNodes: [UInt64: SKShapeNode] = [:]

    private let arenaLayer = SKNode()
    private let trailLayer = SKNode()
    private let plumeLayer = SKNode()
    private let actorLayer = SKNode()
    private let arena = ArenaGeometry.standard
    /// One hull and one exhaust per seat, built up front and hidden while
    /// the seat is empty.
    private var shipNodes: [Seat: SKShapeNode] = [:]
    private var exhaustNodes: [Seat: SKSpriteNode] = [:]
    private let ball = SKShapeNode(circleOfRadius: 10)
    private var boltNodes: [UInt64: SKNode] = [:]
    private var ballTrail: [CGPoint] = []
    private var wakeAnchors: [Seat: CGPoint] = [:]
    private var plumeBudgets: [Seat: Double] = [:]
    private var plumeSeed = 0
    private var didBuild = false

    override init(size: CGSize = CGSize(width: 960, height: 540)) {
        super.init(size: size)
        backgroundColor = SKColor(red: 0.015, green: 0.025, blue: 0.07, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(arenaLayer)
        addChild(trailLayer)
        addChild(plumeLayer)
        addChild(actorLayer)
        for seat in Seat.allCases {
            let ship = SKShapeNode()
            let exhaust = SKSpriteNode(texture: ArenaScene.puffTexture, size: CGSize(width: 30, height: 34))
            shipNodes[seat] = ship
            exhaustNodes[seat] = exhaust
            actorLayer.addChild(ship)
        }
        actorLayer.addChild(ball)
        configureActorNodes()
    }

    required init?(coder aDecoder: NSCoder) { nil }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
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
        case .cyan: .cyan
        case .orange: .orange
        case .cyanWing: SKColor(red: 0.62, green: 0.92, blue: 1, alpha: 1)
        case .orangeWing: SKColor(red: 1, green: 0.80, blue: 0.50, alpha: 1)
        }
    }

    private func configureActorNodes() {
        for seat in Seat.allCases {
            guard let ship = shipNodes[seat], let exhaust = exhaustNodes[seat] else { continue }
            let color = Self.hullColor(for: seat)
            ship.fillColor = color
            ship.strokeColor = .white
            ship.lineWidth = seat.isWing ? 2.5 : 1.5
            ship.glowWidth = 8
            ship.isHidden = true
            // A soft vapour sprite hung from the tail, anchored at its top so
            // yScale stretches it backwards along the nose axis as throttle rises.
            exhaust.anchorPoint = CGPoint(x: 0.5, y: 1)
            exhaust.position = CGPoint(x: 0, y: -16)
            exhaust.color = color
            exhaust.colorBlendFactor = 0.6
            exhaust.blendMode = .add
            exhaust.zPosition = -1
            exhaust.isHidden = true
            ship.addChild(exhaust)
            setHull(Hull.defaultHull(forSeat: seat), for: seat)
        }
        ball.fillColor = .white
        ball.strokeColor = SKColor(red: 0.65, green: 0.95, blue: 1, alpha: 1)
        ball.lineWidth = 3
        ball.glowWidth = 12
    }

    private func buildArena() {
        guard !didBuild, size.width > 0, size.height > 0 else { return }
        didBuild = true
        arenaLayer.removeAllChildren()
        let frame = arenaRect

        let cyanZone = SKShapeNode(rect: CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width / 2,
            height: frame.height
        ))
        cyanZone.fillColor = .cyan.withAlphaComponent(0.025)
        cyanZone.strokeColor = .clear
        arenaLayer.addChild(cyanZone)
        let orangeZone = SKShapeNode(rect: CGRect(
            x: frame.midX,
            y: frame.minY,
            width: frame.width / 2,
            height: frame.height
        ))
        orangeZone.fillColor = .orange.withAlphaComponent(0.025)
        orangeZone.strokeColor = .clear
        arenaLayer.addChild(orangeZone)

        addSideLabel("CYAN SIDE", team: .cyan, at: point(-0.72, 0.68))
        addSideLabel("ORANGE SIDE", team: .orange, at: point(0.72, 0.68))
        addCrossingLimit(for: .cyan)
        addCrossingLimit(for: .orange)

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
        wall.glowWidth = 5
        arenaLayer.addChild(wall)

        let floor = CGMutablePath()
        floor.move(to: point(-arena.cornerTangentX, arena.floorY))
        floor.addLine(to: point(arena.cornerTangentX, arena.floorY))
        let floorNode = SKShapeNode(path: floor)
        floorNode.strokeColor = .white.withAlphaComponent(0.55)
        floorNode.lineWidth = 4
        floorNode.glowWidth = 3
        arenaLayer.addChild(floorNode)

        addHump()
        addPortalNet()
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
        edge.glowWidth = 3
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
            let scorer: Team = sign < 0 ? .cyan : .orange
            let color: SKColor = scorer == .cyan ? .cyan : .orange
            let face = CGMutablePath()
            face.move(to: point(half * sign, collarBottom))
            face.addLine(to: point(half * sign, arena.netBottomY))
            let faceNode = SKShapeNode(path: face)
            faceNode.strokeColor = color.withAlphaComponent(0.9)
            faceNode.lineWidth = 4
            faceNode.glowWidth = 14
            arenaLayer.addChild(faceNode)
        }

        // The cap: solid, neutral, and the part of the net that bounces.
        let cap = CGMutablePath()
        cap.move(to: point(-half, arena.netBottomY))
        cap.addQuadCurve(
            to: point(half, arena.netBottomY),
            control: point(0, arena.netBottomY - 0.04)
        )
        let capNode = SKShapeNode(path: cap)
        capNode.strokeColor = .white.withAlphaComponent(0.95)
        capNode.lineWidth = 4
        capNode.glowWidth = 6
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
            bodyNode.strokeColor = .white.withAlphaComponent(0.55)
            bodyNode.lineWidth = 2
            bodyNode.fillColor = SKColor(white: 0.16, alpha: 1)
            arenaLayer.addChild(bodyNode)

            let ledge = CGMutablePath()
            ledge.move(to: point(root.x, root.y))
            ledge.addLine(to: point(tip.x, tip.y))
            let ledgeNode = SKShapeNode(path: ledge)
            ledgeNode.strokeColor = .white.withAlphaComponent(0.95)
            ledgeNode.lineWidth = 4
            ledgeNode.glowWidth = 6
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

    private func addCrossingLimit(for intrudingTeam: Team) {
        let x = intrudingTeam == .cyan
            ? arena.opponentCrossingLimit
            : -arena.opponentCrossingLimit
        let color: SKColor = intrudingTeam == .cyan ? .cyan : .orange
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
        marker.glowWidth = 3
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
        if !didBuild { buildArena() }
        for seat in Seat.allCases { update(seat: seat, state: snapshot.ships[seat]) }
        ball.position = point(snapshot.ball.position.x, snapshot.ball.position.y)
        let ballScale = CGFloat(snapshot.ball.radius / 0.038)
        ball.setScale(ballScale)
        ball.glowWidth = 12 + min(20, hypot(snapshot.ball.velocity.x, snapshot.ball.velocity.y))
        updateTrails(snapshot)
        updateBolts(snapshot)
    }

    /// Bolts are keyed by simulation id so a node lives exactly as long as its
    /// bolt: a new id gets a muzzle flash, a vanished id gets a fizzle.
    private func updateBolts(_ snapshot: WorldState) {
        var live = Set<UInt64>()
        for bolt in snapshot.bolts {
            live.insert(bolt.id)
            let position = point(bolt.position.x, bolt.position.y)
            let heading = CGFloat(atan2(bolt.velocity.y, bolt.velocity.x)) - .pi / 2
            if let node = boltNodes[bolt.id] {
                node.position = position
                node.zRotation = heading
                continue
            }
            let color: SKColor = bolt.owner == .cyan ? .cyan : .orange
            let node = SKShapeNode(rectOf: CGSize(width: 5, height: 18), cornerRadius: 2.5)
            node.fillColor = .white
            node.strokeColor = color
            node.lineWidth = 2
            node.glowWidth = 9
            node.zPosition = 6
            node.position = position
            node.zRotation = heading
            actorLayer.addChild(node)
            boltNodes[bolt.id] = node
            if !reduceMotion { flash(at: position, color: color, scale: 0.9, life: 0.16) }
        }
        for (id, node) in boltNodes where !live.contains(id) {
            if !reduceMotion { flash(at: node.position, color: .white, scale: 0.5, life: 0.22) }
            node.removeFromParent()
            boltNodes[id] = nil
        }
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

    func present(_ events: [SimulationEvent]) {
        for event in events {
            switch event {
            case let .point(scoringTeam, reason):
                ballTrail.removeAll()
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
            case let .collisionEffect(position, _):
                sparks(at: point(position.x, position.y), color: .white)
            case .rallyReset, .setEnded:
                ballTrail.removeAll()
                wakeAnchors.removeAll()
            case .matchEnded:
                break
            }
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

    private func update(seat: Seat, state: ShipState?) {
        guard let shipNode = shipNodes[seat], let exhaust = exhaustNodes[seat] else { return }
        guard let state else { shipNode.isHidden = true; return }
        shipNode.isHidden = state.isDestroyed
        shipNode.position = point(state.position.x, state.position.y)
        shipNode.zRotation = state.angle - .pi / 2
        let unit = min(arenaRect.width / 2, arenaRect.height) / 1.7
        shipNode.setScale(unit / 473)
        shipNode.glowWidth = 8 + min(12, state.thrustLevel * 0.65)
        exhaust.isHidden = state.thrustLevel <= 0 || state.isDestroyed
        exhaust.yScale = 0.35 + CGFloat(state.thrustLevel / 18) * 1.65
        exhaust.alpha = 0.55 + CGFloat(state.thrustLevel / 18) * 0.45
        emitPlume(from: shipNode, seat: seat, state: state)
        emitWake(from: shipNode, seat: seat, state: state)
    }

    /// A drifting ship leaves vapour rather than a pen line: one soft puff
    /// every few points of travel, laid down where the ship was and left to
    /// swell and fade in place.
    private func emitWake(from shipNode: SKShapeNode, seat: Seat, state: ShipState) {
        guard !reduceMotion, !state.isDestroyed else { return }
        let here = shipNode.position
        let spacing: CGFloat = 5
        guard let anchor = wakeAnchors[seat] else {
            wakeAnchors[seat] = here
            return
        }
        let travelled = hypot(here.x - anchor.x, here.y - anchor.y)
        guard travelled >= spacing else { return }
        wakeAnchors[seat] = here
        let team = seat.team
        plumeSeed &+= 1
        let jitter = Double((plumeSeed &* 7919) % 199) / 199 - 0.5
        let scale = Double(shipNode.xScale)
        let puff = SKSpriteNode(texture: Self.puffTexture)
        puff.color = team == .cyan
            ? SKColor(red: 0.45, green: 0.8, blue: 1, alpha: 1)
            : SKColor(red: 1, green: 0.66, blue: 0.38, alpha: 1)
        puff.colorBlendFactor = 1
        puff.blendMode = .add
        puff.zPosition = -3
        puff.alpha = 0
        puff.setScale(CGFloat(scale * (0.42 + jitter * 0.12)))
        puff.position = CGPoint(x: here.x + CGFloat(jitter * 3), y: here.y - CGFloat(jitter * 3))
        plumeLayer.addChild(puff)
        let life = 0.62 + jitter * 0.12
        puff.run(.sequence([
            .group([
                .scale(by: 2.2, duration: life),
                .sequence([
                    .fadeAlpha(to: 0.22, duration: life * 0.12),
                    .fadeOut(withDuration: life * 0.88),
                ]),
            ]),
            .removeFromParent(),
        ]))
    }

    /// Soft radial falloff, built once. Sprites are far cheaper than one
    /// SKShapeNode per puff, and a gradient reads as vapour rather than a disc.
    private static let puffTexture: SKTexture = {
        let side: CGFloat = 64
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = [
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 0.35).cgColor,
                UIColor(white: 1, alpha: 0).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.45, 1]
            ) else { return }
            let centre = CGPoint(x: side / 2, y: side / 2)
            context.cgContext.drawRadialGradient(
                gradient,
                startCenter: centre,
                startRadius: 0,
                endCenter: centre,
                endRadius: side / 2,
                options: []
            )
        }
        return SKTexture(image: image)
    }()

    /// Spends a thrust-proportional budget so puff density tracks throttle
    /// instead of frame rate, then trails smoke back along the nose axis.
    private func emitPlume(from shipNode: SKShapeNode, seat: Seat, state: ShipState) {
        guard !reduceMotion, !state.isDestroyed, state.thrustLevel > 0 else { return }
        var budget = (plumeBudgets[seat] ?? 0) + state.thrustLevel * 0.022
        while budget >= 1 {
            budget -= 1
            spawnPuff(from: shipNode, team: seat.team, state: state)
        }
        plumeBudgets[seat] = budget
    }

    private func spawnPuff(from shipNode: SKShapeNode, team: Team, state: ShipState) {
        plumeSeed &+= 1
        let jitter = Double((plumeSeed &* 7919) % 199) / 199 - 0.5
        let drift = Double((plumeSeed &* 104_729) % 173) / 173 - 0.5

        let scale = Double(shipNode.xScale)
        let origin = convert(CGPoint(x: 0, y: -34), from: shipNode)
        let back = (x: -cos(state.angle), y: -sin(state.angle))
        let side = (x: -sin(state.angle), y: cos(state.angle))
        let travel = (32 + state.thrustLevel * 2.4) * scale
        let spread = (11 + state.thrustLevel * 1.1) * scale

        let puff = SKSpriteNode(texture: Self.puffTexture)
        puff.color = team == .cyan
            ? SKColor(red: 0.55, green: 0.86, blue: 1, alpha: 1)
            : SKColor(red: 1, green: 0.72, blue: 0.42, alpha: 1)
        puff.colorBlendFactor = 1
        puff.blendMode = .add
        puff.zPosition = -2
        puff.alpha = 0
        puff.setScale(CGFloat(scale * (0.32 + jitter * 0.1 + state.thrustLevel * 0.012)))
        puff.position = CGPoint(
            x: origin.x + CGFloat(side.x * 4 * jitter * scale),
            y: origin.y + CGFloat(side.y * 4 * jitter * scale)
        )
        plumeLayer.addChild(puff)

        let destination = CGPoint(
            x: origin.x + CGFloat(back.x * travel + side.x * spread * drift),
            y: origin.y + CGFloat(back.y * travel + side.y * spread * drift)
        )
        let life = 0.52 + jitter * 0.14 + state.thrustLevel * 0.012
        puff.run(.sequence([
            .group([
                .move(to: destination, duration: life),
                .scale(by: 3.1, duration: life),
                .sequence([
                    .fadeAlpha(to: 0.32, duration: life * 0.16),
                    .fadeOut(withDuration: life * 0.84),
                ]),
            ]),
            .removeFromParent(),
        ]))
    }

    private func updateTrails(_ snapshot: WorldState) {
        guard !reduceMotion else {
            trailLayer.removeAllChildren()
            plumeLayer.removeAllChildren()
            ballTrail.removeAll()
            wakeAnchors.removeAll()
            return
        }
        ballTrail.append(point(snapshot.ball.position.x, snapshot.ball.position.y))
        ballTrail = Array(ballTrail.suffix(16))
        trailLayer.removeAllChildren()
        let ballTrailNode = trail(points: ballTrail, color: .white)
        ballTrailNode.lineWidth = 2 + min(6, hypot(snapshot.ball.velocity.x, snapshot.ball.velocity.y) * 0.25)
        ballTrailNode.glowWidth = 8
        trailLayer.addChild(ballTrailNode)
    }

    private func trail(points: [CGPoint], color: SKColor) -> SKShapeNode {
        let path = CGMutablePath()
        if let first = points.first { path.move(to: first) }
        for point in points.dropFirst() { path.addLine(to: point) }
        let node = SKShapeNode(path: path)
        node.strokeColor = color.withAlphaComponent(0.32)
        node.lineWidth = 3
        node.glowWidth = 5
        return node
    }

    /// Swaps the drawn silhouette without touching the simulation: every hull
    /// shares one collision envelope. yScale of the exhaust is driven per
    /// frame by thrust, so only its width is set here.
    func setHull(_ hull: Hull, for seat: Seat) {
        guard let ship = shipNodes[seat], let exhaust = exhaustNodes[seat] else { return }
        ship.path = hull.spec.outline.cgPath
        exhaust.xScale = CGFloat(hull.spec.exhaustWidth)
    }

    /// Aspect-fit (not stretch-to-fill): the court keeps the same on-screen
    /// proportions on every device, so a wide Mac window and a tall iPhone
    /// screen show the same shape instead of independently squashed axes.
    private var arenaRect: CGRect {
        let inset = min(size.width, size.height) * 0.055
        let availableWidth = size.width - inset * 2
        let availableHeight = size.height - inset * 2
        let worldWidth = arena.halfWidth * 2
        let worldHeight = arena.ceilingY - arena.floorY
        let scale = min(availableWidth / CGFloat(worldWidth), availableHeight / CGFloat(worldHeight))
        let width = CGFloat(worldWidth) * scale
        let height = CGFloat(worldHeight) * scale
        return CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
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
