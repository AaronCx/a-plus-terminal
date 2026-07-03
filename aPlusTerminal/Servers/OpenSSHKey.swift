import Foundation
import CryptoKit

/// A supported SSH key algorithm. In-app generation is Ed25519-only by
/// design; import/auth/export additionally support the three ECDSA curves.
enum SSHKeyAlgorithm: String, Codable, CaseIterable {
    case ed25519
    case ecdsaP256 = "ecdsa-p256"
    case ecdsaP384 = "ecdsa-p384"
    case ecdsaP521 = "ecdsa-p521"

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP384: return "ECDSA P-384"
        case .ecdsaP521: return "ECDSA P-521"
        }
    }
    /// SSH wire type string (also the public-line prefix).
    var sshType: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        case .ecdsaP384: return "ecdsa-sha2-nistp384"
        case .ecdsaP521: return "ecdsa-sha2-nistp521"
        }
    }
    /// The [identifier] string embedded in ECDSA blobs; nil for ed25519.
    var curveName: String? {
        switch self {
        case .ed25519: return nil
        case .ecdsaP256: return "nistp256"
        case .ecdsaP384: return "nistp384"
        case .ecdsaP521: return "nistp521"
        }
    }
    /// Fixed scalar size for private-key normalization (see the mpint note in
    /// `OpenSSHKey`).
    var scalarBytes: Int? {
        switch self {
        case .ed25519: return nil
        case .ecdsaP256: return 32
        case .ecdsaP384: return 48
        case .ecdsaP521: return 66
        }
    }
}

/// A decoded private key of any supported algorithm. `rawRepresentation` is
/// what KeyStore persists to the Keychain; `algorithm` (stored in key
/// metadata) selects the decode path on load.
enum StoredPrivateKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    var algorithm: SSHKeyAlgorithm {
        switch self {
        case .ed25519: return .ed25519
        case .p256: return .ecdsaP256
        case .p384: return .ecdsaP384
        case .p521: return .ecdsaP521
        }
    }

    /// The Keychain payload. For ed25519 this is the raw 32-byte seed —
    /// exactly what pre-ECDSA builds stored, so existing items decode
    /// unchanged. For ECDSA it's CryptoKit's fixed-width scalar.
    var rawRepresentation: Data {
        switch self {
        case .ed25519(let key): return key.rawRepresentation
        case .p256(let key): return key.rawRepresentation
        case .p384(let key): return key.rawRepresentation
        case .p521(let key): return key.rawRepresentation
        }
    }

    /// Uncompressed EC point `Q` (x963) of the public half; nil for ed25519.
    var ecdsaPublicPoint: Data? {
        switch self {
        case .ed25519: return nil
        case .p256(let key): return key.publicKey.x963Representation
        case .p384(let key): return key.publicKey.x963Representation
        case .p521(let key): return key.publicKey.x963Representation
        }
    }

    /// SSH public-key blob — the base64 payload of an `authorized_keys` line.
    /// ed25519: `string(type) + string(key)`; ECDSA: `string(type) +
    /// string(curveName) + string(Q)`.
    var publicKeyBlob: Data {
        var blob = Data()
        blob.appendSSHString(Data(algorithm.sshType.utf8))
        if case .ed25519(let key) = self {
            blob.appendSSHString(key.publicKey.rawRepresentation)
        } else if let curveName = algorithm.curveName, let point = ecdsaPublicPoint {
            blob.appendSSHString(Data(curveName.utf8))
            blob.appendSSHString(point)
        }
        return blob
    }

    /// `authorized_keys` line for the public half.
    func publicKeyLine(comment: String) -> String {
        let line = "\(algorithm.sshType) \(publicKeyBlob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// Rebuilds the typed key from the Keychain payload written by
    /// `rawRepresentation`. Metadata written before ECDSA support has no
    /// algorithm field and decodes as `.ed25519` upstream.
    static func decode(algorithm: SSHKeyAlgorithm, rawRepresentation: Data) throws -> StoredPrivateKey {
        switch algorithm {
        case .ed25519:
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        case .ecdsaP256:
            return .p256(try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        case .ecdsaP384:
            return .p384(try P384.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        case .ecdsaP521:
            return .p521(try P521.Signing.PrivateKey(rawRepresentation: rawRepresentation))
        }
    }
}

/// Encoding/decoding for OpenSSH key formats (ed25519 and ECDSA
/// P-256/P-384/P-521).
enum OpenSSHKey {
    enum ParseError: LocalizedError, Equatable {
        case notOpenSSHFormat
        case encryptedKeyUnsupported
        case unsupportedKeyType(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notOpenSSHFormat:
                return "Not an OpenSSH private key. Paste the full key including the BEGIN/END lines."
            case .encryptedKeyUnsupported:
                return "Passphrase-protected keys aren't supported. Import an unencrypted key."
            case .unsupportedKeyType(let type):
                return "Unsupported key type \(type). a+Terminal supports Ed25519 and ECDSA (P-256/P-384/P-521) keys. RSA and FIDO security-key types aren't supported — generate an Ed25519 key instead."
            case .malformed:
                return "The key data is malformed."
            }
        }
    }

    /// Renders a public key as an `authorized_keys` line: `ssh-ed25519 <base64> <comment>`.
    static func publicKeyLine(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(key.rawRepresentation)
        let line = "ssh-ed25519 \(blob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// Serializes a private key as an unencrypted openssh-key-v1 PEM —
    /// the exact format `ssh-keygen` writes and `parsePrivateKey` reads.
    /// Only ever called from an explicit user action (reveal / export).
    static func privateKeyPEM(_ key: StoredPrivateKey, comment: String) -> String {
        let publicBlob = key.publicKeyBlob

        var privateBlock = Data()
        var check = UInt32.random(in: .min ... .max).bigEndian
        privateBlock.append(Data(bytes: &check, count: 4))
        privateBlock.append(Data(bytes: &check, count: 4))
        // Both families repeat the public blob's fields verbatim inside the
        // private block, then append the family-specific private material.
        privateBlock.append(publicBlob)
        switch key {
        case .ed25519(let key):
            // OpenSSH stores seed (32) + public (32).
            privateBlock.appendSSHString(key.rawRepresentation + key.publicKey.rawRepresentation)
        case .p256, .p384, .p521:
            privateBlock.appendSSHString(mpint(fromScalar: key.rawRepresentation))
        }
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

        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"] // lastgate-ignore (format marker, not a key)
        let base64 = blob.base64EncodedString()
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----") // lastgate-ignore (format marker)
        return lines.joined(separator: "\n")
    }

    /// Parses an unencrypted `-----BEGIN OPENSSH PRIVATE KEY-----` blob (openssh-key-v1).
    static func parsePrivateKey(_ pem: String) throws -> StoredPrivateKey {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(of: "-----BEGIN OPENSSH PRIVATE KEY-----"), // lastgate-ignore (format marker)
              let end = lines.firstIndex(of: "-----END OPENSSH PRIVATE KEY-----"),
              begin < end else {
            throw ParseError.notOpenSSHFormat
        }
        guard let blob = Data(base64Encoded: lines[(begin + 1)..<end].joined()) else {
            throw ParseError.malformed
        }

        var reader = SSHBinaryReader(blob)
        let magic = Data("openssh-key-v1\0".utf8)
        guard reader.readBytes(magic.count) == magic else { throw ParseError.notOpenSSHFormat }

        guard let cipher = reader.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              let kdf = reader.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              reader.readString() != nil,                    // kdf options
              let keyCount = reader.readUInt32() else {
            throw ParseError.malformed
        }
        guard cipher == "none", kdf == "none" else { throw ParseError.encryptedKeyUnsupported }
        guard keyCount == 1, let publicBlob = reader.readString() else { throw ParseError.malformed }

        guard let privateBlock = reader.readString() else { throw ParseError.malformed }
        var priv = SSHBinaryReader(privateBlock)
        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32(), check1 == check2 else {
            throw ParseError.malformed
        }
        guard let keyType = priv.readString().flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw ParseError.malformed
        }
        if keyType == "ssh-ed25519" {
            return .ed25519(try parseEd25519(from: &priv, outerPublicBlob: Data(publicBlob)))
        }
        if let algorithm = SSHKeyAlgorithm.allCases.first(where: { $0 != .ed25519 && $0.sshType == keyType }) {
            return try parseECDSA(algorithm, from: &priv, outerPublicBlob: Data(publicBlob))
        }
        // Anything else — including ssh-rsa and sk-* FIDO types — is unsupported.
        throw ParseError.unsupportedKeyType(keyType)
    }

    /// ed25519 body of the private block: `string(public) + string(seed+public)`.
    private static func parseEd25519(
        from priv: inout SSHBinaryReader, outerPublicBlob: Data
    ) throws -> Curve25519.Signing.PrivateKey {
        guard let innerPublicKey = priv.readString(), innerPublicKey.count == 32,
              let privateKeyData = priv.readString(), privateKeyData.count == 64 else {
            throw ParseError.malformed
        }
        // OpenSSH stores seed (32) + public (32); CryptoKit wants the seed.
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData.prefix(32))

        // Integrity: the public key derived from the seed must match the public
        // field, the trailing 32 bytes of the private field, and the outer blob.
        // A mismatch means a corrupt/tampered key, not a usable one.
        let derived = Data(key.publicKey.rawRepresentation)
        guard derived == Data(innerPublicKey),
              derived == Data(privateKeyData.suffix(32)) else {
            throw ParseError.malformed
        }
        if let outerPublicKey = ed25519Key(fromPublicBlob: outerPublicBlob), derived != Data(outerPublicKey) {
            throw ParseError.malformed
        }
        return key
    }

    /// ECDSA body of the private block: `string(curveName) + string(Q) +
    /// mpint(d)`. The scalar `d` is an SSH mpint — it may carry a leading
    /// `0x00` (high bit set) or be *shorter* than the curve size (leading zero
    /// bytes dropped); `normalizedScalar` fixes both before CryptoKit sees it.
    private static func parseECDSA(
        _ algorithm: SSHKeyAlgorithm, from priv: inout SSHBinaryReader, outerPublicBlob: Data
    ) throws -> StoredPrivateKey {
        guard let scalarWidth = algorithm.scalarBytes,
              let curve = priv.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              curve == algorithm.curveName,
              let innerPoint = priv.readString(),
              let scalarMpint = priv.readString() else {
            throw ParseError.malformed
        }
        let scalar = try normalizedScalar(Data(scalarMpint), width: scalarWidth)
        let key: StoredPrivateKey
        switch algorithm {
        case .ecdsaP256: key = .p256(try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsaP384: key = .p384(try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case .ecdsaP521: key = .p521(try P521.Signing.PrivateKey(rawRepresentation: scalar))
        case .ed25519: throw ParseError.malformed  // unreachable: callers filter ed25519 out
        }

        // Integrity (parity with the ed25519 path): the point derived from `d`
        // must match `Q` in the inner private block and in the outer blob.
        guard let derived = key.ecdsaPublicPoint, derived == Data(innerPoint) else {
            throw ParseError.malformed
        }
        if let outerPoint = ecdsaPoint(fromPublicBlob: outerPublicBlob, algorithm: algorithm),
           derived != outerPoint {
            throw ParseError.malformed
        }
        return key
    }

    /// SSH mpint → fixed-width scalar: strip leading zero bytes (the mpint
    /// sign byte), then left-pad with zeros to the curve's scalar size.
    /// Getting this wrong makes roughly 1 in 256 keys fail to import.
    private static func normalizedScalar(_ mpint: Data, width: Int) throws -> Data {
        let minimal = Data(mpint.drop { $0 == 0 })
        guard minimal.count <= width else { throw ParseError.malformed }
        return Data(repeating: 0, count: width - minimal.count) + minimal
    }

    /// Fixed-width scalar → SSH mpint: minimal big-endian bytes, with `0x00`
    /// prepended iff the high bit of the first byte is set.
    private static func mpint(fromScalar scalar: Data) -> Data {
        let minimal = Data(scalar.drop { $0 == 0 })
        guard let first = minimal.first else { return Data() }  // zero encodes as empty (RFC 4251)
        return first & 0x80 != 0 ? Data([0]) + minimal : minimal
    }

    /// Extracts the 32-byte ed25519 key from an SSH public-key blob
    /// (`ssh-ed25519` string + 32-byte key); nil if it isn't that shape.
    private static func ed25519Key(fromPublicBlob blob: Data) -> Data? {
        var reader = SSHBinaryReader(blob)
        guard let type = reader.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              type == "ssh-ed25519",
              let key = reader.readString(), key.count == 32 else {
            return nil
        }
        return key
    }

    /// Extracts the EC point from an SSH ECDSA public-key blob
    /// (`ecdsa-sha2-nistpXXX` + curve name + point); nil if it isn't that shape.
    private static func ecdsaPoint(fromPublicBlob blob: Data, algorithm: SSHKeyAlgorithm) -> Data? {
        var reader = SSHBinaryReader(blob)
        guard let type = reader.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              type == algorithm.sshType,
              let curve = reader.readString().flatMap({ String(data: $0, encoding: .utf8) }),
              curve == algorithm.curveName,
              let point = reader.readString() else {
            return nil
        }
        return Data(point)
    }
}

private struct SSHBinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// SSH wire-format string: 4-byte big-endian length + payload.
    mutating func readString() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }
}

extension Data {
    mutating func appendSSHString(_ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(payload)
    }
}
