import SwiftUI
import UniformTypeIdentifiers

/// SSH key management (§4.7): list, create, import, inspect, export, and
/// delete keys. Deleting a key also unlinks it from any server that
/// referenced it, so those servers show as credential-less instead of
/// silently failing.
struct KeysView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(ServerStore.self) private var serverStore

    @State private var errorMessage: String?
    @State private var showGenerateAlert = false
    @State private var newKeyName = ""
    @State private var showImport = false

    var body: some View {
        List {
            if keyStore.keys.isEmpty {
                ContentUnavailableView(
                    "No Keys",
                    systemImage: "key",
                    description: Text("Generate a key, paste one, or import a key file.")
                )
            }
            ForEach(keyStore.keys) { key in
                NavigationLink {
                    KeyDetailView(keyID: key.id)
                } label: {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newKeyName = ""
                        showGenerateAlert = true
                    } label: {
                        Label("Generate New Key", systemImage: "plus")
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("Import Key…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Key")
            }
        }
        .alert("Generate New Key", isPresented: $showGenerateAlert) {
            TextField("Key name", text: $newKeyName)
                .textInputAutocapitalization(.never)
            Button("Generate") { generate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new ed25519 key pair on this device.")
        }
        .sheet(isPresented: $showImport) {
            // The imported key id is intentionally unused here: the keys list
            // observes KeyStore and refreshes itself, so there's nothing to do
            // with it (unlike ServerEditView, which selects the new key).
            KeyImportView { _ in }
        }
    }

    private func servers(using key: SSHKey) -> [Server] {
        serverStore.servers.filter { $0.keyID == key.id }
    }

    private func generate() {
        do {
            let name = newKeyName.trimmingCharacters(in: .whitespaces)
            try keyStore.generateKey(named: name.isEmpty ? "aplusterminal" : name)
        } catch {
            errorMessage = error.localizedDescription
        }
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

/// Full keypair inspector: rename, copy/share the public key, reveal and
/// export the private key, delete. The private key is rendered only after an
/// explicit reveal tap — that tap is the one path key material takes out of
/// the Keychain.
struct KeyDetailView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

    let keyID: UUID

    @State private var name = ""
    @State private var revealedPEM: String?
    @State private var showExporter = false
    @State private var errorMessage: String?

    private var key: SSHKey? { keyStore.key(for: keyID) }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Key name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: name) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { keyStore.renameKey(id: keyID, to: trimmed) }
                    }
            }

            if let key {
                Section {
                    Text(key.publicKeyLine)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button {
                            UIPasteboard.general.string = key.publicKeyLine
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: key.publicKeyLine) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.caption)
                } header: {
                    Text("Public Key")
                } footer: {
                    Text("Add this line to ~/.ssh/authorized_keys on your server.")
                }

                Section {
                    if let pem = revealedPEM {
                        Text(pem)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button {
                                UIPasteboard.general.string = pem
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                showExporter = true
                            } label: {
                                Label("Save to Files", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                            Button("Hide") { revealedPEM = nil }
                                .buttonStyle(.bordered)
                        }
                        .font(.caption)
                    } else {
                        Button {
                            reveal()
                        } label: {
                            Label("Reveal Private Key", systemImage: "eye")
                        }
                    }
                } header: {
                    Text("Private Key")
                } footer: {
                    Text("Anyone with this key can log in to every server that trusts it. It is stored in this device's Keychain and leaves it only when you reveal, copy, or export it here.")
                }

                if !servers(using: key).isEmpty {
                    Section("Used By") {
                        ForEach(servers(using: key)) { server in
                            Text(server.name)
                        }
                    }
                }

                Section {
                    Button("Delete Key", role: .destructive) {
                        delete(key)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(key?.name ?? "Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = key?.name ?? "" }
        .fileExporter(
            isPresented: $showExporter,
            document: KeyFileDocument(text: revealedPEM ?? ""),
            contentType: .plainText,
            defaultFilename: "id_ed25519-\(key?.name ?? "key")"
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func servers(using key: SSHKey) -> [Server] {
        serverStore.servers.filter { $0.keyID == key.id }
    }

    private func reveal() {
        do {
            revealedPEM = try keyStore.privateKeyPEM(for: keyID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ key: SSHKey) {
        do {
            for var server in servers(using: key) {
                server.keyID = nil
                serverStore.update(server)
            }
            try keyStore.deleteKey(id: key.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Plain-text wrapper so the private key PEM can be written via fileExporter.
struct KeyFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
