import SwiftUI

/// Terminal tab (§4.2): `+` new session top-left, Close All top-right,
/// active sessions above the server list.
struct TerminalTabView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(SessionManager.self) private var sessionManager
    @Environment(DeepLinkRouter.self) private var router

    @State private var editingServer: Server?
    @State private var addingServer = false
    @State private var openSession: TerminalSession?

    var body: some View {
        NavigationStack {
            List {
                if !sessionManager.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(sessionManager.sessions) { session in
                            SessionRow(session: session) {
                                sessionManager.close(session)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openSession = session
                            }
                        }
                    }
                }

                Section("Servers") {
                    if serverStore.servers.isEmpty {
                        ContentUnavailableView(
                            "No Servers",
                            systemImage: "server.rack",
                            description: Text("Tap + to add your first server.")
                        )
                    } else {
                        ForEach(serverStore.servers) { server in
                            ServerRow(server: server)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    openSession = sessionManager.open(server: server)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        serverStore.remove(id: server.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        editingServer = server
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            .navigationTitle("Terminal")
            .navigationDestination(item: $openSession) { session in
                TerminalScreen(session: session)
            }
            .onChange(of: router.targetSessionID) { _, target in
                // Live Activity tap: land inside the session; the reconnect
                // contract fires via scene-phase foregrounding (§4.5).
                guard let target, let session = sessionManager.session(for: target) else { return }
                router.targetSessionID = nil
                openSession = session
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Section("New Session") {
                            ForEach(serverStore.servers) { server in
                                Button(server.name) {
                                    openSession = sessionManager.open(server: server)
                                }
                            }
                        }
                        Button {
                            addingServer = true
                        } label: {
                            Label("Add Server…", systemImage: "server.rack")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Session or Server")
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
        }
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

    var body: some View {
        HStack {
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
            }
        }
    }
}
