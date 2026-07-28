import Network
import WebKit
import XCTest
@testable import aPlusTerminal

/// Phase 0 spike for the in-app localhost preview (preview brief §Phase 0).
///
/// Two unknowns gate the design and neither is answerable by reading docs:
///
/// **0a — does ATS block `http://127.0.0.1:PORT` inside a `WKWebView`?** If a
/// plain loopback page loads with the shipped Info.plist untouched, the feature
/// needs no App Transport Security exception at all, which is the difference
/// between "no review conversation" and "justify a broad
/// `NSAllowsArbitraryLoadsInWebContent` in the review notes".
///
/// **0b — can `NWListener` be pinned to loopback only?** A listener that lands
/// on `0.0.0.0` would republish the user's dev server to every device on the
/// Wi-Fi. That contradicts the app's whole privacy posture, so loopback-only
/// binding is a hard precondition, not a nice-to-have.
final class PreviewSpikeTests: XCTestCase {
    // MARK: - 0b: loopback-only binding

    func testListenerPinnedToLoopbackIsReachableOnLoopback() async throws {
        let stub = try LoopbackHTTPStub(body: "<html><head><title>spike</title></head><body>ok</body></html>")
        try await stub.start()
        defer { stub.stop() }

        let up = await ServerReachability.isReachable(host: "127.0.0.1", port: Int(stub.port), timeout: 3)
        XCTAssertTrue(up, "a loopback-pinned listener must accept connections on 127.0.0.1")
    }

    /// CONTROL for the test below. A negative result is only evidence of
    /// loopback pinning if the *same* probe reaches a wildcard-bound listener
    /// on the same address — otherwise a firewall (or a sandbox rule) would
    /// make the real test pass for entirely the wrong reason.
    func testControlWildcardListenerIsReachableOnTheLANAddress() async throws {
        let stub = try LoopbackHTTPStub(body: "<html><body>ok</body></html>", bind: .wildcard)
        try await stub.start()
        defer { stub.stop() }

        guard let lan = Self.primaryIPv4Address() else {
            throw XCTSkip("no non-loopback IPv4 interface — cannot run the control")
        }
        let reachable = await ServerReachability.isReachable(host: lan, port: Int(stub.port), timeout: 3)
        XCTAssertTrue(
            reachable,
            "CONTROL FAILED: even a wildcard bind is unreachable on \(lan) — the loopback-only assertion below proves nothing"
        )
    }

    func testListenerPinnedToLoopbackIsNotReachableOnTheLANAddress() async throws {
        let stub = try LoopbackHTTPStub(body: "<html><body>ok</body></html>", bind: .loopback)
        try await stub.start()
        defer { stub.stop() }

        guard let lan = Self.primaryIPv4Address() else {
            throw XCTSkip("no non-loopback IPv4 interface — cannot prove the negative")
        }
        // Same port, same host machine, different local address: a wildcard
        // (0.0.0.0) bind would answer here — the control above proves the probe
        // can see one. A loopback-pinned one must not.
        let reachable = await ServerReachability.isReachable(host: lan, port: Int(stub.port), timeout: 3)
        XCTAssertFalse(reachable, "listener answered on \(lan):\(stub.port) — it is NOT loopback-only")
    }

    // MARK: - 0a: ATS

    @MainActor
    func testWKWebViewLoadsPlainHTTPFromLoopbackWithoutATSException() async throws {
        let stub = try LoopbackHTTPStub(body: "<html><head><title>spike-ok</title></head><body>hello</body></html>")
        try await stub.start()
        defer { stub.stop() }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let probe = NavigationProbe()
        webView.navigationDelegate = probe

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(stub.port)/"))
        webView.load(URLRequest(url: url))

        let outcome = try await probe.outcome(timeout: 20)
        switch outcome {
        case .finished:
            let title = try await webView.evaluateJavaScript("document.title") as? String
            XCTAssertEqual(title, "spike-ok", "page loaded but did not render the served document")
        case .failed(let error):
            XCTFail("ATS or transport blocked a loopback HTTP load: \(error)")
        }
    }

    // MARK: - Helpers

    /// First non-loopback IPv4 address on this host (en0 preferred).
    static func primaryIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.isEmpty, !address.hasPrefix("169.254.") else { continue }
            if String(cString: pointer.pointee.ifa_name) == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }
}

/// Collects the first navigation outcome so an async test can await it.
final class NavigationProbe: NSObject, WKNavigationDelegate {
    enum Outcome {
        case finished
        case failed(Error)
    }

    private let lock = NSLock()
    private var settled: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.finished)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(.failed(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settle(.failed(error))
    }

    private func settle(_ outcome: Outcome) {
        let pending: [CheckedContinuation<Outcome, Never>] = lock.withLock {
            guard settled == nil else { return [] }
            settled = outcome
            let waiting = waiters
            waiters = []
            return waiting
        }
        for continuation in pending { continuation.resume(returning: outcome) }
    }

    func outcome(timeout: TimeInterval) async throws -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let settled = lock.withLock({ settled }) { return settled }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("navigation never settled within \(timeout)s")
    }
}

/// Minimal HTTP/1.1 responder bound to loopback only, for the spike.
/// Shared with PreviewTests — see PreviewNavigationPolicyTests.
final class LoopbackHTTPStub: @unchecked Sendable {
    private let listener: NWListener
    private let body: String
    private let queue = DispatchQueue(label: "preview.spike.stub")
    private(set) var port: UInt16 = 0

    enum Bind {
        /// The shipping behavior under test: pinned to 127.0.0.1.
        case loopback
        /// Control only — the default wildcard bind, reachable from the LAN.
        case wildcard
    }

    init(body: String, bind: Bind = .loopback) throws {
        self.body = body
        let parameters = NWParameters.tcp
        if case .loopback = bind {
            // The whole point of 0b: ask the stack for a loopback-only bind.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let bound = listener.port?.rawValue, bound != 0 {
                port = bound
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("listener never bound")
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            guard let self else { return }
            let payload = Data(self.body.utf8)
            // Permissive CORS on purpose: the content-rule-list test fetches
            // one stub from another, and without this a blocked result would
            // be attributable to CORS rather than to the rule list under test.
            let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Access-Control-Allow-Origin: *\r
            Content-Length: \(payload.count)\r
            Connection: close\r
            \r

            """
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
