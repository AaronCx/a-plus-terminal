import AppIntents
import SwiftUI
import os

let deepLinkLog = Logger(subsystem: "com.aaroncx.aplusterminal", category: "deeplink")

@main
struct APlusTerminalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var theme: ThemeStore
    @State private var servers: ServerStore
    @State private var keys: KeyStore
    @State private var passwords = PasswordStore()
    @State private var settings: AppSettings
    @State private var profiles: ProfileStore
    @State private var sessions: SessionManager
    @State private var router: DeepLinkRouter
    @State private var tipStore = TipStore()
    @State private var exitDiagnostics: BackgroundExitDiagnostics

    init() {
        let theme = ThemeStore()
        let servers = ServerStore()
        let keys = KeyStore()
        let settings = AppSettings()
        let profiles = ProfileStore()
        _theme = State(initialValue: theme)
        _servers = State(initialValue: servers)
        _keys = State(initialValue: keys)
        _settings = State(initialValue: settings)
        _profiles = State(initialValue: profiles)
        let passwords = PasswordStore()
        _passwords = State(initialValue: passwords)
        // Constructed before SessionManager: its init classifies how the
        // PREVIOUS process died (watchdog forensics) from the record that
        // process left in UserDefaults, then resets the record for this run.
        let exitDiagnostics = BackgroundExitDiagnostics()
        _exitDiagnostics = State(initialValue: exitDiagnostics)
        _sessions = State(initialValue: SessionManager(keyStore: keys, serverStore: servers, passwords: passwords, settings: settings, profiles: profiles, diagnostics: exitDiagnostics))
        let router = DeepLinkRouter()
        _router = State(initialValue: router)
        // App Intents resolve these via @Dependency; the intents run in this
        // process (openAppWhenRun), so they share the live instances.
        AppDependencyManager.shared.add(dependency: router)
        AppDependencyManager.shared.add(dependency: servers)
        #if DEBUG
        TestSeed.applyIfRequested(servers: servers, keys: keys)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
            .environment(theme)
            .environment(servers)
            .environment(keys)
            .environment(passwords)
            .environment(settings)
            .environment(profiles)
            .environment(sessions)
            .environment(router)
            .environment(tipStore)
            .environment(exitDiagnostics)
            .preferredColorScheme(theme.theme.colorScheme)
            .dynamicTypeSize(theme.appTypeSize)
            .onOpenURL { url in
                router.handle(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                sessions.appDidEnterBackground()
            case .active:
                sessions.appWillEnterForeground()
            default:
                break
            }
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            TerminalTabView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
            SettingsScreen()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

/// Routes aplusterminal://session/<uuid> deep links from the Live Activity /
/// Dynamic Island into the matching session (§4.5).
@Observable
final class DeepLinkRouter: @unchecked Sendable {
    /// Set when a deep link arrives; TerminalTabView consumes it.
    var targetSessionID: UUID?
    /// Set when an App Intent (or aplusterminal://connect/<uuid>) asks to
    /// open a session to a saved server; TerminalTabView consumes it.
    var connectServerID: UUID?

    func requestConnect(toServer id: UUID) {
        deepLinkLog.debug("router: connect request \(id.uuidString, privacy: .public)")
        connectServerID = id
    }

    func handle(_ url: URL) {
        // iOS lowercases the scheme but not the host, so compare case-insensitively.
        guard url.scheme == "aplusterminal" else {
            deepLinkLog.debug("router: rejected \(url.absoluteString, privacy: .public)")
            return
        }
        switch url.host?.lowercased() {
        case "session":
            guard let id = UUID(uuidString: url.lastPathComponent) else { break }
            deepLinkLog.debug("router: target=\(id.uuidString, privacy: .public)")
            targetSessionID = id
            return
        case "connect":
            guard let id = UUID(uuidString: url.lastPathComponent) else { break }
            requestConnect(toServer: id)
            return
        default:
            break
        }
        deepLinkLog.debug("router: rejected \(url.absoluteString, privacy: .public)")
    }
}
