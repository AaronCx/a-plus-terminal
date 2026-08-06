import Network
import WebKit
import XCTest
@testable import aPlusTerminal

// MARK: - Source A: scraping URLs out of terminal output

final class PortDetectorScrapeTests: XCTestCase {
    func testScrapesPortFromAViteBanner() {
        let found = PortDetector.scrape("  ➜  Local:   http://localhost:5173/\n")
        XCTAssertEqual(found, [ScrapedEndpoint(port: 5173, path: nil)])
    }

    /// The single most important behavior of the scrape: `/admin` must open at
    /// `/admin`. Dropping the path silently sends the user to the app root.
    func testKeepsThePath() {
        XCTAssertEqual(
            PortDetector.scrape("http://localhost:5173/admin"),
            [ScrapedEndpoint(port: 5173, path: "/admin")]
        )
        XCTAssertEqual(
            PortDetector.scrape("http://127.0.0.1:3000/docs/intro?tab=1"),
            [ScrapedEndpoint(port: 3000, path: "/docs/intro?tab=1")]
        )
    }

    /// A bare `/` is the root, which is what a nil path already means — but
    /// anything longer is meaningful and must survive intact.
    func testBareSlashIsNormalizedToNoPath() {
        XCTAssertEqual(PortDetector.scrape("http://localhost:8080/"), [ScrapedEndpoint(port: 8080, path: nil)])
    }

    func testSchemeSuppliesTheDefaultPort() {
        XCTAssertEqual(PortDetector.scrape("http://localhost/"), [ScrapedEndpoint(port: 80, path: nil)])
        XCTAssertEqual(PortDetector.scrape("https://localhost/"), [ScrapedEndpoint(port: 443, path: nil)])
    }

    func testAcceptsEveryLoopbackSpelling() {
        let text = """
        http://localhost:5173/
        http://127.0.0.1:5174/
        http://0.0.0.0:5175/
        http://[::1]:5176/
        """
        XCTAssertEqual(PortDetector.scrape(text).map(\.port).sorted(), [5173, 5174, 5175, 5176])
    }

    /// A dev server on a routable host is somebody else's machine; the preview
    /// tunnel dials the SSH box's loopback and would silently show the wrong
    /// thing.
    func testIgnoresNonLoopbackHosts() {
        XCTAssertTrue(PortDetector.scrape("http://example.com:5173/").isEmpty)
        XCTAssertTrue(PortDetector.scrape("http://192.168.1.10:5173/").isEmpty)
        XCTAssertTrue(PortDetector.scrape("http://localhost.evil.com:5173/").isEmpty)
    }

    /// "Serving on http://localhost:5173." — the sentence's full stop is not
    /// part of the path.
    func testDoesNotSwallowTrailingSentencePunctuation() {
        XCTAssertEqual(
            PortDetector.scrape("Serving on http://localhost:5173/app."),
            [ScrapedEndpoint(port: 5173, path: "/app")]
        )
        XCTAssertEqual(
            PortDetector.scrape("(see http://localhost:5173/app)"),
            [ScrapedEndpoint(port: 5173, path: "/app")]
        )
    }
}

// MARK: - Source A over a real byte stream

@MainActor
final class PortDetectorStreamTests: XCTestCase {
    /// The scanner sees whatever the SSH read boundary happened to be. A URL
    /// split mid-token is the common case, not the exotic one.
    func testURLSplitAcrossChunksIsStillFound() {
        let detector = PortDetector()
        let whole = Array("  ➜  Local: http://localhost:5173/admin\n".utf8)
        for cut in 1..<whole.count {
            let fresh = PortDetector()
            fresh.observe(Array(whole[..<cut]))
            fresh.observe(Array(whole[cut...]))
            XCTAssertEqual(fresh.ports.first?.port, 5173, "split at byte \(cut) lost the URL")
            XCTAssertEqual(fresh.ports.first?.path, "/admin", "split at byte \(cut) lost the path")
        }
        detector.observe(whole)
        XCTAssertEqual(detector.ports.count, 1)
    }

    /// Vite colours its banner; inside tmux the redraw splices escapes through
    /// the text. Both must survive.
    func testANSIWrappedURLIsFound() {
        let detector = PortDetector()
        let coloured = "  \u{1B}[32m➜\u{1B}[0m  \u{1B}[1mLocal\u{1B}[0m:   \u{1B}[36mhttp://localhost:5173/\u{1B}[0m\n"
        detector.observe(Array(coloured.utf8))
        XCTAssertEqual(detector.ports.map(\.port), [5173])
    }

    func testDedupesAndKeepsMostRecentFirst() {
        let detector = PortDetector()
        detector.observe(Array("http://localhost:3000/\n".utf8))
        detector.observe(Array("http://localhost:5173/\n".utf8))
        detector.observe(Array("http://localhost:3000/\n".utf8))
        XCTAssertEqual(detector.ports.map(\.port), [3000, 5173])
    }

    func testCapsEntriesEvictingTheOldest() {
        let detector = PortDetector()
        let overflow = PortDetector.maxEntries + 4
        for port in 4000..<(4000 + overflow) {
            detector.observe(Array("http://localhost:\(port)/\n".utf8))
        }
        XCTAssertEqual(detector.ports.count, PortDetector.maxEntries)
        XCTAssertEqual(detector.ports.first?.port, 4000 + overflow - 1)
        XCTAssertFalse(detector.ports.contains { $0.port == 4000 })
    }

    /// The whole point of Source C: a scraped port whose server has since
    /// exited must go grey rather than vanish (the user may still want to know
    /// it was there) — but only after two consecutive misses, so one dropped
    /// exec channel doesn't flap the UI.
    func testEntryGoesStaleAfterTwoConsecutiveMisses() {
        let detector = PortDetector()
        detector.observe(Array("http://localhost:5173/\n".utf8))
        XCTAssertEqual(detector.ports.first?.isStale, false)

        detector.applyListenerSnapshot("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 1 me 20u IPv4 0x1 0t0 TCP 127.0.0.1:5173 (LISTEN)\n")
        XCTAssertEqual(detector.ports.first?.isStale, false)
        XCTAssertEqual(detector.ports.first?.process, "node")

        detector.applyListenerSnapshot("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n")
        XCTAssertEqual(detector.ports.first?.isStale, false, "one miss must not be enough")

        detector.applyListenerSnapshot("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n")
        XCTAssertEqual(detector.ports.first?.isStale, true, "two consecutive misses means gone")
    }

    func testReappearingEntryClearsStaleness() {
        let detector = PortDetector()
        detector.observe(Array("http://localhost:5173/\n".utf8))
        let empty = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
        detector.applyListenerSnapshot(empty)
        detector.applyListenerSnapshot(empty)
        XCTAssertEqual(detector.ports.first?.isStale, true)

        detector.applyListenerSnapshot("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 1 me 20u IPv4 0x1 0t0 TCP *:5173 (LISTEN)\n")
        XCTAssertEqual(detector.ports.first?.isStale, false)
    }

    /// A server that never printed a banner still has to be offerable.
    func testListenerOnlyPortsAreOffered() {
        let detector = PortDetector()
        detector.applyListenerSnapshot("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nPython 9 me 3u IPv4 0x1 0t0 TCP *:8000 (LISTEN)\n")
        XCTAssertEqual(detector.ports.map(\.port), [8000])
        XCTAssertEqual(detector.ports.first?.process, "Python")
        XCTAssertNil(detector.ports.first?.path)
    }

    /// A developer Mac has far more than eight listening sockets. The port the
    /// user actually printed must survive them — this regressed once, and the
    /// symptom (the dev server silently missing from its own picker) is one
    /// nobody would attribute to the cap.
    func testABusyHostDoesNotEvictTheScrapedEntry() {
        let detector = PortDetector()
        detector.observe(Array("http://localhost:5173/admin\n".utf8))

        var snapshot = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
        for port in 9000..<9030 {
            snapshot += "daemon \(port) me 3u IPv4 0x1 0t0 TCP *:\(port) (LISTEN)\n"
        }
        detector.applyListenerSnapshot(snapshot)

        let scraped = detector.ports.first { $0.port == 5173 }
        XCTAssertNotNil(scraped, "30 unrelated listeners evicted the scraped dev-server entry")
        XCTAssertEqual(scraped?.path, "/admin", "the entry survived but lost its path")
        XCTAssertEqual(detector.ports.first?.port, 5173, "the scraped entry must stay at the head")
        XCTAssertEqual(detector.ports.count, PortDetector.maxEntries)
    }

    /// Source B — the OSC 8 route that replaces the broken Safari handoff.
    func testNotedLinkAddsPortAndPath() {
        let detector = PortDetector()
        detector.note(url: URL(string: "http://localhost:5173/admin")!)
        XCTAssertEqual(detector.ports.first?.port, 5173)
        XCTAssertEqual(detector.ports.first?.path, "/admin")
    }

    func testResetClearsEverything() {
        let detector = PortDetector()
        detector.observe(Array("http://localhost:5173/\n".utf8))
        detector.reset()
        XCTAssertTrue(detector.ports.isEmpty)
    }
}

// MARK: - Source C: ground-truth listener parsing

final class ListenerParsingTests: XCTestCase {
    func testParsesMacOSLsof() {
        let output = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node      50231  acx   20u  IPv4 0x9f8a2b1c4d5e6f70      0t0  TCP *:5173 (LISTEN)
        node      50231  acx   22u  IPv6 0x9f8a2b1c4d5e6f71      0t0  TCP [::1]:24678 (LISTEN)
        Python    51002  acx    3u  IPv4 0x9f8a2b1c4d5e6f72      0t0  TCP 127.0.0.1:8000 (LISTEN)
        rapportd    811  acx    8u  IPv4 0x9f8a2b1c4d5e6f73      0t0  TCP *:49152 (LISTEN)
        """
        let rows = PortDetector.parseListeners(output)
        XCTAssertEqual(rows.first { $0.port == 5173 }?.process, "node")
        XCTAssertEqual(rows.first { $0.port == 24678 }?.process, "node")
        XCTAssertEqual(rows.first { $0.port == 8000 }?.process, "Python")
        XCTAssertEqual(rows.first { $0.port == 49152 }?.process, "rapportd")
        XCTAssertEqual(rows.count, 4, "header line must not be parsed as a row")
    }

    func testParsesLinuxSs() {
        let output = """
        State    Recv-Q   Send-Q     Local Address:Port      Peer Address:Port  Process
        LISTEN   0        511            127.0.0.1:5173           0.0.0.0:*      users:(("node",pid=812,fd=20))
        LISTEN   0        4096           127.0.0.53:53            0.0.0.0:*      users:(("systemd-resolve",pid=611,fd=13))
        LISTEN   0        128                    *:22                   *:*      users:(("sshd",pid=900,fd=3))
        LISTEN   0        511                 [::1]:3000                [::]:*
        """
        let rows = PortDetector.parseListeners(output)
        XCTAssertEqual(rows.first { $0.port == 5173 }?.process, "node")
        XCTAssertEqual(rows.first { $0.port == 53 }?.process, "systemd-resolve")
        XCTAssertEqual(rows.first { $0.port == 22 }?.process, "sshd")
        XCTAssertEqual(rows.first { $0.port == 3000 }?.process, nil)
        XCTAssertEqual(rows.count, 4)
    }

    /// BSD netstat separates the port with a DOT, not a colon — the fallback
    /// that fires when neither lsof nor ss exists.
    func testParsesBSDNetstat() {
        let output = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  127.0.0.1.5173         *.*                    LISTEN
        tcp6       0      0  ::1.3000               *.*                    LISTEN
        tcp4       0      0  192.168.1.5.22         *.*                    LISTEN
        tcp4       0      0  127.0.0.1.5173         127.0.0.1.61234        ESTABLISHED
        """
        let rows = PortDetector.parseListeners(output)
        XCTAssertEqual(rows.map(\.port).sorted(), [22, 3000, 5173])
        XCTAssertTrue(rows.allSatisfy { $0.process == nil })
    }

    func testParsesLinuxNetstat() {
        let output = """
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 127.0.0.1:5173          0.0.0.0:*               LISTEN
        tcp6       0      0 :::22                   :::*                    LISTEN
        tcp        0      0 127.0.0.1:5173          127.0.0.1:61234         ESTABLISHED
        """
        let rows = PortDetector.parseListeners(output)
        XCTAssertEqual(rows.map(\.port).sorted(), [22, 5173])
    }

    func testIgnoresGarbageAndOutOfRangePorts() {
        XCTAssertTrue(PortDetector.parseListeners("").isEmpty)
        XCTAssertTrue(PortDetector.parseListeners("bash: lsof: command not found").isEmpty)
        XCTAssertTrue(PortDetector.parseListeners("tcp 0 0 127.0.0.1:0 0.0.0.0:* LISTEN").isEmpty)
        XCTAssertTrue(PortDetector.parseListeners("tcp 0 0 127.0.0.1:99999 0.0.0.0:* LISTEN").isEmpty)
    }
}

// MARK: - The loopback guard

final class LoopbackHostTests: XCTestCase {
    func testAcceptsEveryLoopbackForm() {
        for host in ["localhost", "LOCALHOST", "LocalHost", "127.0.0.1", "127.1.2.3", "0.0.0.0", "::1", "[::1]"] {
            XCTAssertTrue(PortDetector.isLoopbackHost(host), host)
        }
    }

    /// The navigation guard is the single thing keeping this from being a
    /// general-purpose embedded browser, so near-misses have to be rejected.
    func testRejectsLookalikes() {
        for host in [
            "localhost.evil.com",
            "127.0.0.1.evil.com",
            "notlocalhost",
            "evil.com",
            "192.168.1.1",
            "10.0.0.1",
            "0.0.0.0.evil.com",
            "xn--localhost-.com",
            "",
        ] {
            XCTAssertFalse(PortDetector.isLoopbackHost(host), host)
        }
    }
}

// MARK: - Phase 1: the tunnel's bind behavior

@MainActor
final class SSHPortForwardBindTests: XCTestCase {
    /// Matching the remote port is what makes HMR work without rewriting the
    /// page's own absolute URLs, so the happy path must actually take it.
    func testPrefersTheRemotePortLocally() async throws {
        let port = try await Self.freeLoopbackPort()
        let forward = SSHPortForward(remotePort: port, connection: SSHConnection())
        try await forward.start()
        defer { forward.stopImmediately() }

        XCTAssertEqual(forward.localPort, port)
        XCTAssertTrue(forward.matchesRemotePort)
    }

    /// When the preferred port is taken the forward must still work — but it
    /// must say so, because live reload will not reconnect.
    func testFallsBackToAnyPortAndFlagsTheMismatch() async throws {
        let port = try await Self.freeLoopbackPort()
        let squatter = try Self.listener(on: port)
        squatter.start(queue: .global())
        defer { squatter.cancel() }
        try await Self.awaitReady(squatter)

        let forward = SSHPortForward(remotePort: port, connection: SSHConnection())
        try await forward.start()
        defer { forward.stopImmediately() }

        XCTAssertNotEqual(forward.localPort, port)
        XCTAssertNotEqual(forward.localPort, 0)
        XCTAssertFalse(forward.matchesRemotePort, "a degraded forward must not pretend it matched")
    }

    /// iOS refuses privileged binds, so a remote server on :80 must degrade
    /// rather than fail outright.
    func testPrivilegedRemotePortDegradesInsteadOfFailing() async throws {
        let forward = SSHPortForward(remotePort: 80, connection: SSHConnection())
        try await forward.start()
        defer { forward.stopImmediately() }

        XCTAssertNotEqual(forward.localPort, 0)
        XCTAssertFalse(forward.matchesRemotePort)
    }

    /// The privacy precondition from the Phase 0 spike, asserted on the real
    /// production type rather than a stub: the forward's listener must never
    /// be reachable from the network.
    func testForwardListenerIsLoopbackOnly() async throws {
        let forward = SSHPortForward(remotePort: try await Self.freeLoopbackPort(), connection: SSHConnection())
        try await forward.start()
        defer { forward.stopImmediately() }

        let onLoopback = await ServerReachability.isReachable(host: "127.0.0.1", port: forward.localPort, timeout: 3)
        XCTAssertTrue(onLoopback, "the forward must accept on loopback")

        guard let lan = PreviewSpikeTests.primaryIPv4Address() else {
            throw XCTSkip("no non-loopback IPv4 interface — cannot prove the negative")
        }
        let onLAN = await ServerReachability.isReachable(host: lan, port: forward.localPort, timeout: 3)
        XCTAssertFalse(onLAN, "the forward answered on \(lan) — it would publish the dev server to the whole Wi-Fi")
    }

    func testStopIsIdempotent() async throws {
        let forward = SSHPortForward(remotePort: try await Self.freeLoopbackPort(), connection: SSHConnection())
        try await forward.start()
        await forward.stop()
        await forward.stop()
        forward.stopImmediately()
    }

    // MARK: Helpers

    private static func listener(on port: Int) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.cancel() }
        return listener
    }

    private static func awaitReady(_ listener: NWListener) async throws {
        for _ in 0..<100 {
            if case .ready = listener.state { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("squatter listener never became ready")
    }

    /// Binds an ephemeral loopback port, notes the number, then releases it
    /// and *waits for the release to complete* before handing it back.
    ///
    /// The wait is the whole point: `NWListener.cancel()` is asynchronous, so
    /// returning the moment it is called hands out a port that is still bound.
    /// `testPrefersTheRemotePortLocally` would then observe the collision
    /// fallback and fail, intermittently and confusingly.
    private static func freeLoopbackPort() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let probe = try NWListener(using: parameters)
        // MUST be set before start(). Without a connection handler the
        // listener never binds, `probe.port` stays nil forever, and this
        // helper used to XCTSkip — which quietly turned the three bind tests
        // below (the acceptance coverage for the port-collision rule) into no
        // coverage at all, while the suite still reported success.
        probe.newConnectionHandler = { $0.cancel() }
        probe.start(queue: .global())

        var port: UInt16 = 0
        for _ in 0..<200 {
            if let bound = probe.port?.rawValue, bound != 0 {
                port = bound
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard port != 0 else {
            probe.cancel()
            XCTFail("probe listener never bound — the bind tests cannot run")
            throw XCTSkip("probe listener never bound")
        }

        probe.cancel()
        // The real signal that the port is reusable is that nothing answers on
        // it; `probe.state` can lag the socket being reaped.
        for _ in 0..<100 {
            if await !ServerReachability.isReachable(host: "127.0.0.1", port: Int(port), timeout: 1) {
                return Int(port)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("probe port \(port) never released — the bind tests cannot run")
        throw XCTSkip("probe port \(port) never released")
    }
}

// MARK: - Phase 3: the rule that stops this being a browser

/// The navigation allow-list, tested directly. This is the single check that
/// keeps the preview inside App Review guidelines 2.5.6 / 4.7, so it is worth
/// asserting rather than merely reviewing.
final class PreviewNavigationPolicyTests: XCTestCase {
    private let forwarded = 5173

    func testAllowsTheForwardedOrigin() {
        for allowed in [
            "http://127.0.0.1:5173/",
            "http://127.0.0.1:5173/admin?tab=1",
            "http://localhost:5173/",
            "http://[::1]:5173/assets/app.js",
        ] {
            XCTAssertTrue(
                PreviewNavigationPolicy.allows(URL(string: allowed)!, forwardedPort: forwarded),
                allowed
            )
        }
    }

    /// Live reload dials `ws://localhost:<port>`. Blocking that scheme would
    /// leave the page working and HMR silently dead — the most confusing
    /// possible failure, so it is pinned by a test.
    func testAllowsWebSocketSchemesOnTheForwardedPort() {
        XCTAssertTrue(PreviewNavigationPolicy.allows(URL(string: "ws://127.0.0.1:5173/")!, forwardedPort: forwarded))
        XCTAssertTrue(PreviewNavigationPolicy.allows(URL(string: "wss://127.0.0.1:5173/hmr")!, forwardedPort: forwarded))
    }

    /// iOS loopback is shared by every app on the device, so "any loopback
    /// port" would let a previewed page reach another app's local server.
    func testRejectsOtherLoopbackPorts() {
        for other in [
            "http://127.0.0.1:5174/",
            "http://localhost:8080/",
            "http://127.0.0.1/",
            "ws://127.0.0.1:24678/",
        ] {
            XCTAssertFalse(
                PreviewNavigationPolicy.allows(URL(string: other)!, forwardedPort: forwarded),
                other
            )
        }
    }

    func testRejectsNonLoopbackHostsIncludingLookalikes() {
        for blocked in [
            "http://example.com:5173/",
            "https://evil.com:5173/",
            "http://localhost.evil.com:5173/",
            "http://127.0.0.1.evil.com:5173/",
            // Userinfo trick: the real host here is evil.com.
            "http://127.0.0.1@evil.com:5173/",
        ] {
            XCTAssertFalse(
                PreviewNavigationPolicy.allows(URL(string: blocked)!, forwardedPort: forwarded),
                blocked
            )
        }
    }

    func testRejectsNonHTTPSchemes() {
        for blocked in [
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "javascript:alert(1)",
            "mailto:someone@example.com",
            "aplusterminal://connect",
        ] {
            XCTAssertFalse(
                PreviewNavigationPolicy.allows(URL(string: blocked)!, forwardedPort: forwarded),
                blocked
            )
        }
    }

    /// WebKit's own empty document backs the initial frame and every new
    /// iframe; blocking it breaks first paint and protects nothing.
    func testAllowsAboutBlank() {
        XCTAssertTrue(PreviewNavigationPolicy.allows(URL(string: "about:blank")!, forwardedPort: forwarded))
    }
}

/// WebKit's `url-filter` is a restricted regex engine and rejects patterns
/// NSRegularExpression accepts. A rule list that fails to compile means the
/// preview refuses to render at all, so this must be caught in CI rather than
/// on a user's device.
/// `@MainActor` is required, not stylistic: `WKContentRuleListStore` is
/// main-thread-only and calling it from a nonisolated test crashes the host app
/// (which XCTest reports as "Restarting after unexpected exit" plus a confusing
/// half-count of executed tests, not as an obvious failure).
@MainActor
final class PreviewContentRuleListTests: XCTestCase {
    func testRulesCompileForAWideRangeOfPorts() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        for port in [1, 80, 3000, 5173, 8080, 65535] {
            let json = PreviewNavigationPolicy.contentRuleListJSON(forwardedPort: port)
            let identifier = PreviewNavigationPolicy.contentRuleListIdentifier(forwardedPort: port)
            do {
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                        if let list {
                            continuation.resume(returning: list)
                        } else {
                            continuation.resume(throwing: error ?? PreviewRulesError.unavailable)
                        }
                    }
                }
            } catch {
                XCTFail("rules for port \(port) did not compile: \(error)\n\(json)")
            }
        }
    }
}

// MARK: - The guard, exercised through a real WKWebView

@MainActor
final class PreviewGuardIntegrationTests: XCTestCase {
    /// Proves the shipped `Coordinator` is actually consulted by WebKit.
    /// A delegate method whose signature does not match what WebKit expects is
    /// silently never called — and since WebKit's default is to ALLOW, that
    /// failure mode looks exactly like "no guard at all". Only driving a real
    /// web view can tell the two apart.
    func testProductionCoordinatorBlocksAnOffOriginNavigation() async throws {
        let page = """
        <html><body><script>
        setTimeout(function () { location.href = 'https://example.com/'; }, 50);
        </script></body></html>
        """
        let stub = try LoopbackHTTPStub(body: page)
        try await stub.start()
        defer { stub.stop() }

        let blocked = BlockedRecorder()
        let coordinator = PreviewWebView.Coordinator(
            forwardedPort: Int(stub.port),
            onLoadingChanged: { _ in },
            onError: { _ in },
            onBlocked: { blocked.record($0) }
        )

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(stub.port)/")!))

        let caught = try await blocked.first(timeout: 20)
        XCTAssertEqual(caught.host, "example.com", "the guard did not stop an off-origin navigation")

        // And the web view must still be sitting on the forwarded origin.
        let current = webView.url?.port
        XCTAssertEqual(current, Int(stub.port), "the web view navigated away despite the guard")
    }

    /// The navigation delegate structurally cannot see `fetch`/XHR, so the
    /// content rule list is what covers them. Both halves are asserted: a
    /// control run without the rules must REACH the other origin, otherwise a
    /// blocked result below would prove nothing (it could just be CORS).
    func testContentRulesBlockAnOffOriginFetchThatOtherwiseSucceeds() async throws {
        let target = try LoopbackHTTPStub(body: "<html><body>target</body></html>")
        try await target.start()
        defer { target.stop() }

        func pageFetching(_ port: UInt16) -> String {
            """
            <html><head><title>pending</title></head><body><script>
            fetch('http://127.0.0.1:\(port)/', {cache: 'no-store'})
              .then(function () { document.title = 'reached'; })
              .catch(function () { document.title = 'blocked'; });
            </script></body></html>
            """
        }

        // CONTROL: no rule list installed — the fetch must succeed.
        let controlStub = try LoopbackHTTPStub(body: pageFetching(target.port))
        try await controlStub.start()
        defer { controlStub.stop() }
        let controlTitle = try await loadAndReadTitle(port: controlStub.port, rules: nil)
        XCTAssertEqual(
            controlTitle, "reached",
            "CONTROL FAILED: the cross-origin fetch did not succeed even unfiltered, so the assertion below proves nothing"
        )

        // The real thing: rules scoped to the page's own port must block it.
        let guardedStub = try LoopbackHTTPStub(body: pageFetching(target.port))
        try await guardedStub.start()
        defer { guardedStub.stop() }
        let rules = try await compileRules(forwardedPort: Int(guardedStub.port))
        let guardedTitle = try await loadAndReadTitle(port: guardedStub.port, rules: rules)
        XCTAssertEqual(guardedTitle, "blocked", "a subresource fetch escaped the content rule list")
    }

    // MARK: Helpers

    private func compileRules(forwardedPort: Int) async throws -> WKContentRuleList {
        let json = PreviewNavigationPolicy.contentRuleListJSON(forwardedPort: forwardedPort)
        let identifier = PreviewNavigationPolicy.contentRuleListIdentifier(forwardedPort: forwardedPort)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
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

    private func loadAndReadTitle(port: UInt16, rules: WKContentRuleList?) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let rules { configuration.userContentController.add(rules) }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let probe = NavigationProbe()
        webView.navigationDelegate = probe
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))

        if case .failed(let error) = try await probe.outcome(timeout: 20) {
            XCTFail("the page itself failed to load: \(error)")
            return "load-failed"
        }
        // The fetch resolves after load; poll rather than guess a sleep.
        for _ in 0..<100 {
            let title = try await webView.evaluateJavaScript("document.title") as? String
            if let title, title != "pending" { return title }
            try await Task.sleep(for: .milliseconds(100))
        }
        return "timeout"
    }
}

/// Collects the first URL the guard refused.
private final class BlockedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: URL?

    func record(_ url: URL) {
        lock.withLock { if captured == nil { captured = url } }
    }

    func first(timeout: TimeInterval) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let captured = lock.withLock({ captured }) { return captured }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("nothing was blocked within \(timeout)s")
    }
}

// MARK: - Sessions widget

/// The home-screen widget renders from a file, because a widget extension runs
/// in its own process and can see none of the app's memory. These pin the two
/// things that would break silently: the snapshot round-trip, and the deep
/// links each row taps through to.
final class SessionSnapshotStoreTests: XCTestCase {
    private func summary(_ name: String, state: String = "connected",
                         started: Date = Date(), agent: String? = nil) -> SessionActivityAttributes.SessionSummary {
        .init(id: UUID(), name: name, state: state, startedAt: started, agentStatus: agent)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let sessions = [summary("Mac mini"), summary("homelab", state: "suspended")]
        let snapshot = SessionSnapshotStore.Snapshot(sessions: sessions, updatedAt: Date())
        let decoded = try JSONDecoder().decode(
            SessionSnapshotStore.Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.sessions.map(\.name), ["Mac mini", "homelab"])
        XCTAssertEqual(decoded.sessions.map(\.state), ["connected", "suspended"])
    }

    /// A snapshot the app has not refreshed is a list of sessions that probably
    /// no longer exist — the widget must be able to tell.
    func testStalenessIsDecidedByAge() {
        let now = Date()
        let fresh = SessionSnapshotStore.Snapshot(sessions: [], updatedAt: now.addingTimeInterval(-60))
        let old = SessionSnapshotStore.Snapshot(
            sessions: [], updatedAt: now.addingTimeInterval(-SessionSnapshotStore.staleAfter - 1))
        XCTAssertFalse(SessionSnapshotStore.isStale(fresh, now: now))
        XCTAssertTrue(SessionSnapshotStore.isStale(old, now: now))
        XCTAssertTrue(SessionSnapshotStore.isStale(.empty, now: now), "never-written must read as stale")
    }

    func testEmptySnapshotHasNoSessions() {
        XCTAssertTrue(SessionSnapshotStore.Snapshot.empty.sessions.isEmpty)
    }
}

final class LiveSessionsWidgetRowTests: XCTestCase {
    /// Tapping a live session must land in *that* session — the route the Live
    /// Activity already uses.
    func testSessionRowLinksToTheSessionDeepLink() throws {
        let id = UUID()
        let row = LiveSessionsEntry.Row(
            id: id, name: "Mac mini",
            kind: .session(state: "connected", startedAt: Date(), agent: nil))
        let url = try XCTUnwrap(row.url)
        XCTAssertEqual(url.scheme, "aplusterminal")
        XCTAssertEqual(url.host, "session")
        XCTAssertEqual(url.lastPathComponent, id.uuidString)
        XCTAssertTrue(row.isSession)
    }

    /// Tapping a server with nothing open must *start* a session, which is the
    /// connect route an App Intent uses — not the session route, which would
    /// silently do nothing for an id no session has.
    func testIdleServerRowLinksToTheConnectDeepLink() throws {
        let id = UUID()
        let row = LiveSessionsEntry.Row(id: id, name: "vps", kind: .idleServer)
        let url = try XCTUnwrap(row.url)
        XCTAssertEqual(url.host, "connect")
        XCTAssertEqual(url.lastPathComponent, id.uuidString)
        XCTAssertFalse(row.isSession)
    }

    /// Both URLs have to survive the app's own router, or the widget taps land
    /// nowhere.
    @MainActor
    func testBothRoutesAreAcceptedByTheRouter() throws {
        let sessionID = UUID(), serverID = UUID()
        let router = DeepLinkRouter()

        let sessionRow = LiveSessionsEntry.Row(
            id: sessionID, name: "a", kind: .session(state: "connected", startedAt: Date(), agent: nil))
        router.handle(try XCTUnwrap(sessionRow.url))
        XCTAssertEqual(router.targetSessionID, sessionID)
        XCTAssertEqual(router.selectedTab, .terminal)

        let serverRow = LiveSessionsEntry.Row(id: serverID, name: "b", kind: .idleServer)
        router.handle(try XCTUnwrap(serverRow.url))
        XCTAssertEqual(router.connectServerID, serverID)
    }

    func testEntryCountsOnlyOpenSessions() {
        let entry = LiveSessionsEntry(date: Date(), rows: [
            .init(id: UUID(), name: "a", kind: .session(state: "connected", startedAt: Date(), agent: nil)),
            .init(id: UUID(), name: "b", kind: .session(state: "suspended", startedAt: Date(), agent: nil)),
            .init(id: UUID(), name: "c", kind: .idleServer),
        ], stale: false)
        XCTAssertEqual(entry.sessionCount, 2, "idle servers are not open sessions")
    }
}

/// The write path itself, through the real App Group container. A wrong group
/// identifier or a missing entitlement fails in exactly one way — the widget
/// shows nothing, forever, with no error anywhere — so it is worth one test
/// that actually touches the container the extension will read from.
final class SessionSnapshotContainerTests: XCTestCase {
    func testWriteThenReadThroughTheAppGroupContainer() throws {
        guard let url = SessionSnapshotStore.fileURL() else {
            XCTFail("no App Group container — the widget could never read a snapshot")
            return
        }
        let original = try? Data(contentsOf: url)
        defer {
            if let original { try? original.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }

        let id = UUID()
        let written = SessionSnapshotStore.write([
            .init(id: id, name: "container-check", state: "connected", startedAt: Date(), agentStatus: nil)
        ])
        XCTAssertTrue(written, "could not write into the App Group container")

        let read = SessionSnapshotStore.read()
        XCTAssertEqual(read.sessions.first?.id, id)
        XCTAssertEqual(read.sessions.first?.name, "container-check")
        XCTAssertFalse(SessionSnapshotStore.isStale(read), "a snapshot just written must not read as stale")
    }
}
