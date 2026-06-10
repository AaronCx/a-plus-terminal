import SwiftUI

@main
struct RelayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var theme: ThemeStore
    @State private var servers: ServerStore
    @State private var keys: KeyStore
    @State private var settings: AppSettings
    @State private var sessions: SessionManager

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
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(theme)
                .environment(servers)
                .environment(keys)
                .environment(settings)
                .environment(sessions)
                .preferredColorScheme(theme.theme.colorScheme)
                .onOpenURL { url in
                    DeepLinkRouter.shared.handle(url)
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
            SettingsTabPlaceholder()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

/// Placeholder until PR 9 lands the full settings build-out.
struct SettingsTabPlaceholder: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var theme = theme
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Appearance", selection: $theme.theme) {
                        ForEach(AppTheme.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
                Section {
                    Toggle("Auto-reattach tmux", isOn: $settings.autoReattachTmux)
                } footer: {
                    Text("After reconnecting, automatically attach to the tmux session you were in.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Routes relay://session/<uuid> deep links. Target selection lands with
/// Live Activities (PR 8).
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private(set) var pendingSessionID: UUID?

    func handle(_ url: URL) {
        guard url.scheme == "relay", url.host == "session" else { return }
        pendingSessionID = UUID(uuidString: url.lastPathComponent)
    }
}
