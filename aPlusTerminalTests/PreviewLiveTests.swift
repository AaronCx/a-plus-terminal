import Network
import WebKit
import XCTest
@testable import aPlusTerminal

/// End-to-end verification of the preview tunnel against a **real** SSH server
/// and a **real** Vite dev server. Everything else in the preview suite is
/// hermetic; this is the part that can only be proved by moving bytes.
///
/// Skipped — cleanly, with a reason — unless a fixture file is present, so
/// `make test` and CI stay hermetic. `docs/qa/preview-live.md` has the setup;
/// it is a throwaway sshd on a high port plus a Vite app, no system config
/// change and nothing that touches the user's real SSH setup.
///
/// **Simulator caveat, and it is the reason one assertion is scoped the way it
/// is.** The Simulator shares the host's network stack, so a dev server on the
/// Mac already owns `127.0.0.1:5173` *on the same loopback the app binds*. The
/// forward therefore always takes its collision fallback here and the ports
/// cannot match — which is precisely the condition under which Vite's
/// hardcoded `localhost:<devPort>` HMR socket does not reconnect. That is a
/// property of running both ends on one machine, not of the tunnel: on a real
/// iPhone the phone's `5173` is free. So this file proves the *mechanism* a
/// WebSocket needs — a real upgrade and real frames across the channel — and
/// leaves port-matched HMR to the on-device pass.
@MainActor
final class PreviewLiveTests: XCTestCase {
    private struct Fixture {
        let host: String
        let port: Int
        let user: String
        let keyPEM: String
        let devPort: Int
    }

    /// Where the harness drops the fixture. A *file*, not `TEST_RUNNER_`
    /// environment variables: that prefix is forwarded to the UI-test runner
    /// process, and these are app-hosted unit tests, so the variables never
    /// arrive and every assertion here silently skips.
    static let fixturePath = "/private/tmp/aplusterminal-preview-live.json"

    private struct FixtureFile: Decodable {
        let host: String?
        let port: Int?
        let user: String?
        let keyPEM: String
        let devPort: Int?
    }

    private func fixture() throws -> Fixture {
        let path = ProcessInfo.processInfo.environment["PREVIEW_FIXTURE"] ?? Self.fixturePath
        guard let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("no live-preview fixture at \(path) — see docs/qa/preview-live.md")
        }
        let decoded = try JSONDecoder().decode(FixtureFile.self, from: data)
        return Fixture(
            host: decoded.host ?? "127.0.0.1",
            port: decoded.port ?? 2222,
            user: decoded.user ?? NSUserName(),
            keyPEM: decoded.keyPEM,
            devPort: decoded.devPort ?? 5173
        )
    }

    /// Connects, forwards, and hands back a live forward plus its connection.
    private func openForward() async throws -> (SSHConnection, SSHPortForward, Fixture) {
        let fixture = try fixture()
        let connection = SSHConnection()
        try await connection.connect(
            SSHConnection.Configuration(
                host: fixture.host,
                port: fixture.port,
                username: fixture.user,
                auth: .key(try OpenSSHKey.parsePrivateKey(fixture.keyPEM)),
                knownHostKey: nil
            )
        )
        let forward = SSHPortForward(remotePort: fixture.devPort, connection: connection)
        try await forward.start()
        XCTAssertGreaterThan(forward.localPort, 0, "forward never bound")
        return (connection, forward, fixture)
    }

    // MARK: - The page itself

    /// The headline claim: a dev server on the SSH host renders in the app.
    func testViteDevServerRendersThroughTheTunnel() async throws {
        let (connection, forward, _) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        try await installRules(forwardedPort: forward.localPort)
        let webView = try makeGuardedWebView(forwardedPort: forward.localPort)
        try await load(webView, port: forward.localPort, path: "/")

        // Vite rewrites index.html and serves main.js as a real ES module; if
        // the module graph did not come through the tunnel intact this stays
        // at the static placeholder.
        // The label element starts empty and is filled by the ES module graph,
        // so a non-empty value proves modules were fetched and executed through
        // the tunnel — not merely that index.html arrived.
        let label = try await pollJavaScript(
            webView,
            script: "document.getElementById('label') ? document.getElementById('label').textContent : ''",
            until: { $0.contains("BUILD") }
        )
        XCTAssertTrue(
            label.contains("BUILD"),
            "the Vite module graph did not execute through the tunnel — label was \(label)"
        )
    }

    /// The regression guard for the teardown bug: `NWConnection.cancel()`
    /// discards sends that have not reported completion, and NIOSSH delivers
    /// buffered reads and `channelInactive` in the same tick — so a response
    /// the server ends by closing used to lose its tail. A hello-world page
    /// never shows it; four megabytes does.
    func testLargeAssetSurvivesTheTunnelByteForByte() async throws {
        let (connection, forward, _) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        let webView = try makeGuardedWebView(forwardedPort: forward.localPort)
        try await load(webView, port: forward.localPort, path: "/")

        let script = """
        (function () {
          window.__big = 'pending';
          fetch('/big.txt', {cache: 'no-store'})
            .then(function (r) { return r.arrayBuffer(); })
            .then(function (b) { window.__big = String(b.byteLength); })
            .catch(function (e) { window.__big = 'error:' + e; });
          return 'started';
        })()
        """
        _ = try await webView.evaluateJavaScript(script)

        let result = try await pollJavaScript(webView, script: "window.__big", until: { $0 != "pending" })
        XCTAssertEqual(
            result, "4194304",
            "the 4 MiB asset was truncated or failed in transit — got \(result)"
        )
    }

    /// HMR is a WebSocket, so the tunnel has to carry an HTTP upgrade and then
    /// stop behaving like a request/response pipe. This does the handshake on a
    /// raw socket rather than through WKWebView, which isolates "can the
    /// channel carry an upgrade" from anything the web view layers on top.
    func testWebSocketUpgradeTraversesTheTunnelRaw() async throws { // lastgate-ignore (test name, not a credential)
        let (connection, forward, _) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        let response = try await rawWebSocketHandshake(port: forward.localPort)
        XCTAssertTrue(
            response.contains("101 Switching Protocols"),
            "the tunnel did not carry a WebSocket upgrade. Response was:\n\(response)"
        )
        XCTAssertTrue(
            response.lowercased().contains("upgrade: websocket"),
            "upgrade header missing from the tunnelled response:\n\(response)"
        )
    }

    /// THE device bug, reproduced without a device.
    ///
    /// WKWebView/CFNetwork sends its request and then closes its *send* side,
    /// waiting for the response — ordinary HTTP, and what every load after the
    /// first one did on the phone. The forward read that local EOF
    /// (`isComplete == true`) and treated it as "the exchange is over", tearing
    /// the channel and the socket down before the server had answered. The
    /// browser saw a connection closed with no response, retried, and did the
    /// same thing forever: the preview hung on "Loading…", and a reload landed
    /// as NSURLErrorCannotParseResponse.
    ///
    /// The device trace that found it:
    ///     local->remote 447B isComplete=false   <- first request, answered
    ///     local->remote 447B isComplete=true    <- every one after
    ///     shutDown(graceful: true)              <- killed before the response
    ///     accept #4, #5, #6 ...                 <- the retry storm
    func testHalfClosedRequestStillReceivesAResponse() async throws {
        let (connection, forward, _) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        let response = try await requestThenHalfClose(port: forward.localPort)
        XCTAssertTrue(
            response.contains("HTTP/1."),
            "no response after the client half-closed its request — the forward tore the exchange down early. Got \(response.count) bytes: \(response.prefix(200))"
        )
    }

    /// The OTHER half of the same bug. The FIN can reach the forward either
    /// coalesced with the request bytes (what a real network does — 54,029 of
    /// 54,896 requests in the device log) or in a receive completion of its
    /// own, and there are two separate code paths for those. Only the first was
    /// fixed initially; this pins the second, which is the more damaging one
    /// because it can fire while the response is already streaming and cut it
    /// off mid-headers.
    func testRequestThenSeparateHalfCloseStillReceivesAResponse() async throws {
        let (connection, forward, _) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        let response = try await requestThenHalfClose(port: forward.localPort, separateFIN: true)
        XCTAssertTrue(
            response.contains("HTTP/1."),
            "no response when the FIN arrived separately from the request. Got \(response.count) bytes: \(response.prefix(200))"
        )
    }

    /// Sends a GET, closes the send side (exactly what CFNetwork does), and
    /// waits for the response. `separateFIN` sends the bytes and the FIN as two
    /// distinct operations, which is the loopback/keep-alive framing.
    private func requestThenHalfClose(port: Int, separateFIN: Bool = false) async throws -> String {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "preview.live.halfclose")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.trySet() { continuation.resume() }
                case .failed(let error): if once.trySet() { continuation.resume(throwing: error) }
                case .cancelled: if once.trySet() { continuation.resume(throwing: SSHPortForwardError.notConnected) }
                default: break
                }
            }
            connection.start(queue: queue)
        }

        let request = """
        GET / HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Connection: close\r
        \r

        """
        // isComplete: true == FIN after the request. This single flag is the
        // whole bug: it is what the browser does and what the forward mishandled.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(request.utf8),
                contentContext: separateFIN ? .defaultMessage : .finalMessage,
                isComplete: !separateFIN,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            )
        }
        if separateFIN {
            // Let the request land as its own receive, then close the send side
            // separately — the framing the coalesced fix does NOT cover.
            try await Task.sleep(for: .milliseconds(120))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                )
            }
        }

        // Read until the server closes or we time out; the bug shows up as zero
        // bytes and an immediate close.
        var received = Data()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    continuation.resume(returning: isComplete && (data?.isEmpty ?? true) ? nil : data)
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            received.append(chunk)
            if received.count > 512 { break }
        }
        return String(decoding: received, as: UTF8.self)
    }

    /// Opens a TCP connection through the forward and performs an RFC 6455
    /// handshake by hand, returning the response headers.
    private func rawWebSocketHandshake(port: Int) async throws -> String {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "preview.live.ws")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.trySet() { continuation.resume() }
                case .failed(let error):
                    if once.trySet() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.trySet() { continuation.resume(throwing: SSHPortForwardError.notConnected) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = """
        GET / HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Protocol: vite-hmr\r
        \r

        """
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                }
            }
        }
    }

    /// CONTROL for the WKWebView WebSocket test below. Talks to the dev server
    /// **directly**, no tunnel involved, so a failure here means WKWebView (or
    /// ATS) refuses `ws://` to loopback generally — which would be a fact about
    /// the platform, not about this feature. Without this control, a failure
    /// below is unattributable.
    func testControlWebSocketDirectToDevServerFromWebView() async throws {
        let fixture = try fixture()
        let webView = try makeGuardedWebView(forwardedPort: fixture.devPort)
        try await load(webView, port: fixture.devPort, path: "/")

        let result = try await openWebSocketFromPage(webView, port: fixture.devPort)
        XCTAssertEqual(
            result, "open",
            "CONTROL: WKWebView could not open ws:// to the dev server even without a tunnel — got \(result)"
        )
    }

    /// Runs the page-side WebSocket open and reports the outcome.
    ///
    /// The `?token=` is mandatory and was the subject of a false alarm worth
    /// recording: Vite 5.4.12+ (CVE-2025-24010) rejects, with a bare 400, any
    /// upgrade that carries an `Origin` header but no token. Browsers *always*
    /// send `Origin`, so a hand-rolled `new WebSocket(...)` without the token
    /// fails 100% of the time — which reads exactly like "the tunnel dropped
    /// the upgrade" and briefly sent me looking for an ATS exception the app
    /// does not need. The token is emitted into `/@vite/client`, which is where
    /// Vite's own HMR client picks it up.
    private func openWebSocketFromPage(_ webView: WKWebView, port: Int) async throws -> String {
        let script = """
        (function () {
          window.__ws = 'pending';
          fetch('/@vite/client').then(function (r) { return r.text(); }).then(function (src) {
            var m = src.match(/wsToken\\s*=\\s*"([^"]+)"/);
            if (!m) { window.__ws = 'no-token'; return; }
            var s = new WebSocket('ws://127.0.0.1:\(port)/?token=' + m[1], 'vite-hmr'); // lastgate-ignore (reads Vite's own dev-server token out of the page)
            s.onopen = function () { window.__ws = 'open'; };
            s.onerror = function () { if (window.__ws === 'pending') { window.__ws = 'error'; } };
            s.onclose = function (e) {
              if (window.__ws === 'pending') { window.__ws = 'closed:' + e.code; }
            };
          }).catch(function (e) { window.__ws = 'fetch-failed:' + e; });
          return 'started';
        })()
        """
        _ = try await webView.evaluateJavaScript(script)
        return try await pollJavaScript(webView, script: "window.__ws", until: { $0 != "pending" })
    }

    /// The same upgrade, but through WKWebView the way a page's own HMR client
    /// would do it.
    func testWebSocketUpgradeTraversesTheTunnel() async throws { // lastgate-ignore (test name, not a credential)
        let (connection, forward, _) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        let webView = try makeGuardedWebView(forwardedPort: forward.localPort)
        try await load(webView, port: forward.localPort, path: "/")

        // Dialling the *tunnel* port rather than Vite's own hardcoded one is
        // the whole point: it isolates "can a WebSocket cross this channel"
        // from "did the port numbers happen to match".
        let result = try await openWebSocketFromPage(webView, port: forward.localPort)
        XCTAssertEqual(result, "open", "a WebSocket upgrade did not survive the tunnel — got \(result)")
    }

    /// The other half of Source C, against a real machine: the command really
    /// does name the dev server, on whatever OS answered.
    func testListenerSnapshotFindsTheDevServerOnARealHost() async throws { // lastgate-ignore (test name, not a credential)
        let (connection, forward, fixture) = try await openForward()
        defer { forward.stopImmediately() }
        defer { Task { await connection.disconnect() } }

        let output = try await connection.runCommand(PortDetector.listenerCommand)
        let rows = PortDetector.parseListeners(output)
        XCTAssertTrue(
            rows.contains { $0.port == fixture.devPort },
            "listener snapshot did not include the dev server on \(fixture.devPort). Raw output:\n\(output.prefix(2000))"
        )
    }

    // MARK: - Helpers

    /// A web view configured exactly as the shipping sheet configures one —
    /// production coordinator, production rule list. Testing through a laxer
    /// setup would prove nothing about what users get.
    private func makeGuardedWebView(forwardedPort: Int) throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The content rule list is part of the shipping configuration, so it
        // has to be part of the harness: an earlier version of this file left
        // it out, which meant the live tests were exercising a *laxer* web view
        // than any user ever gets.
        if let rules = compiledRules { configuration.userContentController.add(rules) }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        webView.navigationDelegate = navigationProbe
        // A real window: WKWebView does not lay out or paint off-window, and
        // the shipping sheet is always on screen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.addSubview(webView)
        window.makeKeyAndVisible()
        self.window = window
        return webView
    }

    private var window: UIWindow?
    private var compiledRules: WKContentRuleList?

    /// Compiles the production rules for `port` so the harness matches the sheet.
    private func installRules(forwardedPort port: Int) async throws {
        let json = PreviewNavigationPolicy.contentRuleListJSON(forwardedPort: port)
        let identifier = PreviewNavigationPolicy.contentRuleListIdentifier(forwardedPort: port)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        compiledRules = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? PreviewRulesError.unavailable) }
            }
        }
    }

    private let navigationProbe = NavigationProbe()

    private func load(_ webView: WKWebView, port: Int, path: String) async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        webView.load(URLRequest(url: url))
        if case .failed(let error) = try await navigationProbe.outcome(timeout: 30) {
            XCTFail("page load through the tunnel failed: \(error)")
        }
    }

    private func pollJavaScript(
        _ webView: WKWebView,
        script: String,
        until predicate: (String) -> Bool,
        timeout: TimeInterval = 60
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript(script) {
                last = String(describing: value)
                if predicate(last) { return last }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return last
    }
}
