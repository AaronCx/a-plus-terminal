import SwiftUI

/// Terminal tab (§4.2): `+` new session top-left, Close All top-right,
/// active sessions above the server list.
struct TerminalTabView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(VNCMonitorManager.self) private var vncManager
    @Environment(PasswordStore.self) private var passwords
    @Environment(DeepLinkRouter.self) private var router

    @State private var editingServer: Server?
    @State private var addingServer = false
    @State private var addingMonitor = false
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
                if let persistError = serverStore.lastPersistError {
                    Section {
                        PersistenceWarningRow(message: persistError)
                    }
                }

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

                if !vncManager.sessions.isEmpty {
                    Section("Monitors") {
                        ForEach(vncManager.sessions) { monitor in
                            VNCMonitorRow(session: monitor) {
                                vncManager.close(monitor)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vncManager.presented = monitor
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
                                ServerRow(
                                    server: server,
                                    status: reachability.statuses[server.id] ?? .unknown,
                                    waitingCount: waitingCount(on: server)
                                )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if server.kind == .vncMonitor {
                                            vncManager.open(server: server)
                                        } else {
                                            path = [sessionManager.open(server: server)]
                                        }
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
            // SOLE owner of tab-bar visibility for this tab (do not add other
            // writers): hidden while a session is pushed, visible at the
            // list. Two writers — this plus the pushed screen's own unconditional
            // `.hidden` — raced during pop/tab transitions and could latch
            // the bar hidden; the screen-side writer was removed.
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
            .onChange(of: router.connectServerID) { _, _ in
                consumeConnectRequest()
            }
            .onChange(of: router.targetServerSession?.name) { _, _ in
                consumeServerSessionLink()
            }
            .onAppear {
                // A cold-launch deep link (or App Intent) can land before this
                // view observes changes — consume whatever is already pending.
                consumeDeepLink()
                consumeConnectRequest()
                consumeServerSessionLink()
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
                            addingMonitor = true
                        } label: {
                            Label("Add Monitor (VNC)", systemImage: "display")
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
            .sheet(isPresented: $addingMonitor) {
                VNCMonitorEditView()
            }
            .sheet(item: $editingServer) { server in
                if server.kind == .vncMonitor {
                    VNCMonitorEditView(server: server)
                } else {
                    ServerEditView(server: server)
                }
            }
            .sheet(isPresented: $discovering) {
                DiscoveryView { found in
                    discoveredServer = found
                }
            }
            .sheet(item: $discoveredServer) { server in
                ServerEditView(prefill: server)
            }
            .fullScreenCover(item: Binding(
                get: { vncManager.presented },
                set: { vncManager.presented = $0 }
            )) { monitor in
                VNCMonitorScreen(session: monitor)
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
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                dismissStrandedKeyboard()
            }
        }
    }

    /// Nothing on the bare session list accepts text, so a keyboard standing
    /// over it belongs to a first responder whose screen is gone.
    ///
    /// Field report (build 40): a session was popped out, the phone locked, the
    /// shell expired while away, and returning through the pop-out landed on
    /// this list with the keyboard up — "as if I did come back into the
    /// session". UIKit restores the keyboard for its remembered first responder
    /// on activation whether or not that view still has a screen, so the fix
    /// has to react to the keyboard *appearing* rather than to any one of the
    /// routes that can strand it (remote hangup, wind-down, a pop-out restore
    /// into a session that no longer exists).
    private func dismissStrandedKeyboard() {
        // This view stays mounted while the Settings tab is frontmost and the
        // notification is global, so without the tab check this would yank the
        // keyboard out from under Settings' own text fields (key name, agent
        // profiles) the moment they opened it.
        guard router.selectedTab == .terminal else { return }
        // A sheet or the monitor cover owns the screen, and its fields are
        // entitled to a keyboard.
        guard path.isEmpty, !addingServer, !addingMonitor, !discovering,
              editingServer == nil, discoveredServer == nil, vncManager.presented == nil else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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

    /// Open sessions on `server` whose agent is waiting — the server-list
    /// glance count. A helper, because the same expression inline sent the
    /// type-checker into the weeds.
    private func waitingCount(on server: Server) -> Int {
        sessionManager.sessions.filter {
            $0.server.id == server.id && $0.effectiveAgentStatus == .waiting
        }.count
    }

    /// Notification tap → the NAMED daemon session on a server (PR 3 of the
    /// product brief). The name outlives tabs; the flow is: an open tab
    /// already on that session wins, else a new tab that resumes it, and a
    /// name the daemon no longer holds is SAID OUT LOUD — never silently
    /// swapped for a fresh shell, which is the slot bug's failure class worn
    /// as a convenience.
    private func consumeServerSessionLink() {
        guard let target = router.targetServerSession else { return }
        router.targetServerSession = nil
        // An open tab already attached to that daemon session: just focus it.
        if let existing = sessionManager.sessions.first(where: {
            $0.server.id == target.server && $0.meshyy?.sessionName == target.name
        }) {
            deepLinkLog.debug("consume: focusing named session \(target.name, privacy: .public)")
            router.selectedTab = .terminal
            path = [existing]
            return
        }
        guard let server = serverStore.servers.first(where: { $0.id == target.server }) else {
            deepLinkLog.debug("consume: no server for \(target.server.uuidString, privacy: .public)")
            return
        }
        deepLinkLog.debug("consume: opening \(server.name, privacy: .public) to resume \(target.name, privacy: .public)")
        router.selectedTab = .terminal
        let session = sessionManager.open(server: server)
        session.requestedMeshyySession = target.name
        path = [session]
        // NO connect() here: open() already started one. The extra call ran a
        // SECOND connect concurrently — the exact double-connect the test
        // harness documented in July — and two connects racing into the
        // survivor-picker park can resume its continuation twice, which is a
        // fatalError. That was the crash on tapping a notification.
    }

    /// Live Activity tap → land inside the session (§4.5). After an app
    /// relaunch the tapped session no longer exists — clear the target so a
    /// stale ID can't hijack navigation later; the user just lands in the app.
    private func consumeDeepLink() {
        guard let target = router.targetSessionID else { return }
        router.targetSessionID = nil
        if let session = sessionManager.session(for: target) {
            deepLinkLog.debug("consume: switching path to \(session.id.uuidString, privacy: .public)")
            router.selectedTab = .terminal
            path = [session]
            return
        }
        // A pop-out restore can target a VNC monitor too — present its cover.
        if let monitor = vncManager.session(for: target) {
            deepLinkLog.debug("consume: presenting monitor \(monitor.id.uuidString, privacy: .public)")
            router.selectedTab = .terminal
            vncManager.presented = monitor
            return
        }
        deepLinkLog.debug("consume: no session for \(target.uuidString, privacy: .public)")
    }

    /// App Intent / aplusterminal://connect/<uuid> → open a session to the
    /// saved server. If a session to that server is already open, focus it
    /// instead of stacking a duplicate. A stale or unknown server ID is
    /// cleared and ignored — the user just lands in the app.
    private func consumeConnectRequest() {
        guard let target = router.connectServerID else { return }
        router.connectServerID = nil
        guard let server = serverStore.server(for: target) else {
            deepLinkLog.debug("connect: no server for \(target.uuidString, privacy: .public)")
            return
        }
        if let existing = sessionManager.sessions.first(where: { $0.server.id == server.id }) {
            deepLinkLog.debug("connect: focusing existing session \(existing.id.uuidString, privacy: .public)")
            router.selectedTab = .terminal
            path = [existing]
            return
        }
        deepLinkLog.debug("connect: opening session to \(server.name, privacy: .public)")
        router.selectedTab = .terminal
        path = [sessionManager.open(server: server)]
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
                if session.effectiveAgentStatus == .waiting {
                    Text("\(session.effectiveAgentName ?? "Agent") is waiting")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text(session.startedAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if session.effectiveAgentStatus == .waiting {
                // One glance, no switching: the tab that needs a human says so.
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Agent waiting")
            }
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

/// One open VNC monitor: state dot, name, started time, close button —
/// the SessionRow treatment for monitors.
struct VNCMonitorRow: View {
    let session: VNCMonitorSession
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
            Image(systemName: "display")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Monitor")
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .connected: return .green
        case .connecting, .authenticating, .reconnecting: return .orange
        case .suspended: return .orange
        case .idle, .failed, .closed: return .gray
        }
    }
}

/// Warning row shown when a store's last save failed — a full disk or
/// container failure would otherwise be silent data loss on next launch.
/// A plain list row (not an alert) on purpose: it must survive being ignored.
struct PersistenceWarningRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            Text("Couldn't save changes: \(message). Changes may be lost when the app closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ServerRow: View {
    @Environment(KeyStore.self) private var keyStore

    let server: Server
    var status: ReachabilityStore.Status = .unknown
    /// Open sessions on this server whose agent is waiting on a human. A user
    /// running several agents scans this list; the count is the glance.
    var waitingCount: Int = 0

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Server \(statusLabel)")
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body.weight(.medium))
                Text(server.username.isEmpty ? server.displayAddress : "\(server.username)@\(server.displayAddress)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if waitingCount > 0 {
                Text("\(waitingCount) waiting")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(waitingCount) agents waiting")
            }
            if server.kind == .vncMonitor {
                Text("Monitor")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.2), in: Capsule())
                    .foregroundStyle(.blue)
            } else if let keyID = server.keyID, keyStore.key(for: keyID) != nil {
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
