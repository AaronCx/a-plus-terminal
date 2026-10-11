import Foundation
import Observation

/// Loads agent & multiplexer profiles from the bundled `profiles.json`, then
/// merges a user-editable `profiles.json` in Application Support. User entries
/// (override by `id`, or add new ones) win over built-ins, so adding an agent
/// or multiplexer is data — no recompile. Mirrors the ServerStore/KeyStore
/// pattern.
///
/// Writes (Settings › Agents, import) go to the user file only. Sessions
/// capture their agent candidates when they open, so an edit, import or
/// delete applies to sessions opened AFTER it; open sessions keep what they
/// started with.
@MainActor
@Observable
final class ProfileStore {
    private(set) var agents: [AgentProfile] = []
    private(set) var multiplexers: [MultiplexerProfile] = []
    /// Why the user file could not be used, for the Agents screen to show.
    /// Nil when it loaded (or simply does not exist yet).
    private(set) var loadError: String?

    /// Codable shape of both bundled and user files.
    struct ProfileBundle: Codable {
        var agents: [AgentProfile] = []
        var multiplexers: [MultiplexerProfile] = []

        init(agents: [AgentProfile] = [], multiplexers: [MultiplexerProfile] = []) {
            self.agents = agents
            self.multiplexers = multiplexers
        }

        private enum CodingKeys: String, CodingKey { case agents, multiplexers }

        /// Lenient: either array may be missing, so a hand-written file with
        /// only "agents" imports. Synthesized Decodable ignores the property
        /// defaults and would demand both keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agents = try c.decodeIfPresent([AgentProfile].self, forKey: .agents) ?? []
            multiplexers = try c.decodeIfPresent([MultiplexerProfile].self, forKey: .multiplexers) ?? []
        }
    }

    /// Everything the write path can refuse, worded for the person holding
    /// the phone (shown verbatim in the Agents screen's alerts).
    enum ProfileError: LocalizedError, Equatable {
        case malformedJSON(String)
        case noAgents
        case invalidID(String)
        case reservedID(String)
        case duplicateID(String)
        case emptyName(String)
        case noDetectionMarkers(String)
        case userFileUnavailable
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .malformedJSON(let detail):
                return "That file isn't a valid agents file (\(detail))."
            case .noAgents:
                return "That file doesn't contain any agents."
            case .invalidID(let id):
                return "The agent id \"\(id)\" isn't allowed. Ids use only lowercase letters, digits and hyphens, at most 64 characters."
            case .reservedID(let id):
                return "\"\(id)\" is a built-in agent. Import only adds or updates custom agents."
            case .duplicateID(let id):
                return "The file lists the agent id \"\(id)\" more than once."
            case .emptyName(let id):
                return "The agent \"\(id)\" has no name."
            case .noDetectionMarkers(let name):
                return "\"\(name)\" has nothing to recognize it by. Add at least one command name or startup phrase."
            case .userFileUnavailable:
                return "Your saved agents couldn't be read right now, so nothing was changed. Try again after unlocking the device."
            case .saveFailed(let detail):
                return "Couldn't save agents: \(detail)"
            }
        }
    }

    /// The user file as loaded, kept apart from the merged view: saving
    /// must write back the user's multiplexers and built-in overrides too,
    /// and `merge` forgets which entries came from where.
    private var userBundle = ProfileBundle()
    /// Ids that ship in the app bundle. Everything else is a custom agent.
    private(set) var bundledAgentIDs: Set<String> = []
    /// True when the user file exists but could not be READ (e.g. data
    /// protection before first unlock). Saving then would replace a file we
    /// never saw, so every write refuses instead.
    private var userFileUnreadable = false
    /// Nil for the in-memory test seam: nothing is read or written.
    private let userFileURL: URL?

    init(userFileURL: URL? = nil) {
        self.userFileURL = userFileURL ?? Self.defaultUserFileURL()
        reload()
    }

    /// Deterministic init with explicit profiles — used by tests and as a
    /// no-disk seeding path. Does not read the bundle or user file, and never
    /// writes one.
    init(agents: [AgentProfile], multiplexers: [MultiplexerProfile]) {
        self.userFileURL = nil
        self.agents = agents
        self.multiplexers = multiplexers
        self.userBundle = ProfileBundle(agents: agents.filter { !$0.builtIn })
        self.bundledAgentIDs = Set(agents.filter(\.builtIn).map(\.id))
    }

    func agent(id: String) -> AgentProfile? { agents.first { $0.id == id } }
    func multiplexer(id: String) -> MultiplexerProfile? { multiplexers.first { $0.id == id } }

    /// Built-in agents that the Agents screen lists (the generic fallback is
    /// a mode, not an agent anyone picks an icon for).
    var builtInAgents: [AgentProfile] {
        agents.filter { bundledAgentIDs.contains($0.id) && $0.id != "generic" }
    }

    /// Agents the user made (or imported) — not overrides of built-in ids.
    var customAgents: [AgentProfile] {
        agents.filter { !bundledAgentIDs.contains($0.id) }
    }

    func isCustom(id: String) -> Bool { agent(id: id) != nil && !bundledAgentIDs.contains(id) }

    /// Built-ins from the bundle, overlaid with user entries (override by id).
    func reload() {
        let bundled = Self.loadBundled()
        bundledAgentIDs = Set(bundled.agents.map(\.id))
        if let userFileURL {
            let loaded = Self.loadUser(from: userFileURL)
            userBundle = loaded.bundle
            userFileUnreadable = loaded.unreadable
            loadError = loaded.error
        }
        applyMerge(bundled: bundled)
    }

    // MARK: - Writing

    /// Adds or replaces a user agent (matched by id) and saves. The profile
    /// is normalized and validated first; on any error nothing changes.
    func upsert(_ agent: AgentProfile) throws {
        let clean = try validated(agent)
        var next = userBundle
        if let index = next.agents.firstIndex(where: { $0.id == clean.id }) {
            next.agents[index] = clean
        } else {
            next.agents.append(clean)
        }
        try commit(next)
    }

    /// Removes a user agent and its custom icon, then saves. For a built-in
    /// id this drops the user's override (back to the bundled profile). The
    /// caller clears references to the id — see `clearReferences(to:...)`.
    func deleteAgent(id: String) throws {
        var next = userBundle
        next.agents.removeAll { $0.id == id }
        try commit(next)
        CustomAgentIconStore.clear(for: id)
    }

    /// Deletes an agent and everything that pointed at it (the Settings and
    /// editor delete path).
    func deleteAgent(id: String, settings: AppSettings, servers: ServerStore) throws {
        try deleteAgent(id: id)
        Self.clearReferences(to: id, settings: settings, servers: servers)
    }

    /// Imports agents from a bundle file (`{"agents":[...]}`). Every agent is
    /// validated before anything is written: on error the store is exactly
    /// as it was. Id policy: an id that matches a BUILT-IN is refused (an
    /// import cannot silently re-skin one); an id that matches an existing
    /// custom agent REPLACES it, keeping its icon (re-importing an updated
    /// export is the point); any other id is added.
    @discardableResult
    func importBundle(_ data: Data) throws -> [AgentProfile] {
        let bundle: ProfileBundle
        do {
            bundle = try JSONDecoder().decode(ProfileBundle.self, from: data)
        } catch let error as DecodingError {
            throw ProfileError.malformedJSON(Self.describe(error))
        } catch {
            throw ProfileError.malformedJSON(error.localizedDescription)
        }
        guard !bundle.agents.isEmpty else { throw ProfileError.noAgents }
        var seen = Set<String>()
        var imported: [AgentProfile] = []
        for agent in bundle.agents {
            guard AgentProfile.isValidID(agent.id) else { throw ProfileError.invalidID(agent.id) }
            guard !bundledAgentIDs.contains(agent.id) else { throw ProfileError.reservedID(agent.id) }
            guard seen.insert(agent.id).inserted else { throw ProfileError.duplicateID(agent.id) }
            imported.append(try validated(agent))
        }
        var next = userBundle
        for agent in imported {
            if let index = next.agents.firstIndex(where: { $0.id == agent.id }) {
                next.agents[index] = agent
            } else {
                next.agents.append(agent)
            }
        }
        try commit(next)
        return imported
    }

    /// The same bundle format, for the given agents only (store order),
    /// pretty-printed with sorted keys. Icons are NOT included: a user's
    /// icon is their own copy and never leaves the device.
    func exportData(agentIDs: [String]) -> Data {
        let wanted = Set(agentIDs)
        let bundle = ProfileBundle(agents: agents.filter { wanted.contains($0.id) }, multiplexers: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(bundle)) ?? Data("{\"agents\":[],\"multiplexers\":[]}".utf8)
    }

    /// Writes the user file atomically. Public so callers can retry after
    /// a transient failure; the mutating methods call it themselves.
    func save() throws {
        try write(userBundle)
    }

    /// When an agent is deleted, nothing may keep pointing at its id: the
    /// global default falls back to auto-detect and per-server picks fall
    /// back to "use default". (An unknown id already behaves like auto at
    /// connect time, but the Pickers would show a blank, dangling choice.)
    static func clearReferences(to id: String, settings: AppSettings, servers: ServerStore) {
        if settings.defaultAgentProfileID == id {
            settings.defaultAgentProfileID = "auto"
        }
        for var server in servers.servers where server.agentProfileID == id {
            server.agentProfileID = nil
            servers.update(server)
        }
    }

    // MARK: - Internals

    private func validated(_ agent: AgentProfile) throws -> AgentProfile {
        guard AgentProfile.isValidID(agent.id) else { throw ProfileError.invalidID(agent.id) }
        var clean = agent.normalized()
        clean.builtIn = false
        guard !clean.displayName.isEmpty else { throw ProfileError.emptyName(agent.id) }
        // A profile without markers is treated as `generic` by the monitor:
        // it could never be named, and its presence would suppress the
        // explicit-agent mode for whoever picks it.
        guard !clean.detectionMarkers.isEmpty else {
            throw ProfileError.noDetectionMarkers(clean.displayName)
        }
        return clean
    }

    /// Write first, then adopt: a failed save leaves memory matching disk.
    private func commit(_ next: ProfileBundle) throws {
        try write(next)
        userBundle = next
        applyMerge(bundled: Self.loadBundled())
    }

    private func write(_ bundle: ProfileBundle) throws {
        guard let userFileURL else { return }  // in-memory seam
        guard !userFileUnreadable else { throw ProfileError.userFileUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: userFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(bundle).write(to: userFileURL, options: .atomic)
        } catch {
            throw ProfileError.saveFailed(error.localizedDescription)
        }
    }

    private func applyMerge(bundled: ProfileBundle) {
        let userAgents = userBundle.agents.map { var a = $0.normalized(); a.builtIn = false; return a }
        let userMultiplexers = userBundle.multiplexers.map { var m = $0; m.builtIn = false; return m }
        agents = Self.merge(builtIn: bundled.agents, user: userAgents, id: \.id)
        multiplexers = Self.merge(builtIn: bundled.multiplexers, user: userMultiplexers, id: \.id)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not JSON" : "bad value at \(path(context.codingPath))"
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\"" + (context.codingPath.isEmpty ? "" : " in \(path(context.codingPath))")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at \(path(context.codingPath))"
        @unknown default:
            return "unreadable"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
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

    private struct UserLoad {
        var bundle = ProfileBundle()
        var unreadable = false
        var error: String?
    }

    /// A missing file is the normal empty state. A file that exists but
    /// can't be read is left alone and blocks writes; one that reads but
    /// doesn't decode is moved aside (never deleted) so the next save can't
    /// silently replace the user's only copy.
    private static func loadUser(from url: URL) -> UserLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return UserLoad() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return UserLoad(unreadable: true, error: "Your saved agents couldn't be read right now, so they're hidden and changes are disabled. They're safe on disk; reopen the app after unlocking the device.")
        }
        do {
            return UserLoad(bundle: try JSONDecoder().decode(ProfileBundle.self, from: data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("profiles.unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                // Couldn't preserve it: refuse writes rather than overwrite.
                return UserLoad(unreadable: true, error: "Your saved agents file is damaged and couldn't be set aside, so changes are disabled.")
            }
            return UserLoad(error: "Your saved agents file was damaged and couldn't be loaded. It was kept as \(aside.lastPathComponent) in the app's files; agents you add now are saved fresh.")
        }
    }

    nonisolated static func defaultUserFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("profiles.json")
    }
}
