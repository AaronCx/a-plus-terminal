import SwiftUI

/// Warning card shown instead of the generic connection-failure card when a
/// (re)connect failed on a host-key mismatch. The connection has already
/// hard-failed (§4.1 — no silent accept); the only way forward is the review
/// sheet, where re-pinning is an explicit, destructive-styled decision.
struct HostKeyConflictView: View {
    let serverName: String
    let conflict: (expectedFingerprint: String, presentedFingerprint: String, presentedKey: String)
    /// Wired to `session.acceptRotatedHostKey()` — the destructive confirm in
    /// the sheet is its only call site.
    var onAccept: () async -> Void
    var onClose: () -> Void

    @State private var showReviewSheet = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Server identity changed")
                .font(.headline)
            Text("\(serverName) presented a host key that doesn't match the pinned one, so the connection was refused.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button {
                    showReviewSheet = true
                } label: {
                    Label("Review Host Key Change…", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Close", role: .cancel, action: onClose)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 320)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.red.opacity(0.6), lineWidth: 1)
        )
        .padding(24)
        .sheet(isPresented: $showReviewSheet) {
            HostKeyReviewSheet(
                expectedFingerprint: conflict.expectedFingerprint,
                presentedFingerprint: conflict.presentedFingerprint,
                onAccept: onAccept
            )
        }
    }
}

/// Review-then-decide sheet: both fingerprints side by side, a plain-language
/// warning, and a destructive confirm that re-pins exactly the reviewed key.
/// No "don't ask again", no remembering the choice for other servers.
struct HostKeyReviewSheet: View {
    let expectedFingerprint: String
    let presentedFingerprint: String
    var onAccept: () async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                        Text("This server's host key has changed.")
                            .font(.headline)
                    }
                    Text("This can mean the server was reinstalled or its keys were rotated — or that something is intercepting your connection. If you didn't expect this change, do not trust the new key.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 14) {
                        fingerprintRow(label: "Pinned key", fingerprint: expectedFingerprint)
                        fingerprintRow(label: "Presented key", fingerprint: presentedFingerprint)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                    Button(role: .destructive) {
                        dismiss()
                        Task { await onAccept() }
                    } label: {
                        Text("Trust New Key & Reconnect")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }
            .navigationTitle("Host Key Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fingerprintRow(label: String, fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(fingerprint)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }
}
