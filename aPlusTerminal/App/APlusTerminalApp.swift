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
    @State private var pip: PiPCoordinator
    @State private var vncMonitors: VNCMonitorManager

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
        let sessions = SessionManager(keyStore: keys, serverStore: servers, passwords: passwords, settings: settings, profiles: profiles, diagnostics: exitDiagnostics)
        _sessions = State(initialValue: sessions)
        let router = DeepLinkRouter()
        _router = State(initialValue: router)
        // Pop-Out Sessions (beta): the coordinator is a cheap facade — the
        // AVKit engine only exists while the setting is on and PiP is in use.
        let pip = PiPCoordinator(settings: settings)
        _pip = State(initialValue: pip)
        pip.onRestore = { sessionID in
            // Same mechanism as the Live Activity deep link: front the tab,
            // then let TerminalTabView consume the target.
            router.selectedTab = .terminal
            router.targetSessionID = sessionID
        }
        let vncMonitors = VNCMonitorManager(passwords: passwords, keyStore: keys, serverStore: servers)
        _vncMonitors = State(initialValue: vncMonitors)
        // While a pop-out is live, the background wind-down must not kill
        // the sessions it is monitoring…
        sessions.pipKeepsProcessAlive = { [weak pip] in pip?.isActive ?? false }
        vncMonitors.pipKeepsProcessAlive = { [weak pip] in pip?.isActive ?? false }
        // …and when the pop-out ends while still backgrounded, the normal
        // grace window starts at that moment instead.
        pip.onStoppedInBackground = { [weak sessions, weak vncMonitors] in
            sessions?.appDidEnterBackground()
            vncMonitors?.appDidEnterBackground()
        }
        // Closing a session ends any pop-out mirroring it.
        sessions.pipSessionClosed = { [weak pip] in pip?.sessionClosed($0) }
        vncMonitors.pipSessionClosed = { [weak pip] in pip?.sessionClosed($0) }
        // App Intents resolve these via @Dependency; the intents run in this
        // process (openAppWhenRun), so they share the live instances.
        AppDependencyManager.shared.add(dependency: router)
        AppDependencyManager.shared.add(dependency: servers)
        #if DEBUG
        TestSeed.applyIfRequested(servers: servers, keys: keys, router: router, settings: settings)
        TestSeed.applyVNCIfRequested(servers: servers, passwords: passwords, vncManager: vncMonitors)
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
            .environment(pip)
            .environment(vncMonitors)
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
                vncMonitors.appDidEnterBackground()
            case .active:
                sessions.appWillEnterForeground()
                vncMonitors.appWillEnterForeground()
            default:
                break
            }
        }
    }
}

/// Top-level tabs. Selection lives on the router so deep links and App
/// Intents — consumed by TerminalTabView, which stays mounted while Settings
/// is frontmost — bring their tab forward instead of mutating a background
/// tab's navigation.
enum AppTab: Hashable {
    case terminal, settings
}

struct RootTabView: View {
    @Environment(DeepLinkRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            TerminalTabView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
                .tag(AppTab.terminal)
            SettingsScreen()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        // Load-bearing: reading selectedTab here registers the Observation
        // dependency for this always-frontmost view. On iOS 26 the
        // UIKit-bridged TabView's selection binding alone does NOT register
        // one, so a programmatic `router.selectedTab = .terminal` (deep link
        // / intent) never re-rendered the TabView — TabBarRegressionUITests
        // stays red without this modifier.
        .onChange(of: router.selectedTab) { old, new in
            deepLinkLog.debug("tabview: selection \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public)")
        }
    }
}

/// Routes aplusterminal://session/<uuid> deep links from the Live Activity /
/// Dynamic Island into the matching session (§4.5).
@Observable
final class DeepLinkRouter: @unchecked Sendable {
    /// Tab selection, owned here so deep-link/intent consumption can bring
    /// the Terminal tab forward BEFORE mutating its navigation path — a path
    /// mutation in a background tab applied `.toolbar(.hidden, for: .tabBar)`
    /// to the shared bar underneath Settings (the tab-bar-vanishes bug).
    var selectedTab: AppTab = .terminal
    /// Set when a deep link arrives; TerminalTabView consumes it.
    var targetSessionID: UUID?
    /// Set when an App Intent (or aplusterminal://connect/<uuid>) asks to
    /// open a session to a saved server; TerminalTabView consumes it.
    var connectServerID: UUID?

    func requestConnect(toServer id: UUID) {
        deepLinkLog.debug("router: connect request \(id.uuidString, privacy: .public)")
        // Front the Terminal tab at request time: while Settings is frontmost
        // the background tab's onChange never fires (iOS 26), so the request
        // would sit pending — and on-device the background path mutation hid
        // the shared tab bar. Fronting the tab lets TerminalTabView's
        // onAppear consume the pending request.
        selectedTab = .terminal
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
            // Same request-time fronting as requestConnect — see the comment
            // there.
            selectedTab = .terminal
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
