import Foundation
import Observation
import StoreKit

/// Product identifiers for the Tip Jar and Supporter subscription (§4.6).
/// Must match App Store Connect and Relay.storekit.
enum RelayProducts {
    static let tipSmall = "com.aaroncx.relay.tip.small"
    static let tipMedium = "com.aaroncx.relay.tip.medium"
    static let tipLarge = "com.aaroncx.relay.tip.large"
    static let supporterMonthly = "com.aaroncx.relay.supporter.monthly"
    static let supporterYearly = "com.aaroncx.relay.supporter.yearly"

    static let tips = [tipSmall, tipMedium, tipLarge]
    static let subscriptions = [supporterMonthly, supporterYearly]
    static let all = tips + subscriptions
}

/// StoreKit 2 front-end: loads products, performs purchases, tracks the
/// supporter entitlement, listens for transaction updates. No receipts ever
/// leave the device beyond Apple's own infrastructure.
@MainActor
@Observable
final class TipStore {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var tipProducts: [Product] = []
    private(set) var subscriptionProducts: [Product] = []
    /// True when a supporter subscription is active — shows the badge (§4.6).
    private(set) var isSupporter = false
    /// Set briefly after a successful tip for a thank-you moment.
    var lastTipThanked = false

    @ObservationIgnored nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.process(update)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func load() async {
        loadState = .loading
        do {
            let products = try await Product.products(for: RelayProducts.all)
            tipProducts = products
                .filter { RelayProducts.tips.contains($0.id) }
                .sorted { $0.price < $1.price }
            subscriptionProducts = products
                .filter { RelayProducts.subscriptions.contains($0.id) }
                .sorted { $0.price < $1.price }
            loadState = .loaded
            await refreshSupporterStatus()
        } catch {
            loadState = .failed("Couldn't load products: \(error.localizedDescription)")
        }
    }

    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await process(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            // Purchase failures surface through StoreKit's own UI; nothing to do.
        }
    }

    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshSupporterStatus()
    }

    private func process(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if RelayProducts.tips.contains(transaction.productID) {
            lastTipThanked = true
        }
        await transaction.finish()
        await refreshSupporterStatus()
    }

    func refreshSupporterStatus() async {
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               RelayProducts.subscriptions.contains(transaction.productID),
               transaction.revocationDate == nil {
                active = true
            }
        }
        isSupporter = active
    }
}
