import Foundation

/// What a saved entry connects to: an SSH shell (the default, and the only
/// kind before VNC monitors existed) or a view-only VNC screen monitor.
enum ServerKind: String, Codable {
    case ssh
    case vncMonitor
}

/// Auth flavor for a VNC monitor. ARD (username + password) is the primary
/// path for macOS Screen Sharing — classic VNC auth on modern macOS lands on
/// a login screen, ARD goes straight to the desktop.
enum VNCAuthMethod: String, Codable {
    case ard
    case vncPassword
    case none
}

/// One saved host. Compiled into both the app and the widget extension —
/// the widget reads the shared server list to render status. Contains no
/// secrets: keys and passwords stay in the Keychain, referenced by UUID.
struct Server: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    /// SSH shell or VNC monitor. Older saved lists decode as `.ssh`.
    var kind: ServerKind = .ssh
    /// VNC monitors only: how to authenticate. Nil on SSH servers. For
    /// `.ard` and `.vncPassword` the password lives in the Keychain behind
    /// `passwordRef` (a VNC-kind server never uses SSH password auth, so the
    /// field is unambiguous per kind).
    var vncAuthMethod: VNCAuthMethod?
    /// VNC monitors only: a saved SSH server (same machine) whose connection
    /// streams the host's REAL pointer position for the cursor overlay —
    /// macOS screen sharing itself reports nothing about the cursor. Nil =
    /// no bridge (overlay shows injected positions only).
    var cursorBridgeSSHServerID: UUID?
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
    /// The meshyy session this server's terminal was last using, so a relaunch
    /// can return to it instead of asking. Cleared when the daemon no longer has
    /// it: a name that no longer exists is worse than none, because resuming it
    /// would silently create a new shell under an old name.
    var lastMeshyySession: String?
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
    /// Concrete address (e.g. "192.168.1.20") observed when this server was
    /// discovered over Bonjour — the last-resort connect candidate once mDNS
    /// can't resolve the ".local" name (off the home network). Optional —
    /// older saved lists and manually-entered servers decode with nil.
    var lastKnownAddress: String?

    var displayAddress: String {
        let defaultPort = kind == .vncMonitor ? 5900 : 22
        return port == defaultPort ? host : "\(host):\(port)"
    }

    /// Ordered, de-duplicated hosts to try when connecting, best-first:
    /// 1. the stored host exactly as saved;
    /// 2. for ".local" (mDNS) hosts, the bare name — off the local network the
    ///    multicast name is dead, but a VPN with search domains (e.g.
    ///    Tailscale MagicDNS) resolves the bare name through the OS resolver,
    ///    with zero VPN-specific code here;
    /// 3. the concrete address recorded at discovery time, if any.
    /// A manually-entered non-".local" host has no bare-name variant and no
    /// recorded address, so it keeps single-candidate behavior exactly.
    /// Fallback candidates are only trusted under the pinned host key — see
    /// `TerminalSession.connectBestCandidate`.
    var connectionCandidates: [String] {
        var candidates = [host]
        if host.lowercased().hasSuffix(".local") {
            let bare = String(host.dropLast(".local".count))
            if !bare.isEmpty { candidates.append(bare) }
        }
        if let lastKnownAddress, !lastKnownAddress.isEmpty {
            candidates.append(lastKnownAddress)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }

    // Only current keys — the synthesized `encode(to:)` uses these, so legacy
    // fields are never re-written.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, group, keyID, passwordRef
        case lastMultiplexerTarget, lastMeshyySession, agentProfileID, multiplexerProfileID
        case knownHostKey, macAddress, lastKnownAddress
        case kind, vncAuthMethod, cursorBridgeSSHServerID
    }

    /// Read-only key from pre-refactor saved lists, consulted during migration.
    private enum LegacyKeys: String, CodingKey {
        case lastTmuxTarget
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
         kind: ServerKind = .ssh, vncAuthMethod: VNCAuthMethod? = nil,
         cursorBridgeSSHServerID: UUID? = nil,
         group: String? = nil, keyID: UUID? = nil, passwordRef: UUID? = nil,
         lastMultiplexerTarget: String? = nil, lastMeshyySession: String? = nil,
         agentProfileID: String? = nil,
         multiplexerProfileID: String? = nil, knownHostKey: String? = nil, macAddress: String? = nil,
         lastKnownAddress: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.kind = kind
        self.vncAuthMethod = vncAuthMethod
        self.cursorBridgeSSHServerID = cursorBridgeSSHServerID
        self.group = group
        self.keyID = keyID
        self.passwordRef = passwordRef
        self.lastMultiplexerTarget = lastMultiplexerTarget
        self.lastMeshyySession = lastMeshyySession
        self.agentProfileID = agentProfileID
        self.multiplexerProfileID = multiplexerProfileID
        self.knownHostKey = knownHostKey
        self.macAddress = macAddress
        self.lastKnownAddress = lastKnownAddress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        kind = try c.decodeIfPresent(ServerKind.self, forKey: .kind) ?? .ssh
        vncAuthMethod = try c.decodeIfPresent(VNCAuthMethod.self, forKey: .vncAuthMethod)
        cursorBridgeSSHServerID = try c.decodeIfPresent(UUID.self, forKey: .cursorBridgeSSHServerID)
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
        lastKnownAddress = try c.decodeIfPresent(String.self, forKey: .lastKnownAddress)
    }
}
