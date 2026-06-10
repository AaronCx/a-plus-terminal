import SwiftUI

/// SSH key management (§4.7): list, export, and delete keys. Deleting a key
/// also unlinks it from any server that referenced it, so those servers show
/// as credential-less instead of silently failing.
struct KeysView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(ServerStore.self) private var serverStore

    @State private var errorMessage: String?

    var body: some View {
        List {
            if keyStore.keys.isEmpty {
                ContentUnavailableView(
                    "No Keys",
                    systemImage: "key",
                    description: Text("Generate or import a key when adding a server.")
                )
            }
            ForEach(keyStore.keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(key.name)
                            .font(.body.weight(.medium))
                        Spacer()
                        if !servers(using: key).isEmpty {
                            Text(servers(using: key).map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(key.publicKeyLine)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Text(key.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = key.publicKeyLine
                    } label: {
                        Label("Copy Public Key", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        delete(key)
                    } label: {
                        Label("Delete Key", systemImage: "trash")
                    }
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("SSH Keys")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func servers(using key: SSHKey) -> [Server] {
        serverStore.servers.filter { $0.keyID == key.id }
    }

    private func delete(_ key: SSHKey) {
        do {
            for var server in servers(using: key) {
                server.keyID = nil
                serverStore.update(server)
            }
            try keyStore.deleteKey(id: key.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
