import SwiftUI

/// Terminal tab (§4.2): `+` new session top-left, Close All top-right,
/// active sessions above the server list.
struct TerminalTabView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(PasswordStore.self) private var passwords
    @Environment(DeepLinkRouter.self) private var router

    @State private var editingServer: Server?
    @State private var addingServer = false
    @State private var discovering = false
    @State private var discoveredServer: Server?
    @State private var reachability = ReachabilityStore()
    @State private var wakeSentFor: String?
    @State private var wakeError: String?
    /// Path-based navigation: replacing the path swaps the visible session
    /// atomically — `navigationDestination(item:)` ignores item changes while
    /// a screen is already pushed (Island switching between sessions).
    @State private var path: [TerminalSession] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !sessionManager.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(sessionManager.sessions) { session in
                            SessionRow(session: session) {
                                sessionManager.close(session)
                            }
                            .accessibilityIdentifier("session-\(session.id.uuidString)")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                path = [session]
                            }
                        }
                    }
                }

                if serverStore.servers.isEmpty {
                    Section("Servers") {
                        ContentUnavailableView(
                            "No Servers",
                            systemImage: "server.rack",
                            description: Text("Tap + to add your first server.")
                        )
                    }
                } else {
                    ForEach(serverGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.servers) { server in
                                ServerRow(server: server, status: reachability.statuses[server.id] ?? .unknown)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        path = [sessionManager.open(server: server)]
                                    }
                                    .contextMenu {
                                        Button {
                                            editingServer = server
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        if server.macAddress != nil {
                                            Button {
                                                wake(server)
                                            } label: {
                                                Label("Wake Server", systemImage: "power")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            // Drop the server's saved password
                                            // from the Keychain too — otherwise
                                            // it lingers with no UI to reach it.
                                            if let ref = server.passwordRef {
                                                passwords.removePassword(for: ref)
                                            }
                                            serverStore.remove(id: server.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Terminal")
            // Explicit restore: relying on the pushed screen's `.hidden` alone
            // sometimes leaves the tab bar gone after popping back.
            .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
            .navigationDestination(for: TerminalSession.self) { session in
                // Identity-keyed: swapping the path A→B updates the pushed
                // screen in place, and UIViewRepresentable.makeUIView never
                // re-runs — session A's terminal view would stay mounted.
                TerminalScreen(session: session)
                    .id(session.id)
            }
            .onChange(of: router.targetSessionID) { _, _ in
                consumeDeepLink()
            }
            .onAppear {
                // A cold-launch deep link can land before this view observes
                // changes — consume whatever is already pending.
                consumeDeepLink()
            }
            .task {
                await reachability.refresh(serverStore.servers)
            }
            .refreshable {
                await reachability.refresh(serverStore.servers)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            addingServer = true
                        } label: {
                            Label("Add Server", systemImage: "plus")
                        }
                        Button {
                            discovering = true
                        } label: {
                            Label("Discover on Network…", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Server")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !sessionManager.sessions.isEmpty {
                        Button("Close All") {
                            sessionManager.closeAll()
                        }
                    }
                }
            }
            .sheet(isPresented: $addingServer) {
                ServerEditView()
            }
            .sheet(item: $editingServer) { server in
                ServerEditView(server: server)
            }
            .sheet(isPresented: $discovering) {
                DiscoveryView { found in
                    discoveredServer = found
                }
            }
            .sheet(item: $discoveredServer) { server in
                ServerEditView(prefill: server)
            }
            .alert(
                "Wake packet sent",
                isPresented: Binding(get: { wakeSentFor != nil }, set: { if !$0 { wakeSentFor = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Sent a Wake-on-LAN magic packet to \(wakeSentFor ?? ""). The machine may take a few seconds to wake.")
            }
            .alert(
                "Couldn't send wake packet",
                isPresented: Binding(get: { wakeError != nil }, set: { if !$0 { wakeError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(wakeError ?? "")
            }
        }
    }

    private func wake(_ server: Server) {
        guard let mac = server.macAddress else { return }
        Task {
            do {
                // Only claim success once a packet actually went out — a
                // swallowed error (bad MAC, send failure) must not show the
                // "Wake packet sent" confirmation.
                try await WakeOnLAN.wake(macAddress: mac, host: server.host)
                wakeSentFor = server.name
            } catch {
                wakeError = error.localizedDescription
            }
        }
    }

    /// Ungrouped servers first under "Servers", then named groups A→Z.
    private var serverGroups: [(title: String, servers: [Server])] {
        let grouped = Dictionary(grouping: serverStore.servers) { $0.group }
        var result: [(title: String, servers: [Server])] = []
        if let ungrouped = grouped[nil], !ungrouped.isEmpty {
            result.append((title: "Servers", servers: ungrouped))
        }
        for name in grouped.keys.compactMap({ $0 }).sorted() {
            result.append((title: name, servers: grouped[name] ?? []))
        }
        return result
    }

    /// Live Activity tap → land inside the session (§4.5). After an app
    /// relaunch the tapped session no longer exists — clear the target so a
    /// stale ID can't hijack navigation later; the user just lands in the app.
    private func consumeDeepLink() {
        guard let target = router.targetSessionID else { return }
        router.targetSessionID = nil
        guard let session = sessionManager.session(for: target) else {
            deepLinkLog.debug("consume: no session for \(target.uuidString, privacy: .public)")
            return
        }
        deepLinkLog.debug("consume: switching path to \(session.id.uuidString, privacy: .public)")
        path = [session]
    }
}

struct SessionRow: View {
    let session: TerminalSession
    var onClose: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.server.name)
                    .font(.body.weight(.medium))
                Text(session.startedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Session")
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .suspended: return .orange
        case .closed: return .gray
        }
    }
}

struct ServerRow: View {
    @Environment(KeyStore.self) private var keyStore

    let server: Server
    var status: ReachabilityStore.Status = .unknown

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Server \(statusLabel)")
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body.weight(.medium))
                Text("\(server.username)@\(server.displayAddress)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let keyID = server.keyID, keyStore.key(for: keyID) != nil {
                Text("Key")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            } else if server.passwordRef != nil {
                Text("Pass")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .up: return .green
        case .down: return .red
        case .checking: return .yellow
        case .unknown: return .gray.opacity(0.4)
        }
    }

    private var statusLabel: String {
        switch status {
        case .up: return "reachable"
        case .down: return "unreachable"
        case .checking: return "checking"
        case .unknown: return "status unknown"
        }
    }
}
