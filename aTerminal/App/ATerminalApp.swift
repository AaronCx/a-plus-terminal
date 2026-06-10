import SwiftUI

@main
struct ATerminalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var theme: ThemeStore
    @State private var servers: ServerStore
    @State private var keys: KeyStore
    @State private var settings: AppSettings
    @State private var sessions: SessionManager
    @State private var router = DeepLinkRouter()
    @State private var tipStore = TipStore()

    init() {
        let theme = ThemeStore()
        let servers = ServerStore()
        let keys = KeyStore()
        let settings = AppSettings()
        _theme = State(initialValue: theme)
        _servers = State(initialValue: servers)
        _keys = State(initialValue: keys)
        _settings = State(initialValue: settings)
        _sessions = State(initialValue: SessionManager(keyStore: keys, serverStore: servers, settings: settings))
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
            .environment(settings)
            .environment(sessions)
            .environment(router)
            .environment(tipStore)
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

/// Routes aterminal://session/<uuid> deep links from the Live Activity /
/// Dynamic Island into the matching session (§4.5).
@Observable
final class DeepLinkRouter {
    /// Set when a deep link arrives; TerminalTabView consumes it.
    var targetSessionID: UUID?

    func handle(_ url: URL) {
        guard url.scheme == "aterminal", url.host == "session",
              let id = UUID(uuidString: url.lastPathComponent) else { return }
        targetSessionID = id
    }
}
