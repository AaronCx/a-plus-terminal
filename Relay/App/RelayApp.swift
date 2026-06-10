import SwiftUI

@main
struct RelayApp: App {
    @State private var theme = ThemeStore()
    @State private var servers = ServerStore()
    @State private var keys = KeyStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(theme)
                .environment(servers)
                .environment(keys)
                .preferredColorScheme(theme.theme.colorScheme)
                .onOpenURL { url in
                    DeepLinkRouter.shared.handle(url)
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

    var body: some View {
        @Bindable var theme = theme
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Appearance", selection: $theme.theme) {
                        ForEach(AppTheme.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Routes relay://session/<uuid> deep links. Target selection lands with
/// SessionManager (PR 5) and Live Activities (PR 8).
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private(set) var pendingSessionID: UUID?

    func handle(_ url: URL) {
        guard url.scheme == "relay", url.host == "session" else { return }
        pendingSessionID = UUID(uuidString: url.lastPathComponent)
    }
}
