import Foundation
import Observation

struct Server: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    /// Reference into KeyStore. Contains no secret material.
    var keyID: UUID?
    /// Reference into PasswordStore (Keychain) for password auth. The JSON
    /// stores only this UUID, never the password.
    var passwordRef: UUID?
    /// Last tmux session attached on this server (for auto-reattach, §4.1).
    var lastTmuxTarget: String?
    /// TOFU-pinned host public key (OpenSSH line), recorded on first connect.
    /// Public information — display via `HostKeyFingerprint.fingerprint`.
    var knownHostKey: String?

    var displayAddress: String {
        port == 22 ? host : "\(host):\(port)"
    }
}

/// JSON-backed host list at Application Support. Contains no secrets —
/// private keys stay in the Keychain, referenced by `keyID`.
@Observable
final class ServerStore {
    private(set) var servers: [Server] = []

    private let fileURL: URL

    init(fileURL: URL = ServerStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.servers = (try? JSONDecoder().decode([Server].self, from: Data(contentsOf: fileURL))) ?? []
    }

    static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }

    func add(_ server: Server) {
        servers.append(server)
        persist()
    }

    func update(_ server: Server) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persist()
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        persist()
    }

    func server(for id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(servers))?.write(to: fileURL, options: .atomic)
    }
}
