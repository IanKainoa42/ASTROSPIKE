import ASTROSPIKECore
import SpriteKit
import UIKit

@MainActor
final class ArenaScene: SKScene {
    var snapshot: WorldState? { didSet { renderSnapshot() } }
    var reduceMotion = false

    private let arenaLayer = SKNode()
    private let trailLayer = SKNode()
    private let plumeLayer = SKNode()
    private let actorLayer = SKNode()
    private let arena = ArenaGeometry.standard
    private let cyanShip = SKShapeNode()
    private let orangeShip = SKShapeNode()
    private let cyanExhaust = SKShapeNode(rectOf: CGSize(width: 9, height: 24), cornerRadius: 4)
    private let orangeExhaust = SKShapeNode(rectOf: CGSize(width: 9, height: 24), cornerRadius: 4)
    private let ball = SKShapeNode(circleOfRadius: 10)
    private var cyanTrail: [CGPoint] = []
    private var orangeTrail: [CGPoint] = []
    private var ballTrail: [CGPoint] = []
    private var cyanPlumeBudget = 0.0
    private var orangePlumeBudget = 0.0
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
        actorLayer.addChild(cyanShip)
        actorLayer.addChild(orangeShip)
        actorLayer.addChild(ball)
        configureActorNodes()
    }

    required init?(coder aDecoder: NSCoder) { nil }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        didBuild = false
        buildArena()
        renderSnapshot()
    }

    private func configureActorNodes() {
        cyanShip.path = shipPath(symbol: .cyan)
        cyanShip.fillColor = .cyan
        cyanShip.strokeColor = .white
        cyanShip.lineWidth = 1.5
        cyanShip.glowWidth = 8
        orangeShip.path = shipPath(symbol: .orange)
        orangeShip.fillColor = .orange
        orangeShip.strokeColor = .white
        orangeShip.lineWidth = 1.5
        orangeShip.glowWidth = 8
        for (ship, exhaust, color) in [
            (cyanShip, cyanExhaust, SKColor.cyan),
            (orangeShip, orangeExhaust, SKColor.orange),
        ] {
            exhaust.position = CGPoint(x: 0, y: -29)
            // Lancet burns a tight needle, Anvil a wide chunky wash. yScale is
            // driven per frame by thrust, so only xScale is set here.
            exhaust.xScale = ship === cyanShip ? 0.75 : 1.9
            exhaust.fillColor = .white
            exhaust.strokeColor = color
            exhaust.lineWidth = 3
            exhaust.glowWidth = 10
            exhaust.zPosition = -1
            exhaust.isHidden = true
            ship.addChild(exhaust)
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
        floor.addLine(to: point(-arena.moundBaseX, arena.floorY))
        floor.move(to: point(arena.moundBaseX, arena.floorY))
        floor.addLine(to: point(arena.cornerTangentX, arena.floorY))
        let floorNode = SKShapeNode(path: floor)
        floorNode.strokeColor = .white.withAlphaComponent(0.55)
        floorNode.lineWidth = 4
        floorNode.glowWidth = 3
        arenaLayer.addChild(floorNode)

        addMound()
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

    /// The hill the net stands on: the corner fillet mirrored into the middle,
    /// walked from the same samples the simulation collides against so the
    /// drawn slope cannot drift from the one balls ramp off.
    private func addMound() {
        let profile = arena.moundProfile

        let hill = CGMutablePath()
        hill.move(to: point(-profile.last!.x, arena.floorY))
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
    /// front of you. The cap on top is hard and neutral -- white, not team
    /// coloured -- because clipping it rebounds rather than scoring.
    private func addPortalNet() {
        let half = arena.netHalfWidth
        let sill = arena.portalMouthFloorY

        // The plinth: the part of the slab standing on the crest, below the
        // mouth. Solid and neutral, like the cap.
        let plinth = CGMutablePath()
        plinth.move(to: point(-half, arena.moundCrestY))
        plinth.addLine(to: point(-half, sill))
        plinth.addLine(to: point(half, sill))
        plinth.addLine(to: point(half, arena.moundCrestY))
        plinth.closeSubpath()
        let plinthNode = SKShapeNode(path: plinth)
        plinthNode.strokeColor = .white.withAlphaComponent(0.55)
        plinthNode.lineWidth = 2
        plinthNode.fillColor = SKColor(white: 0.16, alpha: 1)
        arenaLayer.addChild(plinthNode)

        // The mouth: a dark slot the ball disappears into.
        let mouth = CGMutablePath()
        mouth.move(to: point(-half, sill))
        mouth.addLine(to: point(-half, arena.netTopY))
        mouth.addLine(to: point(half, arena.netTopY))
        mouth.addLine(to: point(half, sill))
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
            face.move(to: point(half * sign, sill))
            face.addLine(to: point(half * sign, arena.netTopY))
            let faceNode = SKShapeNode(path: face)
            faceNode.strokeColor = color.withAlphaComponent(0.9)
            faceNode.lineWidth = 4
            faceNode.glowWidth = 14
            arenaLayer.addChild(faceNode)
        }

        // The crown: solid, neutral, and the only part of the net that bounces.
        let cap = CGMutablePath()
        cap.move(to: point(-half, arena.netTopY))
        cap.addQuadCurve(
            to: point(half, arena.netTopY),
            control: point(0, arena.netTopY + 0.04)
        )
        let capNode = SKShapeNode(path: cap)
        capNode.strokeColor = .white.withAlphaComponent(0.95)
        capNode.lineWidth = 4
        capNode.glowWidth = 6
        arenaLayer.addChild(capNode)
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
        update(shipNode: cyanShip, team: .cyan, state: snapshot.ships[.cyan])
        update(shipNode: orangeShip, team: .orange, state: snapshot.ships[.orange])
        ball.position = point(snapshot.ball.position.x, snapshot.ball.position.y)
        let ballScale = CGFloat(snapshot.ball.radius / 0.038)
        ball.setScale(ballScale)
        ball.glowWidth = 12 + min(20, hypot(snapshot.ball.velocity.x, snapshot.ball.velocity.y))
        updateTrails(snapshot)
    }

    func present(_ events: [SimulationEvent]) {
        for event in events {
            switch event {
            case let .point(scoringTeam, reason):
                ballTrail.removeAll()
                if reason == .goal {
                    // One portal, dead centre -- the ball went through it and
                    // is gone, so the burst is where it vanished.
                    let goalCenterY = (arena.portalMouthFloorY + arena.netTopY) / 2
                    goalBurst(
                        at: point(0, goalCenterY),
                        color: scoringTeam == .cyan ? .cyan : .orange
                    )
                } else if let destroyed = snapshot?.ships[scoringTeam.opponent] {
                    sparks(at: point(destroyed.position.x, destroyed.position.y), color: scoringTeam.opponent == .cyan ? .cyan : .orange)
                }
            case let .destruction(team, _):
                if let ship = snapshot?.ships[team] { sparks(at: point(ship.position.x, ship.position.y), color: team == .cyan ? .cyan : .orange) }
            case let .collisionEffect(position, _):
                sparks(at: point(position.x, position.y), color: .white)
            case .rallyReset:
                ballTrail.removeAll()
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

    private func update(shipNode: SKShapeNode, team: Team, state: ShipState?) {
        guard let state else { shipNode.isHidden = true; return }
        shipNode.isHidden = state.isDestroyed
        shipNode.position = point(state.position.x, state.position.y)
        shipNode.zRotation = state.angle - .pi / 2
        let unit = min(arenaRect.width / 2, arenaRect.height) / 1.7
        shipNode.setScale(unit / 473)
        shipNode.glowWidth = 8 + min(12, state.thrustLevel * 0.65)
        let exhaust = team == .cyan ? cyanExhaust : orangeExhaust
        exhaust.isHidden = state.thrustLevel <= 0 || state.isDestroyed
        exhaust.yScale = 0.35 + CGFloat(state.thrustLevel / 18) * 1.65
        exhaust.alpha = 0.55 + CGFloat(state.thrustLevel / 18) * 0.45
        emitPlume(from: shipNode, team: team, state: state)
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
    private func emitPlume(from shipNode: SKShapeNode, team: Team, state: ShipState) {
        guard !reduceMotion, !state.isDestroyed, state.thrustLevel > 0 else { return }
        var budget = (team == .cyan ? cyanPlumeBudget : orangePlumeBudget)
            + state.thrustLevel * 0.022
        while budget >= 1 {
            budget -= 1
            spawnPuff(from: shipNode, team: team, state: state)
        }
        if team == .cyan { cyanPlumeBudget = budget } else { orangePlumeBudget = budget }
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
            cyanTrail.removeAll()
            orangeTrail.removeAll()
            ballTrail.removeAll()
            return
        }
        if let cyan = snapshot.ships[.cyan], !cyan.isDestroyed { cyanTrail.append(point(cyan.position.x, cyan.position.y)) }
        if let orange = snapshot.ships[.orange], !orange.isDestroyed { orangeTrail.append(point(orange.position.x, orange.position.y)) }
        ballTrail.append(point(snapshot.ball.position.x, snapshot.ball.position.y))
        cyanTrail = Array(cyanTrail.suffix(22))
        orangeTrail = Array(orangeTrail.suffix(22))
        ballTrail = Array(ballTrail.suffix(16))
        trailLayer.removeAllChildren()
        trailLayer.addChild(trail(points: cyanTrail, color: .cyan))
        trailLayer.addChild(trail(points: orangeTrail, color: .orange))
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

    /// Two hulls with genuinely different silhouettes, not one dart with a
    /// different decal. Both stay inside roughly the same envelope so the
    /// three collision fixtures in the simulation still read true.
    private func shipPath(symbol: Team) -> CGPath {
        symbol == .cyan ? lancetPath() : anvilPath()
    }

    /// Cyan "Lancet" — narrow interceptor: raked needle nose, swept wings that
    /// hook forward at the tips, split tail.
    private func lancetPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 30))
        path.addLine(to: CGPoint(x: 3.5, y: 14))
        path.addLine(to: CGPoint(x: 7, y: 1))
        path.addLine(to: CGPoint(x: 21, y: -16))
        path.addLine(to: CGPoint(x: 14, y: -19))
        path.addLine(to: CGPoint(x: 6, y: -11))
        path.addLine(to: CGPoint(x: 0, y: -15))
        path.addLine(to: CGPoint(x: -6, y: -11))
        path.addLine(to: CGPoint(x: -14, y: -19))
        path.addLine(to: CGPoint(x: -21, y: -16))
        path.addLine(to: CGPoint(x: -7, y: 1))
        path.addLine(to: CGPoint(x: -3.5, y: 14))
        path.closeSubpath()

        // Canopy slit along the spine.
        path.move(to: CGPoint(x: 0, y: 16))
        path.addLine(to: CGPoint(x: 0, y: 4))
        return path
    }

    /// Orange "Anvil" — heavy lander: blunt chisel nose, boxy shoulders and two
    /// outboard engine pods hanging wide off the hull.
    private func anvilPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -7, y: 26))
        path.addLine(to: CGPoint(x: 7, y: 26))
        path.addLine(to: CGPoint(x: 13, y: 12))
        path.addLine(to: CGPoint(x: 11, y: -2))
        path.addLine(to: CGPoint(x: 21, y: -4))
        path.addLine(to: CGPoint(x: 22, y: -19))
        path.addLine(to: CGPoint(x: 12, y: -19))
        path.addLine(to: CGPoint(x: 9, y: -9))
        path.addLine(to: CGPoint(x: -9, y: -9))
        path.addLine(to: CGPoint(x: -12, y: -19))
        path.addLine(to: CGPoint(x: -22, y: -19))
        path.addLine(to: CGPoint(x: -21, y: -4))
        path.addLine(to: CGPoint(x: -11, y: -2))
        path.addLine(to: CGPoint(x: -13, y: 12))
        path.closeSubpath()

        // Hex viewport.
        path.move(to: CGPoint(x: 0, y: 18))
        path.addLine(to: CGPoint(x: 6, y: 13))
        path.addLine(to: CGPoint(x: 6, y: 5))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: -6, y: 5))
        path.addLine(to: CGPoint(x: -6, y: 13))
        path.closeSubpath()
        return path
    }

    private var arenaRect: CGRect {
        let inset = min(size.width, size.height) * 0.055
        return CGRect(x: -size.width / 2 + inset, y: -size.height / 2 + inset,
                      width: size.width - inset * 2, height: size.height - inset * 2)
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
