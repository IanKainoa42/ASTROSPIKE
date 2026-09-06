import ASTROSPIKECore
import CoreGraphics
import SwiftUI

extension HullOutline {
    /// Ship-frame path in the renderer's native units (+y is the nose), for
    /// SpriteKit. Details are appended as extra subpaths so a single
    /// `SKShapeNode` strokes hull and canopy together, as the originals did.
    var cgPath: CGPath {
        let path = CGMutablePath()
        path.addLines(between: silhouette.map { CGPoint(x: $0.x, y: $0.y) })
        path.closeSubpath()
        for detail in details {
            path.addLines(between: detail.points.map { CGPoint(x: $0.x, y: $0.y) })
            if detail.closed { path.closeSubpath() }
        }
        return path
    }
}

/// A hull drawn the way the arena draws it: team fill, white stroke, glow.
/// Used by the hangar, the intro and the home screen, so the ship a pilot
/// picks is exactly the ship they will fly.
struct HullBadge: View {
    let hull: Hull
    var team: Team = .cyan
    var glow = true

    var body: some View {
        Canvas { context, size in
            let envelope = HullOutline.envelope
            let spanX = envelope.maxX - envelope.minX
            let spanY = envelope.maxY - envelope.minY
            let scale = min(size.width / spanX, size.height / spanY) * 0.86
            let midX = (envelope.minX + envelope.maxX) / 2
            let midY = (envelope.minY + envelope.maxY) / 2
            func map(_ point: SIMD2<Double>) -> CGPoint {
                CGPoint(x: size.width / 2 + (point.x - midX) * scale,
                        y: size.height / 2 - (point.y - midY) * scale)
            }
            let outline = hull.spec.outline
            var body = Path()
            body.addLines(outline.silhouette.map(map))
            body.closeSubpath()

            let color = team == .cyan ? Color.cyan : Color.orange
            if glow {
                context.addFilter(.shadow(color: color.opacity(0.9), radius: max(6, scale * 2.2)))
            }
            context.fill(body, with: .color(color))
            context.stroke(body, with: .color(.white), lineWidth: max(1, scale * 0.45))
            for detail in outline.details {
                var path = Path()
                path.addLines(detail.points.map(map))
                if detail.closed { path.closeSubpath() }
                context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: max(1, scale * 0.4))
            }
        }
        .accessibilityLabel("\(hull.spec.name) hull")
    }
}
