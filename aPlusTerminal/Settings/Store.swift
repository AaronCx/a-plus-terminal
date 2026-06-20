import Foundation
import Observation
import StoreKit

/// Product identifiers for the Tip Jar (§4.6). Tips are **consumables** — there
/// is no subscription, and nothing in the app is ever paywalled.
/// Must match App Store Connect and aPlusTerminal.storekit.
enum StoreProducts {
    static let tipSmall = "com.aaroncx.aplusterminal.tip.small"
    static let tipMedium = "com.aaroncx.aplusterminal.tip.medium"
    static let tipLarge = "com.aaroncx.aplusterminal.tip.large"

    static let tips = [tipSmall, tipMedium, tipLarge]
    static let all = tips
}

/// StoreKit 2 front-end for the Tip Jar: loads consumable tip products,
/// performs purchases, and surfaces a brief thank-you. No receipts ever leave
/// the device beyond Apple's own infrastructure.
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
            let products = try await Product.products(for: StoreProducts.all)
            tipProducts = products
                .filter { StoreProducts.tips.contains($0.id) }
                .sorted { $0.price < $1.price }
            loadState = Self.postLoadState(tipCount: tipProducts.count)
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

    /// The App Store can return an empty product list without throwing
    /// (transient hiccup right after launch). Treating that as "loaded"
    /// would latch an empty screen forever — every view .task guards on
    /// != .loaded, so nothing would ever retry.
    static func postLoadState(tipCount: Int) -> LoadState {
        if tipCount == 0 {
            return .failed("The App Store didn't return any products. Check your connection and try again.")
        }
        return .loaded
    }

    private func process(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if StoreProducts.tips.contains(transaction.productID) {
            lastTipThanked = true
        }
        await transaction.finish()
    }
}
