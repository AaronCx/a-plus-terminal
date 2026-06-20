import SwiftUI
import UniformTypeIdentifiers

struct ServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStore.self) private var serverStore
    @Environment(KeyStore.self) private var keyStore
    @Environment(ProfileStore.self) private var profiles

    @Environment(PasswordStore.self) private var passwords

    /// Sentinel tag for "use the global default" in the optional pickers.
    private static let useDefaultTag = "__default__"

    enum AuthMode: String, CaseIterable, Identifiable {
        case key = "SSH Key"
        case password = "Password" // lastgate-ignore (UI label, not a credential)
        var id: String { rawValue }
    }

    @State private var server: Server
    @State private var portText: String
    @State private var authMode: AuthMode
    @State private var passwordText = ""
    @State private var showKeyImport = false
    @State private var createdKey: SSHKey?
    @State private var errorMessage: String?

    private let isNew: Bool

    init(server: Server? = nil) {
        let initial = server ?? Server(name: "", host: "", username: "")
        _server = State(initialValue: initial)
        _portText = State(initialValue: String(initial.port))
        _authMode = State(initialValue: initial.passwordRef != nil && initial.keyID == nil ? .password : .key)
        isNew = server == nil
    }

    /// A brand-new server with fields pre-filled (e.g. from Bonjour discovery).
    init(prefill: Server) {
        _server = State(initialValue: prefill)
        _portText = State(initialValue: String(prefill.port))
        _authMode = State(initialValue: .key)
        isNew = true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $server.name)
                        .textInputAutocapitalization(.never)
                    TextField("Host (IP or hostname)", text: $server.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $server.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Group (optional)", text: Binding(
                        get: { server.group ?? "" },
                        set: { server.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ))
                }

                Section {
                    TextField("MAC address (optional)", text: Binding(
                        get: { server.macAddress ?? "" },
                        set: { server.macAddress = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                } header: {
                    Text("Wake-on-LAN")
                } footer: {
                    Text("With a MAC address set (e.g. aa:bb:cc:dd:ee:ff), long-press the server to send a wake packet. Enable Wake for network access on the target machine.")
                }

                Section {
                    Picker("Method", selection: $authMode) {
                        ForEach(AuthMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if authMode == .key {
                        Picker("Key", selection: $server.keyID) {
                            Text("None").tag(UUID?.none)
                            ForEach(keyStore.keys) { key in
                                Text(key.name).tag(UUID?.some(key.id))
                            }
                        }
                        Button("Generate New Key") {
                            generateKey()
                        }
                        Button("Import Key…") {
                            showKeyImport = true
                        }
                    } else {
                        SecureField(
                            server.passwordRef != nil ? "Password (saved — leave blank to keep)" : "Password",
                            text: $passwordText
                        )
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(authMode == .key
                        ? "Keys are stored in this device's Keychain. View, copy, or export them any time in Settings › Manage Keys. Add the public key to the server's authorized_keys."
                        : "The password is stored in this device's Keychain only — never in the server list, never synced.")
                }

                Section {
                    Picker("Agent", selection: Binding(
                        get: { server.agentProfileID ?? Self.useDefaultTag },
                        set: { server.agentProfileID = $0 == Self.useDefaultTag ? nil : $0 }
                    )) {
                        Text("Default").tag(Self.useDefaultTag)
                        Text("Auto-detect").tag("auto")
                        ForEach(profiles.agents) { agent in
                            Text(agent.displayName).tag(agent.id)
                        }
                        Text("None").tag("none")
                    }
                    Picker("Multiplexer", selection: Binding(
                        get: { server.multiplexerProfileID ?? Self.useDefaultTag },
                        set: { server.multiplexerProfileID = $0 == Self.useDefaultTag ? nil : $0 }
                    )) {
                        Text("Default").tag(Self.useDefaultTag)
                        ForEach(profiles.multiplexers) { mux in
                            Text(mux.displayName).tag(mux.id)
                        }
                    }
                } header: {
                    Text("Agent & Multiplexer")
                } footer: {
                    Text("Override the global defaults for this server. \"Default\" follows Settings.")
                }

                if let keyID = server.keyID, let key = keyStore.key(for: keyID) {
                    Section("Public Key") {
                        PublicKeyRow(key: key)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showKeyImport) {
                KeyImportView { importedID in
                    server.keyID = importedID
                }
            }
            // Show the freshly generated keypair immediately — the public
            // half needs to reach the server's authorized_keys, and the
            // private half should be visible/exportable at creation time.
            .sheet(item: $createdKey) { key in
                NavigationStack {
                    KeyDetailView(keyID: key.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { createdKey = nil }
                            }
                        }
                }
            }
        }
    }

    private var isValid: Bool {
        !server.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !server.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !server.username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(portText).map { (1...65535).contains($0) } == true
            && (authMode == .key || !passwordText.isEmpty || server.passwordRef != nil)
    }

    private func generateKey() {
        do {
            let name = server.name.trimmingCharacters(in: .whitespaces)
            let key = try keyStore.generateKey(named: name.isEmpty ? "aplusterminal" : name)
            server.keyID = key.id
            createdKey = key
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        server.port = Int(portText) ?? 22
        if authMode == .password {
            server.keyID = nil
            let ref = server.passwordRef ?? UUID()
            if !passwordText.isEmpty {
                do {
                    try passwords.setPassword(passwordText, for: ref)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            server.passwordRef = ref
        } else if let ref = server.passwordRef {
            passwords.removePassword(for: ref)
            server.passwordRef = nil
        }
        if isNew {
            serverStore.add(server)
        } else {
            serverStore.update(server)
        }
        dismiss()
    }
}

struct PublicKeyRow: View {
    let key: SSHKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(key.publicKeyLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
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
        }
        .padding(.vertical, 4)
    }
}

struct KeyImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(KeyStore.self) private var keyStore

    let onImport: (UUID) -> Void

    @State private var name = ""
    @State private var pem = ""
    @State private var showFilePicker = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    TextEditor(text: $pem)
                        .font(.caption.monospaced())
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose Key File…", systemImage: "folder")
                    }
                } header: {
                    Text("Private Key")
                } footer: {
                    Text("Paste an unencrypted OpenSSH ed25519 private key (BEGIN OPENSSH PRIVATE KEY), or pick the key file (e.g. id_ed25519) from Files. It is stored in this device's Keychain only.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                loadKeyFile(result)
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || pem.isEmpty)
                }
            }
        }
    }

    private func importKey() {
        do {
            let key = try keyStore.importKey(named: name.trimmingCharacters(in: .whitespaces), openSSHPrivateKey: pem)
            onImport(key.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads a picked key file into the editor. Files outside the sandbox
    /// need security-scoped access; key files are tiny, so a synchronous
    /// read is fine.
    private func loadKeyFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pem = try String(contentsOf: url, encoding: .utf8)
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = url.lastPathComponent
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't read the key file: \(error.localizedDescription)"
        }
    }
}
