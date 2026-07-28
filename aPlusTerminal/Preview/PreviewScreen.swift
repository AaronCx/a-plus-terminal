import SwiftUI
import UIKit
import WebKit

/// Sheet that renders a dev server running on the SSH host, reached through the
/// session's loopback-pinned forward (`SSHPortForward`). The whole feature is a
/// *viewer for one tunnel*, never a browser: the navigation guard in
/// `PreviewWebView.Coordinator` refuses every host that isn't loopback, which is
/// what keeps this inside App Review guideline 2.5.6 (no alternate browser) and
/// keeps the App Store privacy label at "Data Not Collected" (guideline 4.7 /
/// the ephemeral data store below — no cookie or localStorage outlives the
/// sheet, so nothing about the user's browsing can be retained or transmitted).
///
/// Deliberately absent, and it must stay absent: any "open this preview in
/// Safari" button for the tunnel URL itself. The listener only exists while
/// a+Terminal is foregrounded — handing `http://127.0.0.1:<port>` to Safari
/// backgrounds this app, iOS suspends it, the listener dies, and Safari lands on
/// "cannot connect to the server". The URL is only meaningful *inside* this
/// sheet. (The "Open in Safari" affordance on the blocked-link banner is the
/// opposite case: that URL is a real remote address Safari can actually reach.)
struct PreviewScreen: View {
    @Environment(\.dismiss) private var dismiss

    let session: TerminalSession

    /// Port to open on appear — the tap target that got us here (an OSC 8 link
    /// or a scraped "Local: http://localhost:5173"). nil presents the picker.
    private let initialPort: Int?

    init(session: TerminalSession, initialPort: Int?) {
        self.session = session
        self.initialPort = initialPort
    }

    /// Ground-truth refresh cadence while this sheet is visible. Slow on
    /// purpose: each tick opens a short-lived exec channel on the shared
    /// connection (see `PortDetector.listenerCommand`), and that channel
    /// competes with the user's own typing on the same transport.
    static let listenerRefreshInterval: TimeInterval = 10

    /// Path of the selected `DetectedPort`, so a scraped "http://localhost:5173/admin"
    /// lands on /admin instead of the app root.
    @State private var selectedPath: String?
    @State private var manualPort = ""
    /// nil = WKWebView's stock mobile UA. See `PreviewWebView.desktopUserAgent`.
    @State private var wantsDesktopLayout = false
    /// Bumped by the Reload button. The URL usually doesn't change between
    /// reloads, so a token is what tells `updateUIView` "load again anyway".
    @State private var reloadToken = 0
    @State private var isStarting = false
    @State private var isLoading = false
    @State private var loadError: String?
    /// Most recent navigation the guard refused, surfaced as a dismissible
    /// banner. Showing it matters: a silently dead tap on an external link
    /// reads as a broken preview, and the user deserves the escape hatch.
    @State private var blockedURL: URL?
    /// Compiled subresource filter for the *bound* port. The web view is not
    /// constructed until this exists, so no page ever renders unfiltered.
    @State private var contentRules: WKContentRuleList?
    @State private var rulesError: String?
    /// Set in `.onDisappear`. `start()` re-reads it after its awaits — see the
    /// note there about the forward that outlives its sheet.
    @State private var isDismissed = false

    private var forward: SSHPortForward? { session.previewForward }

    /// The one URL this sheet ever loads: the bound loopback port, plus the
    /// selected entry's path. `localPort` is 0 until `start()` has bound, which
    /// is exactly the window where the picker (not the web view) is on screen.
    private var previewURL: URL? {
        guard let forward, forward.localPort > 0 else { return nil }
        var path = selectedPath ?? "/"
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(string: "http://127.0.0.1:\(forward.localPort)\(path)")
    }

    private var validatedManualPort: Int? {
        guard let port = Int(manualPort.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(port) else { return nil }
        return port
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if forward?.matchesRemotePort == false {
                    liveReloadWarningBanner
                }
                if let blockedURL {
                    blockedBanner(blockedURL)
                }

                content

                foregroundOnlyNote
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        Task { await session.stopPreview() }
                        dismiss()
                    }
                    .accessibilityLabel("Close Preview")
                }
                if previewURL != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            loadError = nil
                            reloadToken += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Reload Preview")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // Dev servers ship a different layout per UA, and
                            // the mobile one is usually NOT what you opened the
                            // preview to check.
                            wantsDesktopLayout.toggle()
                        } label: {
                            Image(systemName: wantsDesktopLayout ? "desktopcomputer" : "iphone")
                        }
                        .accessibilityLabel(wantsDesktopLayout
                            ? "Switch to Mobile Layout"
                            : "Switch to Desktop Layout")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                // Awaited, and the per-load state is cleared
                                // only after the teardown completes: starting
                                // the next forward while this listener is
                                // still closing races the bind and can silently
                                // take the collision fallback.
                                await session.stopPreview()
                                contentRules = nil
                                rulesError = nil
                                selectedPath = nil
                                loadError = nil
                                blockedURL = nil
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("Choose Another Port")
                    }
                }
            }
        }
        .task {
            // Everything periodic in this screen lives here, in ONE `.task`,
            // for one reason: `.task` is torn down when the view disappears, so
            // dismissing the sheet stops the polling — no Timer, no detached
            // Task, nothing that keeps opening exec channels behind the user's
            // back. Do NOT add a background timer for this: the session
            // keepalive already owns the connection's idle cadence (a no-op
            // window-change on the live PTY every ~25s), and a second
            // independent poller would interleave exec channels with it for no
            // benefit, on a link the user is also typing on.
            if let initialPort, session.previewForward == nil {
                await start(remotePort: initialPort,
                            path: session.portDetector.ports.first { $0.port == initialPort }?.path)
            }
            while !Task.isCancelled {
                await session.refreshListenerSnapshot()
                try? await Task.sleep(for: .seconds(Self.listenerRefreshInterval))
            }
        }
        .onDisappear { isDismissed = true }
    }

    private var navigationTitle: String {
        if let forward, forward.localPort > 0 {
            return "Port \(forward.remotePort)"
        }
        return "Preview"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isStarting {
            centeredCard {
                ProgressView("Opening tunnel…")
            }
        } else if let previewURL, let contentRules, let port = forward?.localPort {
            ZStack {
                PreviewWebView(
                    url: previewURL,
                    reloadToken: reloadToken,
                    forwardedPort: port,
                    contentRules: contentRules,
                    customUserAgent: wantsDesktopLayout ? PreviewWebView.desktopUserAgent : nil,
                    onLoadingChanged: { isLoading = $0 },
                    onError: { loadError = $0 },
                    onBlocked: { blockedURL = $0 }
                )
                .accessibilityLabel("Preview of port \(forward?.remotePort ?? 0)")

                if isLoading {
                    VStack {
                        loadingIndicator
                        Spacer()
                    }
                }
                if let message = loadError ?? session.previewError {
                    loadFailureCard(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if previewURL != nil {
            // Tunnel is up but the subresource filter isn't ready. Refusing to
            // render here is the point: rendering without it would silently
            // drop the only control that covers fetch/XHR/WebSocket loads.
            if let rulesError {
                loadFailureCard(rulesError)
            } else {
                centeredCard { ProgressView("Preparing preview…") }
            }
        } else {
            portPicker
        }
    }

    /// Shown until a forward is bound: the detected ports (all three detection
    /// sources funnel into this one list) plus manual entry.
    private var portPicker: some View {
        List {
            if let message = session.previewError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Preview error: \(message)")
                }
            }

            Section("Detected Ports") {
                if session.portDetector.ports.isEmpty {
                    Text("Nothing detected yet. Start a dev server in this session, or type its port below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.portDetector.ports) { port in
                        Button {
                            Task { await start(remotePort: port.port, path: port.path) }
                        } label: {
                            portRow(port)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityLabel(for: port))
                    }
                }
            }

            Section("Other Port") {
                HStack {
                    TextField("Port number", text: $manualPort)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Port Number")
                    Button("Open") {
                        guard let port = validatedManualPort else { return }
                        // No scraped path for a hand-typed port — start at root.
                        Task { await start(remotePort: port, path: nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(validatedManualPort == nil)
                    .accessibilityLabel("Open Typed Port")
                }
                if !manualPort.isEmpty && validatedManualPort == nil {
                    Text("Enter a port between 1 and 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func portRow(_ port: DetectedPort) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(String(port.port))
                    .font(.body.weight(.semibold).monospacedDigit())
                if let process = port.process {
                    Text(process)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let path = port.path, path != "/" {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if port.isStale {
                Text("Not in the last two listener checks — this server may have exited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Stale entries stay tappable (the check runs every 10s, so a server
        // that just restarted can read stale for a beat) but are visibly
        // demoted so a dead port isn't the obvious thing to tap.
        .opacity(port.isStale ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private func accessibilityLabel(for port: DetectedPort) -> String {
        var parts = ["Open port \(port.port)"]
        if let process = port.process { parts.append("process \(process)") }
        if let path = port.path, path != "/" { parts.append("path \(path)") }
        if port.isStale { parts.append("may have exited") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Banners and status

    /// The forward wanted the same local port number as the remote one so that
    /// a dev server's absolute self-references (and its live-reload websocket
    /// URL, which is baked with the *remote* port) resolve. When the number was
    /// already taken on the phone we bound `.any` instead, and live reload will
    /// try to dial a port that isn't ours.
    private var liveReloadWarningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live reload won't reconnect")
                    .font(.subheadline.weight(.semibold))
                Text("Port \(forward?.remotePort ?? 0) was already in use on this device, so the tunnel uses a different local port. The page loads fine; hot-reload updates need a manual Reload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: live reload will not reconnect because the local port could not match the remote port")
    }

    private func blockedBanner(_ url: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Link blocked")
                    .font(.subheadline.weight(.semibold))
                Text("Preview only loads the forwarded server. This link points somewhere else:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if url.scheme == "http" || url.scheme == "https" {
                    Button("Open in Safari") {
                        UIApplication.shared.open(url)
                        blockedURL = nil
                    }
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Open the blocked link in Safari")
                }
            }
            Spacer(minLength: 0)
            Button {
                blockedURL = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss Blocked Link Notice")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Loading…")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .accessibilityLabel("Loading preview")
    }

    private func loadFailureCard(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Preview Failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Port", role: .cancel) {
                    Task { await session.stopPreview() }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Back to Port Picker")
                Button("Retry") {
                    loadError = nil
                    session.previewError = nil
                    reloadToken += 1
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Retry Loading Preview")
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }

    private var foregroundOnlyNote: some View {
        Text("Preview only works while a+Terminal is on screen. If you switch to another app, iOS suspends this one — the local listener closes and the tunnel closes with it. Come back and tap Reload.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityLabel("Preview only works while a+Terminal is on screen. Switching apps closes the tunnel.")
    }

    private func centeredCard(@ViewBuilder content: () -> some View) -> some View {
        VStack {
            Spacer()
            content()
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func start(remotePort: Int, path: String?) async {
        isStarting = true
        contentRules = nil
        rulesError = nil
        // Clear the per-load UI state before the swap: a stale "blocked link"
        // or load error from the previous port would otherwise sit over the new
        // page and read as its failure.
        selectedPath = path
        loadError = nil
        blockedURL = nil
        manualPort = ""
        await session.startPreview(remotePort: remotePort)

        // The user can dismiss the sheet during the awaits above — binding a
        // listener and opening the first channel is a round trip, ~0.5-1s to a
        // VPS. `TerminalScreen`'s onDismiss already ran `stopPreview()` by
        // then, and it was a no-op because `previewForward` was still nil; the
        // assignment above has now published a listener with no UI attached to
        // it. Undoing it here is what actually closes that leak.
        guard !isDismissed else {
            await session.stopPreview()
            isStarting = false
            return
        }

        if let port = session.previewForward?.localPort, port > 0 {
            do {
                contentRules = try await Self.compileContentRules(forwardedPort: port)
            } catch {
                // No filter, no preview. Tear the tunnel back down rather than
                // leave it open behind an error card.
                rulesError = "Couldn't prepare the preview's content filter: \(error.localizedDescription)"
                await session.stopPreview()
            }
        }
        isStarting = false
    }

    /// Compiles the block-everything-but-the-forward rules. WebKit caches the
    /// compiled list under the identifier, so re-opening the same port is
    /// cheap; the identifier carries the port precisely so a different port
    /// can never be served the previous port's allow-rule.
    private static func compileContentRules(forwardedPort: Int) async throws -> WKContentRuleList {
        let json = PreviewNavigationPolicy.contentRuleListJSON(forwardedPort: forwardedPort)
        let identifier = PreviewNavigationPolicy.contentRuleListIdentifier(forwardedPort: forwardedPort)
        guard let store = WKContentRuleListStore.default() else {
            throw PreviewRulesError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? PreviewRulesError.unavailable)
                }
            }
        }
    }
}

enum PreviewRulesError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "WebKit's content rule store was unavailable."
    }
}

/// What the preview is allowed to load. Extracted from the delegate so the
/// single rule that keeps this feature from being a general-purpose browser is
/// *tested* rather than merely reviewed — see `PreviewNavigationPolicyTests`.
///
/// Two layers, because one is not enough:
///
/// - `allows(_:forwardedPort:)` backs `WKNavigationDelegate.decidePolicyFor`,
///   which WebKit consults for main-frame *and* subframe navigations, every
///   navigation type, and every hop of a redirect chain.
/// - `contentRuleListJSON(forwardedPort:)` backs a `WKContentRuleList`, which
///   covers what the navigation delegate structurally cannot see: images,
///   scripts, stylesheets, `fetch`/`XHR`, `EventSource` and WebSockets. Without
///   it, a page could quietly talk to any host on the internet and the claim
///   in `docs/app-store/review-notes.md` would be false.
enum PreviewNavigationPolicy {
    /// Only ever the one forwarded origin. The port matters as much as the
    /// host: iOS loopback is shared by every app on the device, so allowing
    /// "any loopback port" would let a previewed page reach another app's
    /// local server — and after a port-collision fallback, the port we bound
    /// is not even the one the user named.
    static func allows(_ url: URL, forwardedPort: Int) -> Bool {
        // WebKit's own empty document: the initial frame, every freshly
        // created iframe, and the document left behind after a cancel.
        // Blocking it breaks the first paint and protects nothing.
        if url.scheme?.lowercased() == "about" { return true }
        guard let scheme = url.scheme?.lowercased(), Self.allowedSchemes.contains(scheme) else { return false }
        // `host` ignores userinfo, so `http://127.0.0.1@evil.com/` correctly
        // reads as the host `evil.com` and is refused.
        guard let host = url.host, PortDetector.isLoopbackHost(host) else { return false }
        return (url.port ?? (scheme == "https" ? 443 : 80)) == forwardedPort
    }

    private static let allowedSchemes: Set<String> = ["http", "https", "ws", "wss"]

    /// Block everything, then re-allow exactly the forwarded origin. `ws`/`wss`
    /// are in the allow rule deliberately: a dev server's live-reload socket is
    /// the whole reason this feature carries raw bytes instead of proxying, and
    /// omitting the scheme here would block HMR while leaving the page working
    /// — the most confusing possible failure.
    /// Two separate allow rules with deliberately plain patterns. WebKit's
    /// `url-filter` is a restricted regex engine, not NSRegularExpression: an
    /// alternation combining schemes with an anchored suffix
    /// (`^(https?|wss?)://…([/?#]|$)`) is rejected outright with "Invalid or
    /// unsupported regular expression", which at runtime would mean no filter
    /// compiled and — because the sheet refuses to render without one — no
    /// preview at all. `PreviewContentRuleListTests` compiles these on every
    /// CI run so that can never regress silently.
    ///
    /// The trailing `/` is load-bearing as a port boundary: WebKit canonicalises
    /// every URL to have a path, so `:\(forwardedPort)/` matches the forwarded
    /// port and cannot also match `:\(forwardedPort)0/`.
    static func contentRuleListJSON(forwardedPort: Int) -> String {
        """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://127\\\\.0\\\\.0\\\\.1:\(forwardedPort)/"},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^wss?://127\\\\.0\\\\.0\\\\.1:\(forwardedPort)/"},"action":{"type":"ignore-previous-rules"}}
        ]
        """
    }

    /// Identifier is per-port: the compiled list is cached by WebKit under
    /// this key, and reusing one identifier across ports would serve a stale
    /// allow-rule for the wrong port.
    static func contentRuleListIdentifier(forwardedPort: Int) -> String {
        "preview-loopback-\(forwardedPort)"
    }
}

/// The locked-down web view. Every hardening decision here is load-bearing —
/// read the comments before relaxing any of it.
// Internal rather than `private` so `PreviewNavigationPolicyTests` can drive the
// real Coordinator through a real WKWebView. The guard that keeps this from
// being a browser is worth more as a test than as a comment.
struct PreviewWebView: UIViewRepresentable {
    /// Frozen macOS Safari UA for the desktop toggle. It has to be a literal:
    /// WKWebView exposes no synchronous read of its default UA (only an async
    /// `evaluateJavaScript("navigator.userAgent")`), so there's nothing to
    /// append a "desktop" suffix to at the moment we need the string. Dev
    /// servers only ever regex this for "Mobile"/"iPhone", so drift in the
    /// version numbers is harmless.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    let url: URL
    let reloadToken: Int
    /// The one port this view may talk to — the forward's *bound* local port,
    /// which after a collision fallback is not the port the user named.
    let forwardedPort: Int
    /// Compiled block-all-but-the-forward rules. Non-optional on purpose: the
    /// parent will not construct this view until compilation succeeds, so
    /// there is no code path that renders a page without subresource
    /// filtering in place.
    let contentRules: WKContentRuleList
    /// nil restores WKWebView's stock (mobile) UA.
    let customUserAgent: String?
    var onLoadingChanged: (Bool) -> Void
    var onError: (String?) -> Void
    var onBlocked: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            forwardedPort: forwardedPort,
            onLoadingChanged: onLoadingChanged,
            onError: onError,
            onBlocked: onBlocked
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent store: cookies, localStorage, IndexedDB, service
        // workers and the HTTP cache live in memory and die with this view.
        // Nothing the user's dev server sets can survive the sheet, be read
        // back later, or end up in a backup — which is what lets the app keep
        // its "Data Not Collected" privacy label while shipping a web view.
        configuration.websiteDataStore = .nonPersistent()
        // The layer the navigation delegate cannot provide. `decidePolicyFor`
        // only ever sees frame navigations, so without this an <img>, a
        // <script src>, a fetch() or a WebSocket could reach any host on the
        // internet from a page we claim is loopback-only.
        configuration.userContentController.add(contentRules)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // No `uiDelegate` — ON PURPOSE, and it must stay that way. Without a
        // WKUIDelegate implementing `createWebViewWith`, `target="_blank"` and
        // `window.open()` do nothing at all: WebKit has nowhere to put the new
        // window, so it drops the request. Implementing it would hand this
        // sheet a second, unguarded web view — the exact "embedded general
        // purpose browser" shape that guideline 2.5.6 rejects.
        //
        // Back/forward swipes are off for the same reason the URL bar doesn't
        // exist: this is a viewer for one server, not a browsing surface.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        #if DEBUG
        // Safari Web Inspector attach, debug builds only. Never in a shipped
        // build: `isInspectable` on a release binary lets anything with a USB
        // cable read the page the user is previewing.
        webView.isInspectable = true
        #endif
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The representable is re-made on every parent render, so the
        // coordinator's callbacks must be re-pointed at the current @State
        // setters or delegate events would update a stale view snapshot.
        context.coordinator.onLoadingChanged = onLoadingChanged
        context.coordinator.onError = onError
        context.coordinator.onBlocked = onBlocked

        let userAgentChanged = webView.customUserAgent != customUserAgent
        if userAgentChanged {
            webView.customUserAgent = customUserAgent
            // A UA swap only takes effect on the next request — the loaded DOM
            // was built for the old one — so the toggle has to reload, and the
            // reload is driven from here rather than from a token bump in the
            // parent so the two can never disagree.
        }

        let needsLoad = userAgentChanged
            || context.coordinator.loadedURL != url
            || context.coordinator.loadedToken != reloadToken
        guard needsLoad else { return }
        context.coordinator.loadedURL = url
        context.coordinator.loadedToken = reloadToken
        // Cache-defeating by default: a dev server rebuilds its bundle under
        // the same URL constantly, and a cached asset is indistinguishable from
        // "my change didn't take". The ephemeral store makes this cheap.
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    /// Navigation delegate. Not `@MainActor`-annotated for the same reason
    /// `SessionIO` isn't: WebKit calls these on the main thread, and
    /// `MainActor.assumeIsolated` is how this codebase crosses that line
    /// without inventing hops that would let a decision handler run late.
    final class Coordinator: NSObject, WKNavigationDelegate {
        let forwardedPort: Int
        var onLoadingChanged: (Bool) -> Void
        var onError: (String?) -> Void
        var onBlocked: (URL) -> Void

        /// What `updateUIView` last asked for — the diff that decides whether a
        /// render needs a real `load()`.
        var loadedURL: URL?
        var loadedToken: Int?

        init(
            forwardedPort: Int,
            onLoadingChanged: @escaping (Bool) -> Void,
            onError: @escaping (String?) -> Void,
            onBlocked: @escaping (URL) -> Void
        ) {
            self.forwardedPort = forwardedPort
            self.onLoadingChanged = onLoadingChanged
            self.onError = onError
            self.onBlocked = onBlocked
        }

        /// THE guard. Applied to every navigation type (`.linkActivated`,
        /// `.other` — which is what a JS `location =` assignment, a meta
        /// refresh and every server redirect arrive as — form submits, and
        /// reloads) and to every frame, main and sub alike: `targetFrame` is
        /// deliberately never consulted, because an off-host iframe is exactly
        /// as much "an embedded browser" as an off-host top-level page, and it
        /// is the sneakier of the two. Redirects re-enter here per hop, so a
        /// loopback URL that 302s to a remote host is stopped on the hop that
        /// leaves.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let policy = MainActor.assumeIsolated {
                decide(navigationAction.request.url)
            }
            decisionHandler(policy)
        }

        @MainActor
        private func decide(_ url: URL?) -> WKNavigationActionPolicy {
            // No URL to judge (rare, but WebKit permits it) — nothing can be
            // fetched from it either.
            guard let url else { return .allow }
            // `file:` (no host), `data:`, `blob:`, `mailto:` and custom app
            // schemes all fall through to the block path, by design: the
            // forward can only ever produce http on one loopback port.
            if PreviewNavigationPolicy.allows(url, forwardedPort: forwardedPort) { return .allow }
            onBlocked(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                onError(nil)
                onLoadingChanged(true)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { onLoadingChanged(false) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { finish(error) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { finish(error) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated {
                onLoadingChanged(false)
                onError("The preview stopped responding. Tap Reload to load it again.")
            }
        }

        @MainActor
        private func finish(_ error: Error) {
            onLoadingChanged(false)
            let nsError = error as NSError
            // Two "failures" that are really our own guard doing its job: the
            // cancel above surfaces as NSURLErrorCancelled or as WebKit's
            // frame-load-interrupted-by-policy-change (102). Neither is
            // something to show the user — the blocked banner already did.
            let isOurCancel = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
            guard !isOurCancel else { return }
            onError(nsError.localizedDescription)
        }
    }
}
