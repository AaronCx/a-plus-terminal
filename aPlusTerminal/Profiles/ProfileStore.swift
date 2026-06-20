import Foundation
import Observation

/// Loads agent & multiplexer profiles from the bundled `profiles.json`, then
/// merges a user-editable `profiles.json` in Application Support. User entries
/// (override by `id`, or add new ones) win over built-ins, so adding an agent
/// or multiplexer is data — no recompile. Mirrors the ServerStore/KeyStore
/// pattern.
@MainActor
@Observable
final class ProfileStore {
    private(set) var agents: [AgentProfile] = []
    private(set) var multiplexers: [MultiplexerProfile] = []

    /// Codable shape of both bundled and user files.
    struct ProfileBundle: Codable {
        var agents: [AgentProfile] = []
        var multiplexers: [MultiplexerProfile] = []
    }

    private let userFileURL: URL

    init(userFileURL: URL? = nil) {
        self.userFileURL = userFileURL ?? Self.defaultUserFileURL()
        reload()
    }

    /// Deterministic init with explicit profiles — used by tests and as a
    /// no-disk seeding path. Does not read the bundle or user file.
    init(agents: [AgentProfile], multiplexers: [MultiplexerProfile]) {
        self.userFileURL = Self.defaultUserFileURL()
        self.agents = agents
        self.multiplexers = multiplexers
    }

    func agent(id: String) -> AgentProfile? { agents.first { $0.id == id } }
    func multiplexer(id: String) -> MultiplexerProfile? { multiplexers.first { $0.id == id } }

    /// Built-ins from the bundle, overlaid with user entries (override by id).
    func reload() {
        let bundled = Self.loadBundled()
        let user = Self.loadUser(from: userFileURL)
        agents = Self.merge(builtIn: bundled.agents, user: user.agents, id: \.id)
        multiplexers = Self.merge(builtIn: bundled.multiplexers, user: user.multiplexers, id: \.id)
    }

    /// Persists the user-defined (`builtIn == false`) profiles, leaving the
    /// bundled set untouched, then reloads the merged view.
    func saveUserProfiles(agents userAgents: [AgentProfile], multiplexers userMux: [MultiplexerProfile]) {
        let bundle = ProfileBundle(
            agents: userAgents.filter { !$0.builtIn },
            multiplexers: userMux.filter { !$0.builtIn }
        )
        if let data = try? JSONEncoder().encode(bundle) {
            try? FileManager.default.createDirectory(
                at: userFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: userFileURL, options: .atomic)
        }
        reload()
    }

    // MARK: - Loading

    private static func merge<T>(builtIn: [T], user: [T], id: (T) -> String) -> [T] {
        var byID: [String: T] = [:]
        var order: [String] = []
        for item in builtIn {
            let key = id(item)
            if byID[key] == nil { order.append(key) }
            byID[key] = item
        }
        for item in user {  // user overrides built-ins, appends new ones
            let key = id(item)
            if byID[key] == nil { order.append(key) }
            byID[key] = item
        }
        return order.compactMap { byID[$0] }
    }

    private static func loadBundled() -> ProfileBundle {
        guard let url = Bundle.main.url(forResource: "profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(ProfileBundle.self, from: data) else {
            // The bundle must always ship profiles.json; an empty result here
            // would silently disable detection/reattach, so fall back to a
            // minimal safe set rather than nothing.
            return ProfileBundle(
                agents: [AgentProfile(id: "generic", displayName: "Agent", detectionMarkers: [], attachTemplate: "{path} ")],
                multiplexers: [MultiplexerProfile(id: "none", displayName: "None (raw shell)")]
            )
        }
        return bundle
    }

    private static func loadUser(from url: URL) -> ProfileBundle {
        guard let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(ProfileBundle.self, from: data) else {
            return ProfileBundle()
        }
        // Anything loaded from the user file is, by definition, user-defined.
        return ProfileBundle(
            agents: bundle.agents.map { var a = $0; a.builtIn = false; return a },
            multiplexers: bundle.multiplexers.map { var m = $0; m.builtIn = false; return m }
        )
    }

    private static func defaultUserFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("profiles.json")
    }
}
