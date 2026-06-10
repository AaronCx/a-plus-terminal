import SwiftUI

/// Terminal tab: active sessions (PR 5) above the server list (§4.2 layout).
struct TerminalTabView: View {
    @Environment(ServerStore.self) private var serverStore

    @State private var editingServer: Server?
    @State private var addingServer = false
    @State private var openServer: Server?

    var body: some View {
        NavigationStack {
            List {
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
                                    openServer = server
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
            .navigationDestination(item: $openServer) { server in
                TerminalScreen(server: server)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        addingServer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Server")
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
