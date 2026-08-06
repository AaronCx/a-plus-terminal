import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Full-screen terminal for one session: emulator + accessory bar, with
/// state overlays for connecting / reconnecting / suspended.
struct TerminalScreen: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(SessionManager.self) private var sessionManager
    @Environment(PiPCoordinator.self) private var pip
    @Environment(\.dismiss) private var dismiss

    let session: TerminalSession

    @State private var showDictation = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showPreview = false
    /// Port the preview should open on presentation — set when the user taps a
    /// loopback OSC 8 link, nil when they opened the sheet from the toolbar
    /// (which presents the picker instead).
    @State private var previewPort: Int?

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
                if let conflict = session.hostKeyConflict {
                    // Host-key mismatch: hard-failed already (no silent
                    // accept); offer the review-then-re-pin flow.
                    HostKeyConflictView(
                        serverName: session.server.name,
                        conflict: conflict,
                        onAccept: { await session.acceptRotatedHostKey() },
                        onClose: {
                            sessionManager.close(session)
                            dismiss()
                        }
                    )
                } else if let error = session.lastError {
                    // An actual connection failure (auth, unreachable, …).
                    ConnectionFailureView(message: error) {
                        Task { await session.reconnect(maxAttempts: 1) }
                    } onClose: {
                        sessionManager.close(session)
                        dismiss()
                    }
                } else if session.usesMeshyy {
                    // meshyy resumes itself (see appWillEnterForeground), so this
                    // is the moment between foregrounding and the reattach
                    // landing. Showing the paused card here would offer a choice
                    // that is already being made — and its "Fresh Shell" button
                    // would throw away the very session meshyy exists to keep.
                    statusCard {
                        ProgressView("Resuming your session…")
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

            // The daemon holds detached meshyy sessions for this server — the user
            // decides whether this tab resumes one or starts fresh. Never guessed:
            // guessing is exactly what used to drop new tabs into old shells.
            if let survivors = session.meshyySurvivors {
                MeshyySurvivorPickerView(
                    survivors: survivors,
                    onResume: { session.chooseMeshyySession(.resume($0)) },
                    onNew: { session.chooseMeshyySession(.new) }
                )
            }
        }
        .navigationTitle(session.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // Tab-bar visibility is owned solely by TerminalTabView's
        // `path.isEmpty` modifier — a second unconditional `.hidden` here
        // raced it during pop/tab transitions (see the tab-bar-vanishes PR).
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
                // CARRIAGE RETURN, not newline. Every other Enter in the app sends
                // CR (SwiftTerm's `returnByteSequence`), and a raw-mode TUI — an
                // agent's permission prompt, which is exactly what dictation is for
                // — reads LF as a literal line feed rather than Enter. In a cooked
                // shell both happen to submit, which is why this survived: it broke
                // only where it mattered most.
                session.sendInput(Data((appendReturn ? text + "\r" : text).utf8))
            }
        }
        .sheet(isPresented: $showPreview, onDismiss: {
            // Swipe-to-dismiss has to tear the tunnel down too, not just the
            // "Done" button — otherwise a listener stays bound on the phone
            // with no UI attached to it. (stopPreview is idempotent, so the
            // Done path calling it first is harmless.)
            Task { await session.stopPreview() }
            // Give the terminal its focus back. Presenting the sheet resigned
            // it, and SwiftTerm told the running program so (a mode-1004
            // focus-out escape). Nothing on the dismiss path restored either
            // half, so the program behind the terminal — an agent chat is
            // where it shows — kept behaving as an unfocused window: scroll
            // wheel input ignored, first tap swallowed by the refocus. The
            // .onAppear refocus never runs here because a sheet does not
            // detach the screen underneath it.
            session.bridge.focus()
        }) {
            PreviewScreen(session: session, initialPort: previewPort)
        }
        .onChange(of: session.pendingPreviewPort) { _, port in
            // A loopback OSC 8 link was tapped in the terminal. Consume the
            // request so re-tapping the same link presents again.
            guard let port else { return }
            previewPort = port
            session.pendingPreviewPort = nil
            showPreview = true
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
                // The remote shell exited (`exit`) — leave the screen too, and
                // take the keyboard with it. `focus()` made the terminal view
                // first responder; dismissing the screen without resigning
                // leaves UIKit holding a first responder whose view is gone,
                // and it restores the keyboard for it on the next activation —
                // over the session list, with nothing to type into and no way
                // to dismiss it. TerminalTabView backstops the routes that
                // never run this.
                session.bridge.dismissKeyboard()
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
            // Pre-arm the pop-out engine so the system's auto path can start
            // it on app switch (no-op unless both toggles are on).
            pip.sessionScreenAppeared(session)
        }
        .onDisappear {
            pip.sessionScreenDisappeared(session)
        }
    }

    /// Extracted from the `.toolbar` call site deliberately: with the Preview
    /// item added, the inline builder pushed the whole `body` past the Swift
    /// type-checker's budget ("unable to type-check this expression in
    /// reasonable time"). Annotating the return type is what fixes it — keep
    /// this separate rather than inlining it back.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Preview a dev server running on the far end. Only while connected:
        // the tunnel rides this session's SSH connection, so there is nothing
        // to forward over a paused one.
        if session.state == .connected {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    previewPort = nil
                    showPreview = true
                } label: {
                    Image(systemName: "macwindow")
                }
                .accessibilityLabel("Preview Local Server")
            }
        }
        // Pop-out (beta): user-initiated only — this tap (or the system's
        // auto-inline path) is the sole way a PiP window appears (§5).
        if pip.isAvailable && session.state == .connected {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    pip.popOut(session)
                } label: {
                    Image(systemName: "pip.enter")
                }
                .accessibilityLabel("Pop Out Session")
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
/// Detached meshyy sessions found on the server at connect time. The card the
/// connect parks behind: each survivor is a shell still running exactly as it was
/// left, and only a tap — never a guess — puts this tab into one.
struct MeshyySurvivorPickerView: View {
    let survivors: [MeshyyTransport.RemoteSession]
    var onResume: (String) -> Void
    var onNew: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(survivors.count == 1 ? "A Session Is Still Running" : "Sessions Are Still Running")
                .font(.headline)
            Text("This server kept working while the app was away. Pick a session to resume, or start fresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(survivors) { survivor in
                        Button { onResume(survivor.name) } label: {
                            VStack(spacing: 2) {
                                Label("Resume Session \(survivor.slot + 1)",
                                      systemImage: "arrow.uturn.backward")
                                Text(detail(for: survivor))
                                    .font(.caption2)
                                    .opacity(0.8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(action: onNew) {
                        Label("New Session", systemImage: "plus.rectangle").frame(maxWidth: .infinity)
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

    private func detail(for survivor: MeshyyTransport.RemoteSession) -> String {
        var parts: [String] = []
        if let last = survivor.lastOutputAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append("active \(formatter.localizedString(for: last, relativeTo: Date()))")
        }
        if survivor.bufferedBytes > 0 {
            parts.append(ByteCountFormatter.string(
                fromByteCount: Int64(survivor.bufferedBytes), countStyle: .memory))
        }
        return parts.isEmpty ? "\(survivor.cols)×\(survivor.rows)" : parts.joined(separator: " · ")
    }
}

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

/// Hard-fail card for generic connection failures (auth, unreachable, …).
/// Host-key mismatches route to `HostKeyConflictView` instead; there is
/// deliberately no "trust anyway" button here (§4.1).
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
