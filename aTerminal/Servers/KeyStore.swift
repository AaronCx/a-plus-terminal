import Foundation
import CryptoKit
import Observation
import Security

struct SSHKey: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// `authorized_keys`-format public key line. Safe to display and export.
    let publicKeyLine: String
}

enum KeyStoreError: LocalizedError {
    case keychainFailure(OSStatus)
    case keyNotFound

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            return "Keychain error (\(status))."
        case .keyNotFound:
            return "The private key is missing from the Keychain."
        }
    }
}

/// Stores private key bytes for a key ID. Backed by the Keychain in the app;
/// injectable so unit tests can run hermetically.
protocol SecretStore {
    func setSecret(_ data: Data, for account: String) throws
    func secret(for account: String) throws -> Data?
    func removeSecret(for account: String) throws
}

/// Generic-password Keychain items, `WhenUnlockedThisDeviceOnly` — never synced,
/// never in backups, never exportable through UI.
/// The service string keeps the legacy "relay" prefix: it matches the immutable
/// bundle ID and renaming it would orphan keys stored by earlier builds.
final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "com.aaroncx.relay.keys") {
        self.service = service
    }

    func setSecret(_ data: Data, for account: String) throws {
        try removeSecret(for: account)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychainFailure(status) }
    }

    func secret(for account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeyStoreError.keychainFailure(status)
        }
    }

    func removeSecret(for account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychainFailure(status)
        }
    }
}

/// Server login passwords: Keychain-only (`WhenUnlockedThisDeviceOnly`), keyed
/// by a per-server reference UUID. Same zero-export posture as private keys —
/// the server list JSON never contains them.
@Observable
final class PasswordStore {
    private let secrets: SecretStore

    init(secrets: SecretStore = KeychainSecretStore(service: "com.aaroncx.relay.passwords")) {
        self.secrets = secrets
    }

    func setPassword(_ password: String, for ref: UUID) throws {
        try secrets.setSecret(Data(password.utf8), for: ref.uuidString)
    }

    func password(for ref: UUID) -> String? {
        guard let data = try? secrets.secret(for: ref.uuidString) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removePassword(for ref: UUID) {
        try? secrets.removeSecret(for: ref.uuidString)
    }
}

/// ed25519 key management: in-app generation, OpenSSH import, public-key export.
/// Metadata (names, public keys) lives in a JSON file; private key bytes live
/// only in the Keychain.
@Observable
final class KeyStore {
    private(set) var keys: [SSHKey] = []

    private let secrets: SecretStore
    private let metadataURL: URL

    init(secrets: SecretStore = KeychainSecretStore(), metadataURL: URL = KeyStore.defaultMetadataURL()) {
        self.secrets = secrets
        self.metadataURL = metadataURL
        self.keys = (try? JSONDecoder().decode([SSHKey].self, from: Data(contentsOf: metadataURL))) ?? []
    }

    static func defaultMetadataURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keys.json")
    }

    @discardableResult
    func generateKey(named name: String) throws -> SSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        return try addKey(privateKey, named: name)
    }

    @discardableResult
    func importKey(named name: String, openSSHPrivateKey pem: String) throws -> SSHKey {
        let privateKey = try OpenSSHKey.parsePrivateKey(pem)
        return try addKey(privateKey, named: name)
    }

    func privateKey(for id: UUID) throws -> Curve25519.Signing.PrivateKey {
        guard let data = try secrets.secret(for: id.uuidString) else { throw KeyStoreError.keyNotFound }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    func key(for id: UUID) -> SSHKey? {
        keys.first { $0.id == id }
    }

    func deleteKey(id: UUID) throws {
        try secrets.removeSecret(for: id.uuidString)
        keys.removeAll { $0.id == id }
        persist()
    }

    func renameKey(id: UUID, to name: String) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index].name = name
        persist()
    }

    private func addKey(_ privateKey: Curve25519.Signing.PrivateKey, named name: String) throws -> SSHKey {
        let id = UUID()
        try secrets.setSecret(privateKey.rawRepresentation, for: id.uuidString)
        let key = SSHKey(
            id: id,
            name: name,
            createdAt: Date(),
            publicKeyLine: OpenSSHKey.publicKeyLine(privateKey.publicKey, comment: "aterminal-\(name)")
        )
        keys.append(key)
        persist()
        return key
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(keys))?.write(to: metadataURL, options: .atomic)
    }
}
