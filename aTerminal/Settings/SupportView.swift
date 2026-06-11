import SwiftUI
import StoreKit

/// Settings row (§4.6): single entry point for tips and the supporter
/// subscription — tapping it opens `SupportScreen`. Shows the badge inline
/// so supporters see their status without drilling in.
struct SupportCardLink: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        Section {
            NavigationLink {
                SupportScreen()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Support a-Terminal")
                            .font(.body.weight(.medium))
                        Text("Tips and a supporter subscription — every feature stays free.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if store.isSupporter {
                        Spacer()
                        SupporterBadge()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Support screen: one-time tips and the auto-renewing supporter
/// subscription in one place. Purely donations — nothing is paywalled.
struct SupportScreen: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Support a-Terminal", systemImage: "heart.fill")
                            .font(.headline)
                            .foregroundStyle(.pink)
                        if store.isSupporter {
                            SupporterBadge()
                        }
                    }
                    Text("a-Terminal is free and collects zero data. If it saves you time, a tip or a supporter subscription helps fund development — neither unlocks anything, ever.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            switch store.loadState {
            case .loading:
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await store.load() }
                    }
                }
            case .loaded:
                Section("One-Time Tip") {
                    ForEach(store.tipProducts) { product in
                        productRow(product, priceLabel: product.displayPrice)
                    }
                    if store.lastTipThanked {
                        Label("Thank you for the tip!", systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(.pink)
                    }
                }

                Section {
                    ForEach(store.subscriptionProducts) { product in
                        productRow(product, priceLabel: subscriptionPriceLabel(for: product))
                    }
                    Button("Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.subheadline)
                } header: {
                    Text("Supporter Subscription")
                } footer: {
                    // App Review Guideline 3.1.2: auto-renewal terms and
                    // functional Privacy Policy / Terms of Use links must
                    // accompany the subscription purchase UI.
                    Text("Subscriptions renew automatically until cancelled. Manage or cancel any time in Settings › Apple Account › Subscriptions. [Privacy Policy](https://aaroncx.github.io/a-Terminal/privacy) · [Terms of Use (EULA)](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)")
                }
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if store.loadState != .loaded {
                await store.load()
            }
        }
    }

    private func productRow(_ product: Product, priceLabel: String) -> some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            HStack {
                Text(product.displayName)
                Spacer()
                Text(priceLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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
