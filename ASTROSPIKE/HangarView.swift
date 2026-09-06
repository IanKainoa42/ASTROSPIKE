import ASTROSPIKECore
import SwiftUI

/// Pick a hull. Free hulls select on tap; premium hulls preview but stay
/// locked with a visible reason, so nothing here is a silent dead end.
struct HangarView: View {
    @Bindable var profile: PilotProfileStore
    let entitlements: HullEntitlements
    /// Team colour to preview in. Solo play is always cyan.
    var team: Team = .cyan
    /// Compact layout for the intro page, full layout for the sheet.
    var compact = false

    @State private var previewed: Hull?

    private var shown: Hull { previewed ?? profile.selectedHull }
    private var shownUnlocked: Bool { entitlements.isUnlocked(shown) }

    var body: some View {
        HStack(spacing: compact ? 18 : 28) {
            preview
                .frame(maxWidth: compact ? 210 : 280)
            VStack(alignment: .leading, spacing: 10) {
                if !compact {
                    Text("HANGAR").font(.caption.monospaced().weight(.black)).tracking(3)
                        .foregroundStyle(.white.opacity(0.55))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(HullCatalog.all, id: \.hull) { spec in
                        hullTile(spec)
                    }
                }
                if !compact {
                    Text("Hulls are cosmetic. Every ship flies and bounces the same, online and solo.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("hangar")
    }

    private var preview: some View {
        let spec = shown.spec
        return VStack(spacing: compact ? 8 : 12) {
            HullBadge(hull: shown, team: team)
                .frame(height: compact ? 110 : 150)
                .animation(.easeOut(duration: 0.2), value: shown)
            Text(spec.name.uppercased())
                .font(.system(size: compact ? 22 : 28, weight: .black, design: .rounded))
                .foregroundStyle(team == .cyan ? .cyan : .orange)
            Text(spec.role.uppercased()).font(.caption2.monospaced().weight(.bold)).tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            if !compact {
                Text(spec.blurb).font(.caption).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            selectButton(spec)
        }
        .padding(compact ? 12 : 18)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)))
    }

    @ViewBuilder
    private func selectButton(_ spec: HullSpec) -> some View {
        if shown == profile.selectedHull {
            Label("SELECTED", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.black)).tracking(1)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(.white.opacity(0.08), in: Capsule())
                .accessibilityIdentifier("hull-selected")
        } else if shownUnlocked {
            Button {
                profile.selectedHull = shown
                FeedbackCenter.shared.tap()
            } label: {
                Label("FLY THE \(spec.name.uppercased())", systemImage: "arrow.up.circle.fill")
                    .font(.caption.weight(.black)).tracking(1)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent).tint(team == .cyan ? .cyan : .orange)
            .accessibilityIdentifier("hull-select")
        } else {
            VStack(spacing: 4) {
                Label("LOCKED • PREMIUM", systemImage: "lock.fill")
                    .font(.caption.weight(.black)).tracking(1)
                Text("Hull packs arrive with in-app purchases in a coming update.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .accessibilityIdentifier("hull-locked")
        }
    }

    private func hullTile(_ spec: HullSpec) -> some View {
        let unlocked = entitlements.isUnlocked(spec.hull)
        let isSelected = spec.hull == profile.selectedHull
        let isShown = spec.hull == shown
        return Button {
            previewed = spec.hull
            FeedbackCenter.shared.tap()
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    HullBadge(hull: spec.hull, team: team, glow: isShown)
                        .frame(height: compact ? 40 : 52)
                        .opacity(unlocked ? 1 : 0.42)
                    if !unlocked {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(3).background(.black.opacity(0.6), in: Circle())
                    }
                }
                Text(spec.name.uppercased())
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(unlocked ? .white : .white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(isShown ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? (team == .cyan ? Color.cyan : .orange) : .white.opacity(isShown ? 0.35 : 0.1),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spec.name), \(unlocked ? "unlocked" : "locked")\(isSelected ? ", selected" : "")")
        .accessibilityIdentifier("hull-\(spec.hull.rawValue)")
    }
}

struct HangarSheet: View {
    @Bindable var profile: PilotProfileStore
    let entitlements: HullEntitlements
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                HangarView(profile: profile, entitlements: entitlements)
                    .padding(24)
            }
            .background(CosmicBackground())
            .navigationTitle("Hangar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("hangar-screen")
    }
}
