import SwiftUI

/// Add/edit form for a "Monitor (VNC)" entry: host, port (default 5900),
/// auth method, credentials into the Keychain via the shared PasswordStore.
struct VNCMonitorEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStore.self) private var serverStore
    @Environment(PasswordStore.self) private var passwords

    @State private var server: Server
    @State private var portText: String
    @State private var authMethod: VNCAuthMethod
    @State private var passwordText = ""
    @State private var errorMessage: String?

    private let isNew: Bool

    init(server: Server? = nil) {
        let initial = server ?? Server(
            name: "", host: "", port: 5900, username: "",
            kind: .vncMonitor, vncAuthMethod: .ard
        )
        _server = State(initialValue: initial)
        _portText = State(initialValue: String(initial.port))
        _authMethod = State(initialValue: initial.vncAuthMethod ?? .ard)
        isNew = server == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $server.name)
                        .textInputAutocapitalization(.never)
                    TextField("Host (IP or hostname)", text: $server.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Screen Sharing Host")
                } footer: {
                    Text("Connects directly to your own computer's screen sharing (VNC) — nothing in between. On macOS, enable System Settings › General › Sharing › Screen Sharing. Reach it over Tailscale or an SSH tunnel: classic VNC's own encryption is weak.")
                }

                Section {
                    Picker("Method", selection: $authMethod) {
                        Text("macOS (ARD)").tag(VNCAuthMethod.ard)
                        Text("VNC Password").tag(VNCAuthMethod.vncPassword) // lastgate-ignore (UI label, not a credential)
                        Text("None").tag(VNCAuthMethod.none)
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .ard {
                        TextField("Username", text: $server.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if authMethod != .none {
                        SecureField(
                            server.passwordRef != nil ? "Password (saved — leave blank to keep)" : "Password",
                            text: $passwordText
                        )
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(footerText)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "Add Monitor" : "Edit Monitor")
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
        }
    }

    private var footerText: String {
        switch authMethod {
        case .ard:
            return "Sign in with the Mac's user account — ARD authentication lands straight on the desktop instead of a login screen. Note: if the Mac's screen is LOCKED you'll see its lock screen; a+Terminal is view-only and never types a password, so unlock the Mac (or relax its lock requirement on an always-on machine) to watch the desktop. The password is stored in this device's Keychain."
        case .vncPassword:
            return "Classic VNC authentication uses only the first 8 characters of the password. On modern macOS it usually lands on a login screen — prefer macOS (ARD)."
        case .none:
            return "For VNC servers that accept connections without authentication."
        }
    }

    private var isValid: Bool {
        let hasHost = !server.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !server.host.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(portText).map { (1...65535).contains($0) } == true
        let hasCredential: Bool
        switch authMethod {
        case .ard:
            hasCredential = !server.username.trimmingCharacters(in: .whitespaces).isEmpty
                && (!passwordText.isEmpty || server.passwordRef != nil)
        case .vncPassword:
            hasCredential = !passwordText.isEmpty || server.passwordRef != nil
        case .none:
            hasCredential = true
        }
        return hasHost && hasCredential
    }

    private func save() {
        server.port = Int(portText) ?? 5900
        server.kind = .vncMonitor
        server.vncAuthMethod = authMethod
        server.keyID = nil
        if authMethod == .none {
            if let ref = server.passwordRef {
                passwords.removePassword(for: ref)
                server.passwordRef = nil
            }
        } else if !passwordText.isEmpty {
            // Mirror ServerEditView: Keychain write must succeed before the
            // store mutation; blank keeps the existing entry.
            let ref = server.passwordRef ?? UUID()
            do {
                try passwords.setPassword(passwordText, for: ref)
            } catch {
                errorMessage = "Couldn't save the password to the Keychain: \(error.localizedDescription)"
                return
            }
            server.passwordRef = ref
        }
        if authMethod != .ard {
            server.username = ""
        }
        if isNew {
            serverStore.add(server)
        } else {
            serverStore.update(server)
        }
        dismiss()
    }
}
