import SwiftUI

/// Full-screen terminal for one server connection: emulator + accessory bar,
/// with connecting/failure overlays. Multi-session management lands in PR 5.
struct TerminalScreen: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(ServerStore.self) private var serverStore
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let server: Server

    @State private var connection = SSHConnection()
    @State private var bridge = TerminalBridge()
    @State private var phase: Phase = .connecting

    enum Phase: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    var body: some View {
        ZStack {
            TerminalHostView(connection: connection, bridge: bridge, fontSize: theme.terminalFontSize)

            switch phase {
            case .connecting:
                ProgressView("Connecting to \(server.name)…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let message):
                ConnectionFailureView(message: message) {
                    phase = .connecting
                    Task { await connect() }
                } onClose: {
                    dismiss()
                }
            case .connected:
                EmptyView()
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if phase == .connected {
                KeyAccessoryBar(bridge: bridge) {
                    // Dictation lands in PR 7.
                }
            }
        }
        .task {
            await connect()
        }
        .onDisappear {
            Task { await connection.disconnect() }
        }
    }

    private func connect() async {
        guard let keyID = server.keyID, let privateKey = try? keyStore.privateKey(for: keyID) else {
            phase = .failed("No key is assigned to this server. Edit the server and pick or generate a key, then add its public key to the server's authorized_keys.")
            return
        }
        do {
            try await connection.connect(SSHConnection.Configuration(
                host: server.host,
                port: server.port,
                username: server.username,
                privateKey: privateKey,
                knownHostKey: server.knownHostKey
            ))
            phase = .connected
            bridge.focus()
            if server.knownHostKey == nil, let presented = await connection.serverHostKey {
                // TOFU: pin what the server presented on first contact.
                var updated = server
                updated.knownHostKey = presented
                serverStore.update(updated)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
