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

/// Test-side encoder for the openssh-key-v1 container, so tests can exercise
/// the import parser without embedding any literal key material in the repo.
/// Layout mirrors what `ssh-keygen -t ed25519` produces (unencrypted).
enum OpenSSHFixture {
    static let pemHeader = "-----BEGIN OPENSSH PRIVATE KEY-----" // lastgate-ignore
    static let pemFooter = "-----END OPENSSH PRIVATE KEY-----" // lastgate-ignore

    static func pem(blob: Data) -> String {
        var lines = [pemHeader]
        let base64 = blob.base64EncodedString()
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append(pemFooter)
        return lines.joined(separator: "\n")
    }

    static func privateKeyPEM(for key: Curve25519.Signing.PrivateKey, comment: String = "test@relay") -> String {
        var publicBlob = Data()
        publicBlob.appendSSHString(Data("ssh-ed25519".utf8))
        publicBlob.appendSSHString(key.publicKey.rawRepresentation)

        var privateBlock = Data()
        var check = UInt32(0x52656C61).bigEndian
        privateBlock.append(Data(bytes: &check, count: 4))
        privateBlock.append(Data(bytes: &check, count: 4))
        privateBlock.appendSSHString(Data("ssh-ed25519".utf8))
        privateBlock.appendSSHString(key.publicKey.rawRepresentation)
        privateBlock.appendSSHString(key.rawRepresentation + key.publicKey.rawRepresentation)
        privateBlock.appendSSHString(Data(comment.utf8))
        var pad: UInt8 = 1
        while privateBlock.count % 8 != 0 {
            privateBlock.append(pad)
            pad += 1
        }

        var blob = Data("openssh-key-v1\0".utf8)
        blob.appendSSHString(Data("none".utf8))
        blob.appendSSHString(Data("none".utf8))
        blob.appendSSHString(Data())
        var one = UInt32(1).bigEndian
        blob.append(Data(bytes: &one, count: 4))
        blob.appendSSHString(publicBlob)
        blob.appendSSHString(privateBlock)
        return pem(blob: blob)
    }
}

final class KeyStoreTests: XCTestCase {
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

    func testImportedKeyRoundTripsThroughPEM() throws {
        let original = Curve25519.Signing.PrivateKey()
        let pem = OpenSSHFixture.privateKeyPEM(for: original)

        let store = makeStore()
        let key = try store.importKey(named: "imported", openSSHPrivateKey: pem)

        let expectedLine = OpenSSHKey.publicKeyLine(original.publicKey, comment: "relay-imported")
        XCTAssertEqual(key.publicKeyLine, expectedLine)
        XCTAssertEqual(try store.privateKey(for: key.id).rawRepresentation, original.rawRepresentation)
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
    func testParseRecoversGeneratedKey() throws {
        let original = Curve25519.Signing.PrivateKey()
        let parsed = try OpenSSHKey.parsePrivateKey(OpenSSHFixture.privateKeyPEM(for: original))
        XCTAssertEqual(parsed.rawRepresentation, original.rawRepresentation)
        XCTAssertEqual(parsed.publicKey.rawRepresentation, original.publicKey.rawRepresentation)
    }

    func testParseToleratesSurroundingWhitespace() throws {
        let original = Curve25519.Signing.PrivateKey()
        let pem = "\n  \(OpenSSHFixture.privateKeyPEM(for: original))\n\n"
        let parsed = try OpenSSHKey.parsePrivateKey(pem)
        XCTAssertEqual(parsed.rawRepresentation, original.rawRepresentation)
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try OpenSSHKey.parsePrivateKey("not a key")) { error in
            XCTAssertEqual(error as? OpenSSHKey.ParseError, .notOpenSSHFormat)
        }
    }

    func testParseRejectsRSAKeyType() throws {
        // An RSA marker inside the container should fail with a clear error.
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

        XCTAssertThrowsError(try OpenSSHKey.parsePrivateKey(OpenSSHFixture.pem(blob: blob))) { error in
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

        XCTAssertThrowsError(try OpenSSHKey.parsePrivateKey(OpenSSHFixture.pem(blob: blob))) { error in
            XCTAssertEqual(error as? OpenSSHKey.ParseError, .encryptedKeyUnsupported)
        }
    }
}
