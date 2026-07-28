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

        let webView = try makeGuardedWebView(forwardedPort: forward.localPort)
        try await load(webView, port: forward.localPort, path: "/")

        // Vite rewrites index.html and serves main.js as a real ES module; if
        // the module graph did not come through the tunnel intact this stays
        // at the static placeholder.
        let marker = try await pollJavaScript(
            webView,
            script: "document.getElementById('marker') ? document.getElementById('marker').textContent : ''",
            until: { $0 == "MARKER_V1" }
        )
        XCTAssertEqual(marker, "MARKER_V1", "the Vite module graph did not execute through the tunnel")
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
    func testWebSocketUpgradeTraversesTheTunnelRaw() async throws {
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
            var s = new WebSocket('ws://127.0.0.1:\(port)/?token=' + m[1], 'vite-hmr');
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
    func testWebSocketUpgradeTraversesTheTunnel() async throws {
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
    func testListenerSnapshotFindsTheDevServerOnARealHost() async throws {
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
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        webView.navigationDelegate = navigationProbe
        return webView
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
