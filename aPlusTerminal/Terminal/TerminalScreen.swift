import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Full-screen terminal for one session: emulator + accessory bar, with
/// state overlays for connecting / reconnecting / suspended.
struct TerminalScreen: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.dismiss) private var dismiss

    let session: TerminalSession

    @State private var showDictation = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        ZStack {
            TerminalHostView(session: session, fontSize: theme.terminalFontSize)

            if session.showMultiplexerHint {
                VStack {
                    TmuxMouseHintBanner {
                        session.showMultiplexerHint = false
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
                if let error = session.lastError {
                    // An actual connection failure (host-key mismatch, auth, …).
                    ConnectionFailureView(message: error) {
                        Task { await session.reconnect(maxAttempts: 1) }
                    } onClose: {
                        sessionManager.close(session)
                        dismiss()
                    }
                } else {
                    // Cleanly paused (backgrounded long enough that iOS froze
                    // us). Reconnect queries the *live* sessions, then attaches
                    // or shows the picker — so the choices are never stale.
                    SessionPausedView(
                        reattachEnabled: session.reattachEnabled,
                        onReconnect: { Task { await session.reconnectChoosingSession() } },
                        onFreshShell: { Task { await session.reconnect(attachTo: nil) } },
                        onClose: {
                            sessionManager.close(session)
                            dismiss()
                        }
                    )
                }
            case .connected, .closed:
                EmptyView()
            }

            // Multiple live sessions after a reconnect — pick which to reattach.
            if session.state == .connected && session.reattachChoicePending {
                ReattachPickerView(
                    sessions: session.availableSessions,
                    onPick: { name in session.attachToChosen(name) },
                    onStayInShell: { session.dismissReattachChoice() }
                )
            }
        }
        .navigationTitle(session.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) {
            if session.isAttaching {
                uploadingIndicator
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.state == .connected {
                KeyAccessoryBar(
                    bridge: session.bridge,
                    onMic: { showDictation = true },
                    onAttachPhoto: { showPhotoPicker = true },
                    onAttachFile: { showFileImporter = true }
                )
            }
        }
        .sheet(isPresented: $showDictation) {
            DictationSheet { text, appendReturn in
                session.sendInput(Data((appendReturn ? text + "\n" : text).utf8))
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                    await session.attach(data, suggestedName: "shot.\(ext)", kind: .image)
                }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    await session.attach(data, suggestedName: url.lastPathComponent, kind: .file)
                }
            }
        }
        .onChange(of: session.state) { _, newState in
            if newState == .connected {
                session.bridge.focus()
            } else if newState == .closed {
                // The remote shell exited (`exit`) — leave the screen too.
                dismiss()
            }
        }
        .onAppear {
            switch session.state {
            case .connected:
                session.bridge.focus()
            case .suspended:
                // Arriving via Live Activity tap or session list at a paused
                // session: show the reattach-vs-fresh choice (the .suspended
                // card) rather than silently reconnecting for them.
                break
            default:
                break
            }
        }
    }

    private var uploadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Uploading…")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityLabel("Uploading attachment")
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

/// Shown when a session was cleanly paused in the background (iOS froze the
/// app, so the socket was suspended). The server-side session survives; the
/// user chooses how to come back — reattach the multiplexer or a fresh shell.
struct SessionPausedView: View {
    /// Whether the reattach feature is on ("Auto-reattach multiplexer"). When
    /// off, Reconnect lands in a fresh shell, so the separate "New Shell" button
    /// would be redundant and is hidden.
    var reattachEnabled: Bool
    var onReconnect: () -> Void
    var onFreshShell: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Session Paused")
                .font(.headline)
            Text(reattachEnabled
                 ? "iOS paused this connection in the background. Your work is still running on the server."
                 : "iOS paused this connection in the background. Reconnect when you're ready.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button(action: onReconnect) {
                    Label("Reconnect", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if reattachEnabled {
                    Button(action: onFreshShell) {
                        Label("New Shell", systemImage: "plus.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Close", role: .cancel, action: onClose)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 320)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }
}

/// Live session picker shown over the reconnected shell when several sessions
/// exist. `sessions` is a fresh query (no stale/closed entries).
struct ReattachPickerView: View {
    let sessions: [String]
    var onPick: (String) -> Void
    var onStayInShell: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Reattach a Session")
                .font(.headline)
            Text("Pick the session to return to.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(sessions, id: \.self) { name in
                        Button { onPick(name) } label: {
                            Label(name, systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(action: onStayInShell) {
                        Label("Stay in Shell", systemImage: "terminal").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: 320)
            }
            .frame(maxHeight: 300)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
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
