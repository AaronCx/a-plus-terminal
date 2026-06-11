import SwiftUI
import StoreKit

/// Tip Jar card (§4.6 card 1): consumable tips via StoreKit 2.
struct TipJarView: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Tip Jar", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.pink)
                Text("a-Terminal is free and collects zero data. If it saves you time, you can leave a tip to support development.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            switch store.loadState {
            case .loading:
                HStack {
                    ProgressView()
                    Text("Loading tips…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await store.load() }
                }
            case .loaded:
                ForEach(store.tipProducts) { product in
                    Button {
                        Task { await store.purchase(product) }
                    } label: {
                        HStack {
                            Text(product.displayName)
                            Spacer()
                            Text(product.displayPrice)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if store.lastTipThanked {
                    Label("Thank you for the tip!", systemImage: "sparkles")
                        .font(.subheadline)
                        .foregroundStyle(.pink)
                }
            }
        }
    }
}

/// Supporter card (§4.6 card 2): auto-renewing subscription. Gratitude and a
/// badge — no features are paywalled, ever.
struct SupporterView: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        Section {
            content
        } footer: {
            // App Review Guideline 3.1.2: auto-renewal terms and functional
            // Privacy Policy / Terms of Use links must accompany the
            // subscription purchase UI.
            Text("Subscriptions renew automatically until cancelled. Manage or cancel any time in Settings › Apple Account › Subscriptions. [Privacy Policy](https://aaroncx.github.io/a-Terminal/privacy) · [Terms of Use (EULA)](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Supporter", systemImage: "star.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                if store.isSupporter {
                    SupporterBadge()
                }
            }
            Text("A small recurring thank-you. Supporters get a badge here — and our gratitude. No features are paywalled, ever.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)

        if store.loadState == .loaded {
            ForEach(store.subscriptionProducts) { product in
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    HStack {
                        Text(product.displayName)
                        Spacer()
                        Text(subscriptionPriceLabel(for: product))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }

        Button("Restore Purchases") {
            Task { await store.restorePurchases() }
        }
        .font(.subheadline)
    }

    private func subscriptionPriceLabel(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else {
            return product.displayPrice
        }
        switch period.unit {
        case .month: return "\(product.displayPrice)/mo"
        case .year: return "\(product.displayPrice)/yr"
        default: return product.displayPrice
        }
    }
}

struct SupporterBadge: View {
    var body: some View {
        Text("SUPPORTER")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.yellow.opacity(0.25), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityLabel("Supporter badge")
    }
}
