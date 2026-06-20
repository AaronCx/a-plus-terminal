import SwiftUI
import StoreKit

/// Settings row (§4.6): single entry point for tips — tapping it opens
/// `SupportScreen`. Nothing is paywalled; tips are a pure thank-you.
struct SupportCardLink: View {
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
                        Text("Support a+Terminal")
                            .font(.body.weight(.medium))
                        Text("Leave a tip — every feature stays free.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Support screen: one-time tips only. Purely donations — nothing is paywalled.
struct SupportScreen: View {
    @Environment(TipStore.self) private var store

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Support a+Terminal", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(.pink)
                    Text("a+Terminal is free and collects zero data. If it saves you time, a tip helps fund development — it unlocks nothing, because nothing is paywalled, ever.")
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
            }

            Section {
                Link("Privacy Policy", destination: URL(string: "https://aaroncx.github.io/a-plus-terminal/privacy/")!)
                    .font(.subheadline)
            } footer: {
                Text("Tips are one-time purchases. Nothing is paywalled, and nothing renews.")
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
}
