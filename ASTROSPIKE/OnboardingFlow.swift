import ASTROSPIKECore
import SwiftUI

/// First-launch intro: four pages, then the hangar, then straight into a
/// rookie match. Every page can be skipped; the whole thing can be replayed
/// from Settings.
struct OnboardingFlow: View {
    @Bindable var profile: PilotProfileStore
    let entitlements: HullEntitlements
    let store: HullStore
    /// Called when the pilot is done. `true` means launch a rookie match now.
    let finish: (_ launchRookieMatch: Bool) -> Void

    @State private var page = Self.launchPage
    private let pageCount = 5

    /// `--intro-page N` opens the intro on a given page, for screenshots.
    private static var launchPage: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--intro-page"),
              arguments.indices.contains(index + 1),
              let page = Int(arguments[index + 1]) else { return 0 }
        return max(0, min(4, page))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                progress
                Spacer()
                Button("SKIP") { complete(launch: false) }
                    .font(.caption.weight(.black)).tracking(2)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("onboarding-skip")
            }
            .padding(.horizontal, 28).padding(.top, 18)

            TabView(selection: $page) {
                welcome.tag(0)
                fly.tag(1)
                score.tag(2)
                rules.tag(3)
                hangar.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeOut(duration: 0.25), value: page)

            HStack(spacing: 12) {
                if page > 0 {
                    Button {
                        page -= 1
                    } label: {
                        Label("BACK", systemImage: "chevron.left")
                            .font(.caption.weight(.black)).tracking(1)
                            .frame(minWidth: 110, minHeight: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-back")
                }
                Spacer()
                if page < pageCount - 1 {
                    Button {
                        page += 1
                        FeedbackCenter.shared.tap()
                    } label: {
                        Label("NEXT", systemImage: "chevron.right")
                            .labelStyle(.trailingIcon)
                            .font(.headline.weight(.black)).tracking(1)
                            .frame(minWidth: 180, minHeight: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent).tint(.cyan)
                    .accessibilityIdentifier("onboarding-next")
                } else {
                    Button {
                        complete(launch: false)
                    } label: {
                        Text("TO THE MENU")
                            .font(.caption.weight(.black)).tracking(1)
                            .frame(minWidth: 130, minHeight: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-menu")
                    Button {
                        complete(launch: true)
                    } label: {
                        Label("FLY A ROOKIE MATCH", systemImage: "flame.fill")
                            .font(.headline.weight(.black)).tracking(1)
                            .frame(minWidth: 220, minHeight: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .accessibilityIdentifier("onboarding-launch")
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 20)
        }
        .accessibilityIdentifier("onboarding-screen")
    }

    private func complete(launch: Bool) {
        profile.hasCompletedOnboarding = true
        finish(launch)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index <= page ? Color.cyan : .white.opacity(0.18))
                    .frame(width: index == page ? 26 : 12, height: 4)
            }
        }
        .accessibilityLabel("Intro page \(page + 1) of \(pageCount)")
    }

    // MARK: Pages

    private var welcome: some View {
        IntroPage(kicker: "WELCOME, PILOT") {
            (Text("ASTRO").foregroundStyle(.cyan) + Text("SPIKE").foregroundStyle(.orange))
                .font(.system(size: 56, weight: .black, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
            Text("Zero-G volleyball with rockets. Two ships, one ball, one goal hanging from the roof. No brakes, no wrecks, first to seven.")
                .font(.title3).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        } side: {
            HStack(spacing: 28) {
                HullBadge(hull: profile.selectedHull, team: .cyan).frame(width: 120, height: 130)
                Text("VS").font(.caption.monospaced().bold()).foregroundStyle(.white.opacity(0.35))
                HullBadge(hull: .anvil, team: .orange).frame(width: 120, height: 130)
            }
        }
    }

    private var fly: some View {
        IntroPage(kicker: "01 • FLY") {
            Text("STEER, THRUST, FIRE, PULL.")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            IntroLine(icon: "arrow.left.and.right", tint: .cyan, title: "STEER", text: "Hold left or right to rotate. Let go and the nose stays where it is.")
            IntroLine(icon: "flame.fill", tint: .orange, title: "THRUST", text: "Hold to burn. Gravity pulls you down the whole time, and your exhaust shoves the ball.")
            IntroLine(icon: "bolt.fill", tint: .yellow, title: "FIRE", text: "Tap to shoot a bolt from the nose. It knocks the ball where you point and counts as a touch.")
            IntroLine(icon: "arrow.down.to.line.compact", tint: .purple, title: "PULL", text: "Hold to reel the ball in with the tractor beam. Not a touch until it lands on your hull.")
            // Phones almost never have a keyboard and do not have the height
            // for a fourth line; iPads and Macs get the hint.
            if UIDevice.current.userInterfaceIdiom != .phone {
                IntroLine(icon: "keyboard", tint: .white.opacity(0.8), title: "KEYBOARD", text: "A and D steer, W thrusts, space fires, S pulls. Touch and keys work together.")
            }
        } side: {
            ControlsDiagram()
        }
    }

    private var score: some View {
        IntroPage(kicker: "02 • SCORE") {
            Text("THE GOAL IS A PORTAL.")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            IntroLine(icon: "shield.lefthalf.filled", tint: .cyan, title: "DEFEND YOUR FACE", text: "The side of the goal facing you is yours. Ball goes in there, they score.")
            IntroLine(icon: "arrow.up.right", tint: .orange, title: "SPIKE THEIRS", text: "Lift the ball over the net and put it through the far face. Or make them put it in their own.")
            IntroLine(icon: "tray.and.arrow.down.fill", tint: .white.opacity(0.8), title: "THE LIP", text: "A ledge under each face tilts inward. Drop the ball on the far lip and it rolls in.")
        } side: {
            GoalDiagram()
        }
    }

    private var rules: some View {
        IntroPage(kicker: "03 • RULES") {
            Text("THREE TOUCHES. ONE BOUNCE.")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            IntroLine(icon: "hand.tap.fill", tint: .cyan, title: "TOUCHES", text: "Your hull may touch the ball three times per trip. A fourth touch is their point.")
            IntroLine(icon: "circle.bottomhalf.filled", tint: .orange, title: "BOUNCES", text: "The ball may bounce on your floor once between touches. Twice and it’s theirs.")
            IntroLine(icon: "burst.fill", tint: .white.opacity(0.8), title: "NO WRECKS", text: "Walls, floor, roof and the other ship all just rebound. Only the ball scores.")
        } side: {
            RulesDiagram()
        }
    }

    private var hangar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("04 • HANGAR").font(.caption.monospaced().weight(.black)).tracking(3)
                .foregroundStyle(.white.opacity(0.55))
            Text("PICK YOUR HULL.")
                .font(.system(size: 30, weight: .black, design: .rounded))
            HangarView(profile: profile, entitlements: entitlements, store: store, compact: true)
        }
        .padding(.horizontal, 28).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IntroPage<Content: View, Side: View>: View {
    let kicker: String
    @ViewBuilder let content: Content
    @ViewBuilder let side: Side

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            // A phone in landscape has less height than these pages need, so
            // the column scrolls rather than losing its last line under the
            // BACK and NEXT buttons.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(kicker).font(.caption.monospaced().weight(.black)).tracking(3)
                        .foregroundStyle(.white.opacity(0.55))
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            side
                .frame(maxWidth: 340)
        }
        .padding(.horizontal, 28).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IntroLine: View {
    let icon: String, tint: Color, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.black)).tracking(1)
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.title; configuration.icon }
    }
}

private extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

// MARK: - Diagrams

/// Thumb pads as they appear in the match, with the ship above them.
private struct ControlsDiagram: View {
    var body: some View {
        VStack(spacing: 18) {
            HullBadge(hull: .lancet, team: .cyan).frame(width: 90, height: 100)
                .rotationEffect(.degrees(-18))
            HStack(spacing: 10) {
                pad("arrow.counterclockwise", "LEFT", .cyan)
                pad("arrow.clockwise", "RIGHT", .cyan)
                Spacer(minLength: 20)
                pad("arrow.down.to.line.compact", "PULL", .purple)
                pad("bolt.fill", "FIRE", .yellow)
                pad("flame.fill", "THRUST", .orange)
            }
        }
        .padding(18)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .accessibilityHidden(true)
    }

    private func pad(_ icon: String, _ title: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            Text(title).font(.system(size: 9, weight: .black)).tracking(1)
        }
        .frame(width: 70, height: 64)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5)))
    }
}

/// The goal exactly as the arena builds it: the hump under the roof, the
/// slim slab hanging from it, a coloured face either side of the mouth, the
/// hard cap underneath and the two lips that tilt back in. Drawn from
/// `ArenaGeometry.standard` so it cannot drift from the court.
private struct GoalDiagram: View {
    private let arena = ArenaGeometry.standard

    var body: some View {
        Canvas { context, size in
            // Show the middle of the court, floor to roof, and fatten the slab
            // a little so the mouth reads at this size.
            let viewHalfWidth = 0.62
            let scale = size.width / (viewHalfWidth * 2)
            let top = arena.ceilingY, bottom = arena.ceilingY - size.height / scale
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (x + viewHalfWidth) * scale, y: (top - y) * scale)
            }
            let half = max(arena.netHalfWidth, 0.03)
            let mouthTop = arena.portalMouthTopY, mouthBottom = arena.netBottomY
            let slab = Color(white: 0.16)

            // Roof and the hump the net hangs from.
            var hump = Path()
            let profile = arena.humpProfile
            hump.move(to: pt(-viewHalfWidth, top))
            hump.addLine(to: pt(-profile.last!.x, top))
            for sample in profile.reversed() { hump.addLine(to: pt(-sample.x, sample.y)) }
            for sample in profile { hump.addLine(to: pt(sample.x, sample.y)) }
            hump.addLine(to: pt(viewHalfWidth, top))
            hump.closeSubpath()
            context.fill(hump, with: .color(slab))
            var humpEdge = Path()
            for (index, sample) in profile.reversed().enumerated() {
                index == 0 ? humpEdge.move(to: pt(-sample.x, sample.y)) : humpEdge.addLine(to: pt(-sample.x, sample.y))
            }
            for sample in profile { humpEdge.addLine(to: pt(sample.x, sample.y)) }
            context.stroke(humpEdge, with: .color(.white.opacity(0.55)), lineWidth: 2)

            // Collar (solid) and mouth (a dark slot).
            var collar = Path()
            collar.addRect(CGRect(x: pt(-half, 0).x, y: pt(0, arena.humpUndersideY).y,
                                  width: half * 2 * scale, height: (arena.humpUndersideY - mouthTop) * scale))
            context.fill(collar, with: .color(slab))
            context.stroke(collar, with: .color(.white.opacity(0.55)), lineWidth: 1.5)
            var mouth = Path()
            mouth.addRect(CGRect(x: pt(-half, 0).x, y: pt(0, mouthTop).y,
                                 width: half * 2 * scale, height: (mouthTop - mouthBottom) * scale))
            context.fill(mouth, with: .color(.black.opacity(0.85)))

            // Faces: the defender's colour, glowing like the arena.
            for (sign, color) in [(-1.0, Color.cyan), (1.0, Color.orange)] {
                var face = Path()
                face.move(to: pt(sign * half, mouthTop)); face.addLine(to: pt(sign * half, mouthBottom))
                context.stroke(face, with: .color(color.opacity(0.35)), lineWidth: 12)
                context.stroke(face, with: .color(color), lineWidth: 4)
            }

            // Cap: hard and neutral.
            var cap = Path()
            cap.move(to: pt(-half, mouthBottom))
            cap.addQuadCurve(to: pt(half, mouthBottom), control: pt(0, mouthBottom - 0.04))
            context.stroke(cap, with: .color(.white.opacity(0.95)), lineWidth: 3)

            // Lips: shelves that rise away from the mouth, so a ball rolls in.
            for sign in [-1.0, 1.0] {
                let root = arena.lipRoot(sign: sign), tip = arena.lipTip(sign: sign)
                let rootX = sign * half
                var lip = Path()
                lip.move(to: pt(rootX, root.y)); lip.addLine(to: pt(tip.x, tip.y))
                lip.addLine(to: pt(tip.x, tip.y - 0.014)); lip.addLine(to: pt(rootX, root.y - 0.014))
                lip.closeSubpath()
                context.fill(lip, with: .color(slab))
                context.stroke(lip, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            }

            // The spike: cyan lifts the ball from its own side over the cap
            // and into the far face.
            var arc = Path()
            let launch = (x: -0.5, y: max(bottom + 0.06, -0.3))
            arc.move(to: pt(launch.x, launch.y))
            arc.addQuadCurve(to: pt(half + 0.03, (mouthTop + mouthBottom) / 2),
                             control: pt(0.5, mouthBottom - 0.42))
            context.stroke(arc, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            let ball = pt(launch.x, launch.y)
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 6, y: ball.y - 6, width: 12, height: 12)), with: .color(.white))

            // A ball on the far lip rolls into the mouth too.
            let lipTip = arena.lipTip(sign: 1)
            let lipBall = pt(lipTip.x - 0.03, lipTip.y + 0.03)
            context.fill(Path(ellipseIn: CGRect(x: lipBall.x - 4, y: lipBall.y - 4, width: 8, height: 8)), with: .color(.white.opacity(0.7)))
            var roll = Path()
            roll.move(to: CGPoint(x: lipBall.x - 8, y: lipBall.y + 4))
            roll.addLine(to: CGPoint(x: pt(half, mouthBottom).x + 6, y: pt(half, mouthBottom).y - 6))
            context.stroke(roll, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

            // Labels.
            context.draw(Text("YOURS").font(.system(size: 9, weight: .black)).foregroundStyle(.cyan),
                         at: CGPoint(x: pt(-half, 0).x - 34, y: pt(0, mouthTop).y + 10))
            context.draw(Text("THEIRS").font(.system(size: 9, weight: .black)).foregroundStyle(.orange),
                         at: CGPoint(x: pt(half, 0).x + 36, y: pt(0, mouthTop).y + 10))
            context.draw(Text("LIP").font(.system(size: 8, weight: .black)).foregroundStyle(.white.opacity(0.6)),
                         at: CGPoint(x: pt(lipTip.x, lipTip.y).x + 14, y: pt(lipTip.x, lipTip.y).y - 2))
        }
        .frame(height: 200)
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .accessibilityHidden(true)
    }
}

/// The HUD meter the pilot will actually read mid-match.
private struct RulesDiagram: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            meter(title: "TOUCHES", used: 2, total: 3, shape: .bar)
            meter(title: "BOUNCES", used: 1, total: 1, shape: .dot)
            Text("These live under each score in the HUD. Full means the next one costs you the point.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
        .accessibilityHidden(true)
    }

    private enum Shape { case bar, dot }

    private func meter(title: String, used: Int, total: Int, shape: Shape) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 10, weight: .black)).tracking(1).frame(width: 70, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { index in
                    if shape == .bar {
                        Capsule().fill(index < used ? Color.cyan : .white.opacity(0.16)).frame(width: 22, height: 8)
                    } else {
                        Circle().fill(index < used ? Color.cyan.opacity(0.75) : .white.opacity(0.16)).frame(width: 14, height: 14)
                    }
                }
            }
            Spacer()
            Text("\(used)/\(total)").font(.caption.monospaced().bold()).foregroundStyle(.white.opacity(0.6))
        }
    }
}
