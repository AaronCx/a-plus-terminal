import SwiftUI

/// Tip Jar card (§4.6 card 1). StoreKit 2 products land in PR 10 — until
/// then the card explains the model without offering anything fake.
struct TipJarView: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Tip Jar", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(.pink)
                Text("Relay is free and collects zero data. If it saves you time, you can leave a tip to support development.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Supporter card (§4.6 card 2). Subscription products land in PR 10.
struct SupporterView: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Supporter", systemImage: "star.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
                Text("A small recurring thank-you. Supporters get a badge here — and our gratitude. No features are paywalled, ever.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
