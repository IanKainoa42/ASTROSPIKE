import Foundation
import Testing
@testable import ASTROSPIKECore

@Suite("Hull catalog")
struct HullCatalogTests {
    @Test("Eight hulls, each with a unique name")
    func rosterSize() {
        #expect(Hull.allCases.count == 8)
        #expect(Set(HullCatalog.all.map(\.name)).count == 8)
    }

    @Test("Every silhouette stays inside the shared collision envelope")
    func outlinesFitEnvelope() {
        for spec in HullCatalog.all {
            #expect(spec.outline.fitsEnvelope, "\(spec.name) leaves the envelope")
            #expect(spec.outline.silhouette.count >= 8, "\(spec.name) is too simple to read")
        }
    }

    @Test("Free and premium split leaves at least two free hulls for a solo match")
    func availabilitySplit() {
        #expect(HullCatalog.free.count >= 2)
        #expect(HullCatalog.free.count + HullCatalog.premium.count == 8)
        let productIDs = HullCatalog.premium.compactMap(\.availability.productID)
        #expect(productIDs.count == HullCatalog.premium.count)
        #expect(Set(productIDs).count == productIDs.count)
        #expect(productIDs.allSatisfy { $0.hasPrefix("com.iankainoa.ASTROSPIKE.hull.") })
    }

    @Test("Team defaults are the two original hulls")
    func teamDefaults() {
        #expect(Hull.defaultHull(for: .cyan) == .lancet)
        #expect(Hull.defaultHull(for: .orange) == .anvil)
    }

    @Test("Profile payload survives a wire round trip")
    func profileRoundTrip() throws {
        let envelope = WireEnvelope(sequence: 7, payload: .profile(seat: .orange, hull: .wraith))
        let decoded = try WireCodec().decode(WireCodec().encode(envelope))
        #expect(decoded == envelope)
    }
}

@Suite("Hull entitlements and pilot profile")
@MainActor
struct HullPersistenceTests {
    private func scratchDefaults() -> UserDefaults {
        let name = "hull-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Free hulls are always unlocked; premium hulls unlock by product id and persist")
    func entitlements() {
        let defaults = scratchDefaults()
        let store = HullEntitlements(defaults: defaults)
        for spec in HullCatalog.free { #expect(store.isUnlocked(spec.hull)) }
        for spec in HullCatalog.premium { #expect(!store.isUnlocked(spec.hull)) }

        store.unlock(productID: HullCatalog.productID(for: .bulwark))
        #expect(store.isUnlocked(.bulwark))
        #expect(!store.isUnlocked(.wraith))

        let reloaded = HullEntitlements(defaults: defaults)
        #expect(reloaded.isUnlocked(.bulwark))

        reloaded.revokeAll()
        #expect(!HullEntitlements(defaults: defaults).isUnlocked(.bulwark))
    }

    @Test("Selected hull and onboarding flag persist; rival never twins the pilot")
    func profile() {
        let defaults = scratchDefaults()
        let profile = PilotProfileStore(defaults: defaults)
        #expect(profile.selectedHull == .lancet)
        #expect(!profile.hasCompletedOnboarding)

        profile.selectedHull = .manta
        profile.hasCompletedOnboarding = true
        let reloaded = PilotProfileStore(defaults: defaults)
        #expect(reloaded.selectedHull == .manta)
        #expect(reloaded.hasCompletedOnboarding)

        for seed in UInt64(0) ..< 12 {
            let rival = reloaded.rivalHull(seed: seed)
            #expect(rival != .manta)
            #expect(!rival.spec.isPremium)
        }
    }
}

@Suite("Hull store contract")
@MainActor
struct HullStoreTests {
    /// These strings are typed by hand into App Store Connect, so they are
    /// pinned here rather than derived. A rename that does not also happen in
    /// ASC ships a hull nobody can buy.
    @Test("Premium product identifiers match the App Store Connect records")
    func productIDsArePinned() {
        #expect(HullStore.premiumProductIDs == [
            "com.iankainoa.ASTROSPIKE.hull.bulwark",
            "com.iankainoa.ASTROSPIKE.hull.wraith",
            "com.iankainoa.ASTROSPIKE.hull.hornet",
            "com.iankainoa.ASTROSPIKE.hull.comet",
        ])
    }

    @Test("A refund revokes exactly one hull and the revocation survives a relaunch")
    func revocationPersists() {
        let name = "hull-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let entitlements = HullEntitlements(defaults: defaults)
        entitlements.unlock(productID: HullCatalog.productID(for: .bulwark))
        entitlements.unlock(productID: HullCatalog.productID(for: .wraith))
        entitlements.lock(productID: HullCatalog.productID(for: .bulwark))

        #expect(!entitlements.isUnlocked(.bulwark))
        #expect(entitlements.isUnlocked(.wraith))

        let reloaded = HullEntitlements(defaults: defaults)
        #expect(!reloaded.isUnlocked(.bulwark))
        #expect(reloaded.isUnlocked(.wraith))
    }

    @Test("An unstarted store sells nothing and quotes no price")
    func idleStoreHasNoPrices() {
        let entitlements = HullEntitlements(defaults: UserDefaults(suiteName: "hull-idle-\(UUID().uuidString)")!)
        let store = HullStore(entitlements: entitlements)
        #expect(store.phase == .idle)
        #expect(store.purchasing == nil)
        for spec in HullCatalog.premium { #expect(store.price(for: spec.hull) == nil) }
    }
}
