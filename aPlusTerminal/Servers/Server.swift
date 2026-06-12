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
    /// Last tmux session attached on this server (for auto-reattach, §4.1).
    var lastTmuxTarget: String?
    /// TOFU-pinned host public key (OpenSSH line), recorded on first connect.
    /// Public information — display via `HostKeyFingerprint.fingerprint`.
    var knownHostKey: String?
    /// MAC address for Wake-on-LAN (e.g. "aa:bb:cc:dd:ee:ff"). Optional —
    /// older saved lists decode with nil.
    var macAddress: String?

    var displayAddress: String {
        port == 22 ? host : "\(host):\(port)"
    }
}
