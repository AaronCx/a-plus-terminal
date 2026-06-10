import XCTest
import CryptoKit
@testable import Relay

/// In-memory SecretStore so tests are hermetic and leave nothing in the
/// simulator Keychain.
final class InMemorySecretStore: SecretStore {
    private(set) var storage: [String: Data] = [:]

    func setSecret(_ data: Data, for account: String) throws {
        storage[account] = data
    }

    func secret(for account: String) throws -> Data? {
        storage[account]
    }

    func removeSecret(for account: String) throws {
        storage.removeValue(forKey: account)
    }
}

final class KeyStoreTests: XCTestCase {
    // Generated with: ssh-keygen -t ed25519 -N '' -C 'fixture@relay'
    static let fixturePrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACB39ZuotaGOAhEaVFbL0+EmyaWSyRaurOBy2bLJ77EjYQAAAJCUBHnglAR5
    4AAAAAtzc2gtZWQyNTUxOQAAACB39ZuotaGOAhEaVFbL0+EmyaWSyRaurOBy2bLJ77EjYQ
    AAAEA/vbO0468kCpXgr8gEQTze1W4a9qZvqCZ5LuP+WglozXf1m6i1oY4CERpUVsvT4SbJ
    pZLJFq6s4HLZssnvsSNhAAAADWZpeHR1cmVAcmVsYXk=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let fixturePublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHf1m6i1oY4CERpUVsvT4SbJpZLJFq6s4HLZssnvsSNh"

    private var secrets: InMemorySecretStore!
    private var metadataURL: URL!

    override func setUp() {
        super.setUp()
        secrets = InMemorySecretStore()
        metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keys-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: metadataURL)
        super.tearDown()
    }

    private func makeStore() -> KeyStore {
        KeyStore(secrets: secrets, metadataURL: metadataURL)
    }

    func testGenerateKeyStoresPrivateBytesAndMetadata() throws {
        let store = makeStore()
        let key = try store.generateKey(named: "mac-mini")

        XCTAssertEqual(store.keys.count, 1)
        XCTAssertTrue(key.publicKeyLine.hasPrefix("ssh-ed25519 AAAA"))
        XCTAssertTrue(key.publicKeyLine.hasSuffix("relay-mac-mini"))
        XCTAssertEqual(secrets.storage[key.id.uuidString]?.count, 32)
    }

    func testPublicKeyLineMatchesPrivateKey() throws {
        let store = makeStore()
        let key = try store.generateKey(named: "test")
        let privateKey = try store.privateKey(for: key.id)
        let expected = OpenSSHKey.publicKeyLine(privateKey.publicKey, comment: "relay-test")
        XCTAssertEqual(key.publicKeyLine, expected)
    }

    func testMetadataSurvivesRelaunch() throws {
        let store = makeStore()
        let key = try store.generateKey(named: "persisted")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.keys, [key])
    }

    func testImportFixtureKeyProducesMatchingPublicKey() throws {
        let store = makeStore()
        let key = try store.importKey(named: "imported", openSSHPrivateKey: Self.fixturePrivateKey)
        XCTAssertTrue(key.publicKeyLine.hasPrefix(Self.fixturePublicKey))
    }

    func testDeleteRemovesSecretAndMetadata() throws {
        let store = makeStore()
        let key = try store.generateKey(named: "doomed")
        try store.deleteKey(id: key.id)

        XCTAssertTrue(store.keys.isEmpty)
        XCTAssertNil(secrets.storage[key.id.uuidString])
        XCTAssertThrowsError(try store.privateKey(for: key.id))
    }
}

final class OpenSSHKeyTests: XCTestCase {
    func testParseFixturePrivateKey() throws {
        let key = try OpenSSHKey.parsePrivateKey(KeyStoreTests.fixturePrivateKey)
        let line = OpenSSHKey.publicKeyLine(key.publicKey, comment: "fixture@relay")
        XCTAssertEqual(line, KeyStoreTests.fixturePublicKey + " fixture@relay")
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHKey.parsePrivateKey("not a key")) { error in
            XCTAssertEqual(error as? OpenSSHKey.ParseError, .notOpenSSHFormat)
        }
    }

    func testParseRejectsRSAKeyType() throws {
        // An RSA key in openssh-key-v1 format should fail with a clear error,
        // not crash. Build a minimal blob with an RSA type marker.
        var privBlock = Data()
        var check = UInt32(7).bigEndian
        privBlock.append(Data(bytes: &check, count: 4))
        privBlock.append(Data(bytes: &check, count: 4))
        privBlock.appendSSHString(Data("ssh-rsa".utf8))

        var blob = Data("openssh-key-v1\0".utf8)
        blob.appendSSHString(Data("none".utf8))
        blob.appendSSHString(Data("none".utf8))
        blob.appendSSHString(Data())
        var one = UInt32(1).bigEndian
        blob.append(Data(bytes: &one, count: 4))
        blob.appendSSHString(Data("stub".utf8))
        blob.appendSSHString(privBlock)

        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(blob.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHKey.parsePrivateKey(pem)) { error in
            XCTAssertEqual(error as? OpenSSHKey.ParseError, .unsupportedKeyType("ssh-rsa"))
        }
    }

    func testParseRejectsEncryptedKey() {
        var blob = Data("openssh-key-v1\0".utf8)
        blob.appendSSHString(Data("aes256-ctr".utf8))
        blob.appendSSHString(Data("bcrypt".utf8))
        blob.appendSSHString(Data())
        var one = UInt32(1).bigEndian
        blob.append(Data(bytes: &one, count: 4))

        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(blob.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHKey.parsePrivateKey(pem)) { error in
            XCTAssertEqual(error as? OpenSSHKey.ParseError, .encryptedKeyUnsupported)
        }
    }
}
