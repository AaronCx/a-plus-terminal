import Foundation
import CryptoKit

/// Encoding/decoding for OpenSSH key formats (ed25519 only).
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
                return "Unsupported key type \(type). a+Terminal supports ed25519 keys."
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

    /// Serializes an ed25519 private key as an unencrypted openssh-key-v1 PEM —
    /// the exact format `ssh-keygen` writes and `parsePrivateKey` reads.
    /// Only ever called from an explicit user action (reveal / export).
    static func privateKeyPEM(_ key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        var publicBlob = Data()
        publicBlob.appendSSHString(Data("ssh-ed25519".utf8))
        publicBlob.appendSSHString(key.publicKey.rawRepresentation)

        var privateBlock = Data()
        var check = UInt32.random(in: .min ... .max).bigEndian
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
    static func parsePrivateKey(_ pem: String) throws -> Curve25519.Signing.PrivateKey {
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
        // Outer public-key blob: validate its framing (ssh-ed25519 + 32 bytes).
        guard keyCount == 1, let publicBlob = reader.readString() else { throw ParseError.malformed }
        let outerPublicKey = ed25519Key(fromPublicBlob: publicBlob)

        guard let privateBlock = reader.readString() else { throw ParseError.malformed }
        var priv = SSHBinaryReader(privateBlock)
        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32(), check1 == check2 else {
            throw ParseError.malformed
        }
        guard let keyType = priv.readString().flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw ParseError.malformed
        }
        guard keyType == "ssh-ed25519" else { throw ParseError.unsupportedKeyType(keyType) }
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
        if let outerPublicKey, derived != Data(outerPublicKey) {
            throw ParseError.malformed
        }
        return key
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
