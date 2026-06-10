import SwiftUI

/// Full-screen terminal for one session: emulator + accessory bar, with
/// state overlays for connecting / reconnecting / suspended.
struct TerminalScreen: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.dismiss) private var dismiss

    let session: TerminalSession

    var body: some View {
        ZStack {
            TerminalHostView(session: session, fontSize: theme.terminalFontSize)

            if session.showTmuxMouseHint {
                VStack {
                    TmuxMouseHintBanner {
                        session.showTmuxMouseHint = false
                    }
                    Spacer()
                }
            }

            switch session.state {
            case .connecting:
                statusCard {
                    ProgressView("Connecting to \(session.server.name)…")
                }
            case .reconnecting:
                statusCard {
                    ProgressView("Reconnecting…")
                }
            case .suspended:
                ConnectionFailureView(message: session.lastError ?? "Disconnected.") {
                    Task { await session.reconnect(maxAttempts: 1) }
                } onClose: {
                    sessionManager.close(session)
                    dismiss()
                }
            case .connected, .closed:
                EmptyView()
            }
        }
        .navigationTitle(session.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.state == .connected {
                KeyAccessoryBar(bridge: session.bridge) {
                    // Dictation lands in PR 7.
                }
            }
        }
        .onChange(of: session.state) { _, newState in
            if newState == .connected {
                session.bridge.focus()
            }
        }
        .onAppear {
            if session.state == .connected {
                session.bridge.focus()
            }
        }
    }

    private func statusCard(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One-time hint when scrolling falls back to arrow keys inside a full-screen
/// app: tmux feels native once `set -g mouse on` is configured (§4.3).
struct TmuxMouseHintBanner: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Smoother scrolling in tmux")
                    .font(.subheadline.weight(.semibold))
                Text("Add `set -g mouse on` to ~/.tmux.conf on this server so swipes scroll tmux history natively.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss Hint")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

/// Hard-fail sheet; host key mismatches arrive here with the fingerprint diff
/// in the message. Deliberately no "trust anyway" button (§4.1).
struct ConnectionFailureView: View {
    let message: String
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Connection Failed")
                .font(.headline)
            Text(message)
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Close", role: .cancel, action: onClose)
                    .buttonStyle(.bordered)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.red.opacity(0.6), lineWidth: 1)
        )
        .padding(24)
    }
}
