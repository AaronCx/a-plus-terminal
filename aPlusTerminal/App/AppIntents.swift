import AppIntents
import Foundation

/// A saved server, surfaced to Shortcuts/Siri. Reads the shared snapshot so
/// the picker works even before the app has launched this boot.
struct ServerEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerEntityQuery()

    let id: UUID
    let name: String
    let address: String
    let hasMAC: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(address)")
    }

    init(_ server: Server) {
        id = server.id
        name = server.name
        address = server.displayAddress
        hasMAC = server.macAddress != nil
    }
}

struct ServerEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        ServerStore.sharedSnapshot()
            .filter { identifiers.contains($0.id) }
            .map(ServerEntity.init)
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        ServerStore.sharedSnapshot().map(ServerEntity.init)
    }
}

struct ConnectToServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Server"
    static let description = IntentDescription(
        "Opens a+Terminal and starts a session to a saved server.")
    static let openAppWhenRun = true

    @Parameter(title: "Server")
    var server: ServerEntity

    @Dependency
    private var router: DeepLinkRouter

    @MainActor
    func perform() async throws -> some IntentResult {
        router.requestConnect(toServer: server.id)
        return .result()
    }
}

/// Picker source for WakeServerIntent: only servers with a stored MAC.
struct WakeableServerOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [ServerEntity] {
        ServerStore.sharedSnapshot()
            .filter { $0.macAddress != nil }
            .map(ServerEntity.init)
    }
}

struct WakeServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Wake Server"
    static let description = IntentDescription(
        "Sends a Wake-on-LAN magic packet to a saved server with a MAC address.")
    // The app process holds the local-network permission — run in-app.
    static let openAppWhenRun = true

    @Parameter(title: "Server", optionsProvider: WakeableServerOptionsProvider())
    var server: ServerEntity

    @Dependency
    private var servers: ServerStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Same send path as the server row's "Wake Server" button.
        guard let saved = servers.server(for: server.id), let mac = saved.macAddress else {
            return .result(dialog: "\(server.name) has no saved MAC address.")
        }
        try await WakeOnLAN.wake(macAddress: mac, host: saved.host)
        return .result(dialog: "Magic packet sent to \(server.name).")
    }
}

struct AplusTerminalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToServerIntent(),
            phrases: [
                "Connect to \(\.$server) in \(.applicationName)",
                "Open \(\.$server) in \(.applicationName)",
                "SSH to \(\.$server) in \(.applicationName)"
            ],
            shortTitle: "Connect",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: WakeServerIntent(),
            phrases: [
                "Wake \(\.$server) in \(.applicationName)"
            ],
            shortTitle: "Wake",
            systemImageName: "power"
        )
    }
}
