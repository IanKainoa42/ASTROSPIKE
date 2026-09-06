import ASTROSPIKECore
import SwiftUI

/// First-launch intro: four pages, then the hangar, then straight into a
/// rookie match. Every page can be skipped; the whole thing can be replayed
/// from Settings.
struct OnboardingFlow: View {
    @Bindable var profile: PilotProfileStore
    let entitlements: HullEntitlements
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
            Text("STEER AND THRUST. THAT’S IT.")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            IntroLine(icon: "arrow.left.and.right", tint: .cyan, title: "STEER", text: "Hold left or right to rotate. Let go and the nose stays where it is.")
            IntroLine(icon: "flame.fill", tint: .orange, title: "THRUST", text: "Hold to burn. Gravity pulls you down the whole time; you never stop drifting.")
            IntroLine(icon: "keyboard", tint: .white.opacity(0.8), title: "KEYBOARD", text: "A and D steer, W or space thrusts. Touch and keys work together.")
        } side: {
            ControlsDiagram()
        }
    }

    private var score: some View {
        IntroPage(kicker: "02 • SCORE") {
            Text("THE GOAL IS A PORTAL.")
                .font(.system(size: 30, weight: .black, design: .rounded))
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
                .font(.system(size: 30, weight: .black, design: .rounded))
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
            HangarView(profile: profile, entitlements: entitlements, compact: true)
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
        HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                Text(kicker).font(.caption.monospaced().weight(.black)).tracking(3)
                    .foregroundStyle(.white.opacity(0.55))
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            side
                .frame(maxWidth: 360)
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
                Text(text).font(.callout).foregroundStyle(.white.opacity(0.72))
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

/// Roof-hung goal with its two faces and lips, seen from the side.
private struct GoalDiagram: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let midX = w / 2
            // Roof line.
            var roof = Path()
            roof.move(to: CGPoint(x: 0, y: 8)); roof.addLine(to: CGPoint(x: w, y: 8))
            context.stroke(roof, with: .color(.white.opacity(0.3)), lineWidth: 2)
            // Floor.
            var floor = Path()
            floor.move(to: CGPoint(x: 0, y: h - 8)); floor.addLine(to: CGPoint(x: w, y: h - 8))
            context.stroke(floor, with: .color(.white.opacity(0.3)), lineWidth: 2)
            // Goal cap hanging from roof.
            let capRect = CGRect(x: midX - 34, y: 8, width: 68, height: h * 0.42)
            context.fill(Path(roundedRect: capRect, cornerRadius: 10), with: .color(.white.opacity(0.08)))
            context.stroke(Path(roundedRect: capRect, cornerRadius: 10), with: .color(.white.opacity(0.6)), lineWidth: 2)
            // Faces.
            var left = Path(); left.move(to: CGPoint(x: capRect.minX, y: capRect.minY + 14)); left.addLine(to: CGPoint(x: capRect.minX, y: capRect.maxY - 6))
            var right = Path(); right.move(to: CGPoint(x: capRect.maxX, y: capRect.minY + 14)); right.addLine(to: CGPoint(x: capRect.maxX, y: capRect.maxY - 6))
            context.stroke(left, with: .color(.cyan), lineWidth: 5)
            context.stroke(right, with: .color(.orange), lineWidth: 5)
            // Lips.
            var lipL = Path(); lipL.move(to: CGPoint(x: capRect.minX - 26, y: capRect.maxY + 6)); lipL.addLine(to: CGPoint(x: capRect.minX, y: capRect.maxY - 2))
            var lipR = Path(); lipR.move(to: CGPoint(x: capRect.maxX + 26, y: capRect.maxY + 6)); lipR.addLine(to: CGPoint(x: capRect.maxX, y: capRect.maxY - 2))
            context.stroke(lipL, with: .color(.cyan.opacity(0.8)), lineWidth: 3)
            context.stroke(lipR, with: .color(.orange.opacity(0.8)), lineWidth: 3)
            // Ball arc from cyan side into orange face.
            var arc = Path()
            arc.move(to: CGPoint(x: w * 0.12, y: h * 0.72))
            arc.addQuadCurve(to: CGPoint(x: capRect.maxX + 4, y: capRect.midY + 10),
                             control: CGPoint(x: w * 0.55, y: -h * 0.05))
            context.stroke(arc, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            context.fill(Path(ellipseIn: CGRect(x: w * 0.12 - 6, y: h * 0.72 - 6, width: 12, height: 12)), with: .color(.white))
            // Labels.
            context.draw(Text("YOURS").font(.system(size: 9, weight: .black)).foregroundStyle(.cyan),
                         at: CGPoint(x: capRect.minX - 30, y: capRect.minY + 22))
            context.draw(Text("THEIRS").font(.system(size: 9, weight: .black)).foregroundStyle(.orange),
                         at: CGPoint(x: capRect.maxX + 32, y: capRect.minY + 22))
        }
        .frame(height: 190)
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
