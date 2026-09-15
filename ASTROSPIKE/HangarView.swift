import ASTROSPIKECore
import SwiftUI

/// Pick a hull. Free hulls select on tap; premium hulls preview and buy.
/// Every locked branch renders either a price, a spinner or a reason -- none
/// of them is a silent dead end.
struct HangarView: View {
    @Bindable var profile: PilotProfileStore
    let entitlements: HullEntitlements
    let store: HullStore
    /// Team colour to preview in. Solo play is always cyan.
    var team: Team = .cyan
    /// Compact layout for the intro page, full layout for the sheet.
    /// The intro previews premium hulls but never sells them; buying lives
    /// in the hangar sheet, where the restore button and terms sit too.
    var compact = false

    @State private var previewed: Hull?
    @Environment(\.openURL) private var openURL

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
                    storeFooter
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hangar")
    }

    /// Restore plus the store's last word. Both live here rather than in the
    /// toolbar so the intro page never shows them.
    @ViewBuilder
    private var storeFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await store.restore() }
                } label: {
                    if store.isRestoring {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).tint(.white)
                            Text("RESTORING…")
                        }
                        .contentShape(Rectangle())
                    } else {
                        Text("RESTORE PURCHASES").contentShape(Rectangle())
                    }
                }
                .font(.caption2.weight(.black)).tracking(1)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(store.isRestoring ? 0.55 : 0.8))
                .disabled(store.isRestoring)
                .accessibilityIdentifier("hull-restore")
                Spacer(minLength: 8)
                Button("Privacy Policy") {
                    openURL(LegalLinks.privacyPolicy)
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .accessibilityIdentifier("hangar-privacy")
                Text("·").foregroundStyle(.white.opacity(0.35))
                Button("Terms of Use") {
                    openURL(LegalLinks.termsOfUse)
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .accessibilityIdentifier("hangar-terms")
            }
            if let message = store.message {
                Button {
                    store.message = nil
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .black))
                    }
                    .font(.caption2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityIdentifier("hull-store-message")
            }
        }
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
            lockedControls(spec)
        }
    }

    /// The locked branch has four states and every one of them renders:
    /// preview-only on the intro, a spinner mid-purchase, a priced buy button
    /// once StoreKit answers, and a tappable retry with the reason if it did
    /// not. There is no path here that leaves the pilot looking at nothing.
    @ViewBuilder
    private func lockedControls(_ spec: HullSpec) -> some View {
        let productID = spec.availability.productID
        VStack(spacing: 4) {
            if compact {
                Label("LOCKED • PREMIUM", systemImage: "lock.fill")
                    .font(.caption.weight(.black)).tracking(1)
                Text("Unlock premium hulls in the Hangar.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            } else if store.purchasing == productID {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("CONTACTING THE APP STORE…")
                        .font(.caption.weight(.black)).tracking(1)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            } else if let price = store.price(for: spec.hull) {
                Button {
                    store.message = nil
                    FeedbackCenter.shared.tap()
                    Task { await store.purchase(spec.hull) }
                } label: {
                    Label("UNLOCK • \(price)", systemImage: "lock.open.fill")
                        .font(.caption.weight(.black)).tracking(1)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent).tint(team == .cyan ? .cyan : .orange)
                .disabled(store.purchasing != nil)
                .accessibilityIdentifier("hull-buy")
            } else {
                Button {
                    store.message = nil
                    Task { await store.loadProducts() }
                } label: {
                    VStack(spacing: 4) {
                        Label(store.phase == .loading ? "LOADING PRICE…" : "LOCKED • PREMIUM",
                              systemImage: "lock.fill")
                            .font(.caption.weight(.black)).tracking(1)
                        Text(store.phase.reason ?? "Fetching the price from the App Store.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .disabled(store.phase == .loading)
                .accessibilityIdentifier("hull-retry")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .accessibilityIdentifier("hull-locked")
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
    let store: HullStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                HangarView(profile: profile, entitlements: entitlements, store: store)
                    .padding(24)
            }
            .background(CosmicBackground())
            // `start()` is idempotent -- the app root has usually run it
            // already. Opening the hangar is the moment to retry a load that
            // failed earlier, so prices are there when the pilot looks.
            .task {
                await store.start()
                if store.phase.reason != nil { await store.loadProducts() }
            }
            .navigationTitle("Hangar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("hangar-screen")
    }
}
