import Foundation
import Observation
import os

/// JSON-backed host list. Contains no secrets — private keys stay in the
/// Keychain, referenced by `keyID`. Lives in the App Group container so the
/// status widget can read it; falls back to Application Support when the
/// group container is unavailable (tests, simulators without entitlements).
@Observable
final class ServerStore: @unchecked Sendable {
    // @unchecked Sendable: required by AppDependencyManager/@Dependency (App
    // Intents). All mutation happens on the main thread via SwiftUI.
    static let appGroupID = "group.com.aaroncx.aplusterminal"

    private(set) var servers: [Server] = []
    /// Set when the last save failed (nil after a successful save). Surfaced
    /// in the servers list so a full disk / container failure isn't silent
    /// data loss on next launch.
    private(set) var lastPersistError: String?

    private let fileURL: URL

    init(fileURL: URL = ServerStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.servers = (try? JSONDecoder().decode([Server].self, from: Data(contentsOf: fileURL))) ?? []
    }

    static func defaultFileURL() -> URL {
        let legacy = legacyFileURL()
        guard let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return legacy
        }
        let shared = group.appendingPathComponent("servers.json")
        // One-time migration: earlier builds stored the list app-side.
        if !FileManager.default.fileExists(atPath: shared.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: shared)
        }
        return shared
    }

    private static func legacyFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }

    /// Read-only snapshot for the widget extension — no Observation, no
    /// store instance, just the decoded list from the shared container.
    static func sharedSnapshot() -> [Server] {
        (try? JSONDecoder().decode([Server].self, from: Data(contentsOf: defaultFileURL()))) ?? []
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

    /// Lookup by id. Used only by tests today; kept as a natural accessor.
    func server(for id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(servers).write(to: fileURL, options: .atomic)
            lastPersistError = nil
        } catch {
            lastPersistError = error.localizedDescription
            Logger(subsystem: "com.aaroncx.aplusterminal", category: "persistence")
                .error("server list save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
