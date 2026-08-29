import ASTROSPIKECore
import SpriteKit

@MainActor
final class ArenaScene: SKScene {
    var snapshot: WorldState? { didSet { renderSnapshot() } }
    var reduceMotion = false

    private let arenaLayer = SKNode()
    private let trailLayer = SKNode()
    private let actorLayer = SKNode()
    private let arena = ArenaGeometry.standard
    private let cyanShip = SKShapeNode()
    private let orangeShip = SKShapeNode()
    private let cyanExhaust = SKShapeNode(rectOf: CGSize(width: 9, height: 24), cornerRadius: 4)
    private let orangeExhaust = SKShapeNode(rectOf: CGSize(width: 9, height: 24), cornerRadius: 4)
    private let ball = SKShapeNode(circleOfRadius: 12)
    private var cyanTrail: [CGPoint] = []
    private var orangeTrail: [CGPoint] = []
    private var ballTrail: [CGPoint] = []
    private var didBuild = false

    override init(size: CGSize = CGSize(width: 960, height: 540)) {
        super.init(size: size)
        backgroundColor = SKColor(red: 0.015, green: 0.025, blue: 0.07, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(arenaLayer)
        addChild(trailLayer)
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

        let bounds = CGMutablePath()
        bounds.move(to: point(-arena.halfWidth, arena.floorY))
        bounds.addLine(to: point(-arena.halfWidth, arena.ceilingY))
        bounds.addLine(to: point(arena.halfWidth, arena.ceilingY))
        bounds.addLine(to: point(arena.halfWidth, arena.floorY))
        let wall = SKShapeNode(path: bounds)
        wall.strokeColor = SKColor(white: 0.8, alpha: 0.45)
        wall.lineWidth = 3
        wall.glowWidth = 5
        arenaLayer.addChild(wall)

        let floor = CGMutablePath()
        floor.move(to: point(-arena.halfWidth, arena.floorY))
        floor.addLine(to: point(-arena.goalOuterX, arena.floorY))
        floor.move(to: point(arena.goalOuterX, arena.floorY))
        floor.addLine(to: point(arena.halfWidth, arena.floorY))
        let floorNode = SKShapeNode(path: floor)
        floorNode.strokeColor = .white.withAlphaComponent(0.55)
        floorNode.lineWidth = 4
        floorNode.glowWidth = 3
        arenaLayer.addChild(floorNode)

        addGoal(defender: .cyan)
        addGoal(defender: .orange)
        let netPath = CGMutablePath()
        let netLeftBottom = point(-arena.netHalfWidth, arena.floorY)
        let netLeftTop = point(-arena.netHalfWidth, arena.netTopY)
        let netRightTop = point(arena.netHalfWidth, arena.netTopY)
        let netRightBottom = point(arena.netHalfWidth, arena.floorY)
        netPath.move(to: netLeftBottom)
        netPath.addLine(to: netLeftTop)
        netPath.addQuadCurve(to: netRightTop, control: point(0, arena.netTopY + 0.04))
        netPath.addLine(to: netRightBottom)
        netPath.closeSubpath()
        let net = SKShapeNode(path: netPath)
        net.strokeColor = SKColor(red: 0.75, green: 0.35, blue: 1, alpha: 1)
        net.fillColor = SKColor(red: 0.18, green: 0.02, blue: 0.35, alpha: 0.75)
        net.lineWidth = 2
        net.glowWidth = 10
        arenaLayer.addChild(net)
    }

    private func addGoal(defender: Team) {
        let sign = defender == .cyan ? -1.0 : 1.0
        let mouthTopY = arena.floorY + (arena.goalOuterX - arena.goalInnerX)
        let path = CGMutablePath()
        path.move(to: point(arena.goalInnerX * sign, arena.floorY))
        path.addLine(to: point(arena.goalOuterX * sign, mouthTopY))
        path.addLine(to: point(arena.goalOuterX * sign, arena.floorY))
        let goal = SKShapeNode(path: path)
        goal.strokeColor = defender == .cyan ? .cyan : .orange
        goal.lineWidth = 5
        goal.glowWidth = 11
        arenaLayer.addChild(goal)

        let lip = SKShapeNode(rectOf: CGSize(width: 8, height: 18), cornerRadius: 3)
        lip.position = point(arena.goalOuterX * sign, arena.floorY + 0.03)
        lip.fillColor = defender == .cyan ? .cyan : .orange
        lip.strokeColor = .white
        arenaLayer.addChild(lip)
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
        let ballScale = CGFloat(snapshot.ball.radius / 0.045)
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
                    let defendingGoalX = scoringTeam == .cyan
                        ? arena.goalOuterX
                        : -arena.goalOuterX
                    let goalCenterY = arena.floorY
                        + (arena.goalOuterX - arena.goalInnerX) / 2
                    goalBurst(
                        at: point(defendingGoalX, goalCenterY),
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
        shipNode.setScale(unit / 350)
        shipNode.glowWidth = 8 + min(12, state.thrustLevel * 0.65)
        let exhaust = team == .cyan ? cyanExhaust : orangeExhaust
        exhaust.isHidden = state.thrustLevel <= 0 || state.isDestroyed
        exhaust.yScale = 0.35 + CGFloat(state.thrustLevel / 18) * 1.65
        exhaust.alpha = 0.55 + CGFloat(state.thrustLevel / 18) * 0.45
    }

    private func updateTrails(_ snapshot: WorldState) {
        guard !reduceMotion else {
            trailLayer.removeAllChildren()
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

    private func shipPath(symbol: Team) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 28))
        path.addLine(to: CGPoint(x: -18, y: -18))
        path.addLine(to: CGPoint(x: 0, y: -10))
        path.addLine(to: CGPoint(x: 18, y: -18))
        path.closeSubpath()
        if symbol == .orange {
            path.addEllipse(in: CGRect(x: -5, y: -3, width: 10, height: 10))
        } else {
            path.move(to: CGPoint(x: -7, y: 2))
            path.addLine(to: CGPoint(x: 7, y: 2))
        }
        return path
    }

    private var arenaRect: CGRect {
        let inset = min(size.width, size.height) * 0.055
        return CGRect(x: -size.width / 2 + inset, y: -size.height / 2 + inset,
                      width: size.width - inset * 2, height: size.height - inset * 2)
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let rect = arenaRect
        return CGPoint(x: rect.midX + CGFloat(x / 1.92) * rect.width,
                       y: rect.midY + CGFloat(y / 1.56) * rect.height)
    }
}
