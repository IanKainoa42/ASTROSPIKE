import Foundation
import StoreKit

/// Buys and restores the premium hulls.
///
/// StoreKit is the source of truth for what the pilot owns; `HullEntitlements`
/// is the offline cache this writes into, so a locked hull never depends on a
/// round trip to know it is locked. Ownership arrives from three places and
/// they all land in the same place, `apply(_:)`:
///
///   * `Transaction.currentEntitlements` at launch and after a restore,
///   * `Transaction.updates` for purchases finished elsewhere (Ask to Buy
///     approvals, a buy on another device, a refund),
///   * the transaction a `purchase()` call hands back.
///
/// Every branch that can fail sets `message`, because the hangar renders it.
/// A purchase button that changes nothing is the shape App Review rejects.
@MainActor
@Observable
public final class HullStore {
    /// What the hangar should render for the store as a whole.
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        /// Products came back; premium hulls can be bought.
        case ready
        /// Nothing can be sold right now -- offline, purchases restricted, or
        /// the products are not live yet. The string is shown to the pilot.
        case unavailable(String)

        public var reason: String? {
            if case let .unavailable(reason) = self { return reason }
            return nil
        }
    }

    public private(set) var phase: Phase = .idle
    /// Loaded products keyed by identifier.
    public private(set) var products: [String: Product] = [:]
    /// The product currently mid-purchase, so its button can spin.
    public private(set) var purchasing: String?
    public private(set) var isRestoring = false
    /// The last thing worth telling the pilot: every failure, plus every
    /// success with no other visible effect. The hangar clears it on tap.
    public var message: String?

    @ObservationIgnored private let entitlements: HullEntitlements
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(entitlements: HullEntitlements) {
        self.entitlements = entitlements
    }

    // MARK: - Lifecycle

    /// Start the transaction listener and load prices. Call from `.task`,
    /// never from a `View` initialiser -- a listener hooked up in `init` binds
    /// to the copy SwiftUI throws away.
    public func start() async {
        guard !started else { return }
        started = true
        updates = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        await refreshOwned()
        await loadProducts()
    }

    public func stop() {
        updates?.cancel()
        updates = nil
        started = false
    }

    // MARK: - Catalog

    /// Every premium product identifier, in catalog order.
    public static var premiumProductIDs: [String] {
        HullCatalog.premium.compactMap(\.availability.productID)
    }

    /// The localised price for a hull, or `nil` if it has not loaded.
    /// Never format a price yourself: the storefront owns it.
    public func price(for hull: Hull) -> String? {
        hull.spec.availability.productID.flatMap { products[$0]?.displayPrice }
    }

    public func loadProducts() async {
        phase = .loading
        do {
            let loaded = try await Product.products(for: Self.premiumProductIDs)
            products = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            phase = products.isEmpty
                ? .unavailable("Hull packs aren't on sale yet. Check back after the next update.")
                : .ready
        } catch {
            products = [:]
            phase = .unavailable("Couldn't reach the App Store. Tap to try again.")
        }
    }

    // MARK: - Buying

    public func purchase(_ hull: Hull) async {
        guard let productID = hull.spec.availability.productID else { return }
        guard AppStore.canMakePayments else {
            message = "Purchases are turned off on this device. Check Screen Time › Content & Privacy Restrictions."
            return
        }
        guard let product = products[productID] else {
            message = "The \(hull.spec.name) isn't available to buy right now."
            await loadProducts()
            return
        }

        purchasing = productID
        defer { purchasing = nil }

        do {
            switch try await product.purchase() {
            case let .success(verification):
                await handle(verification)
                if !entitlements.isUnlocked(hull) {
                    message = "The purchase went through but the \(hull.spec.name) didn't unlock. Try Restore Purchases."
                }
            case .pending:
                message = "\(hull.spec.name) is waiting on approval. It unlocks here as soon as it clears."
            case .userCancelled:
                break
            @unknown default:
                message = "That purchase didn't finish. Nothing was charged."
            }
        } catch {
            message = "Purchase failed: \(error.localizedDescription)"
        }
    }

    /// Required by App Review for non-consumables: an explicit way back to a
    /// purchase made on another device or before a reinstall.
    public func restore() async {
        isRestoring = true
        defer { isRestoring = false }

        let before = entitlements.unlockedProductIDs
        do {
            try await AppStore.sync()
        } catch {
            message = "Restore failed: \(error.localizedDescription)"
            return
        }
        await refreshOwned()

        let gained = entitlements.unlockedProductIDs.subtracting(before)
        if gained.isEmpty {
            message = entitlements.unlockedProductIDs.isEmpty
                ? "No hull purchases found on this Apple Account."
                : "Everything you've bought is already unlocked."
        } else {
            message = "Restored \(gained.count) hull\(gained.count == 1 ? "" : "s")."
        }
    }

    // MARK: - Transactions

    /// Re-read what this Apple Account owns. Additive by design: a launch
    /// with a cold receipt must never revoke a hull the pilot paid for.
    /// Revocations come through `Transaction.updates` instead.
    public func refreshOwned() async {
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            apply(transaction)
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = result else {
            message = "A purchase couldn't be verified, so nothing was unlocked. Try Restore Purchases."
            return
        }
        apply(transaction)
        await transaction.finish()
    }

    private func apply(_ transaction: Transaction) {
        guard transaction.revocationDate == nil else {
            entitlements.lock(productID: transaction.productID)
            return
        }
        entitlements.unlock(productID: transaction.productID)
    }
}
