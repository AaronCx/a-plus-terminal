import Foundation

/// One saved host. Compiled into both the app and the widget extension —
/// the widget reads the shared server list to render status. Contains no
/// secrets: keys and passwords stay in the Keychain, referenced by UUID.
struct Server: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    /// Optional list grouping (e.g. "Home", "Work"). Nil = ungrouped.
    var group: String?
    /// Reference into KeyStore. Contains no secret material.
    var keyID: UUID?
    /// Reference into PasswordStore (Keychain) for password auth. The JSON
    /// stores only this UUID, never the password.
    var passwordRef: UUID?
    /// Last multiplexer session attached on this server (for auto-reattach,
    /// §4.1). Migrated from the older `lastTmuxTarget` key.
    var lastMultiplexerTarget: String?
    /// Per-server agent profile id (nil → global default, typically "auto").
    var agentProfileID: String?
    /// Per-server multiplexer profile id (nil → global default, "tmux").
    var multiplexerProfileID: String?
    /// TOFU-pinned host public key (OpenSSH line), recorded on first connect.
    /// Public information — display via `HostKeyFingerprint.fingerprint`.
    var knownHostKey: String?
    /// MAC address for Wake-on-LAN (e.g. "aa:bb:cc:dd:ee:ff"). Optional —
    /// older saved lists decode with nil.
    var macAddress: String?

    var displayAddress: String {
        port == 22 ? host : "\(host):\(port)"
    }

    // Only current keys — the synthesized `encode(to:)` uses these, so legacy
    // fields are never re-written.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, group, keyID, passwordRef
        case lastMultiplexerTarget, agentProfileID, multiplexerProfileID
        case knownHostKey, macAddress
    }

    /// Read-only key from pre-refactor saved lists, consulted during migration.
    private enum LegacyKeys: String, CodingKey {
        case lastTmuxTarget
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
         group: String? = nil, keyID: UUID? = nil, passwordRef: UUID? = nil,
         lastMultiplexerTarget: String? = nil, agentProfileID: String? = nil,
         multiplexerProfileID: String? = nil, knownHostKey: String? = nil, macAddress: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.group = group
        self.keyID = keyID
        self.passwordRef = passwordRef
        self.lastMultiplexerTarget = lastMultiplexerTarget
        self.agentProfileID = agentProfileID
        self.multiplexerProfileID = multiplexerProfileID
        self.knownHostKey = knownHostKey
        self.macAddress = macAddress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        keyID = try c.decodeIfPresent(UUID.self, forKey: .keyID)
        passwordRef = try c.decodeIfPresent(UUID.self, forKey: .passwordRef)
        // Migration: prefer the new key, fall back to the legacy one.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        lastMultiplexerTarget = try c.decodeIfPresent(String.self, forKey: .lastMultiplexerTarget)
            ?? legacy.decodeIfPresent(String.self, forKey: .lastTmuxTarget)
        agentProfileID = try c.decodeIfPresent(String.self, forKey: .agentProfileID)
        multiplexerProfileID = try c.decodeIfPresent(String.self, forKey: .multiplexerProfileID)
        knownHostKey = try c.decodeIfPresent(String.self, forKey: .knownHostKey)
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
    }
}
