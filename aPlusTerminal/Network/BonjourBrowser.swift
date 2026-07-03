import Foundation
import Network
import Observation

/// Browses `_ssh._tcp` on the local network. Results resolve to host:port
/// lazily, when the user picks one — resolution needs a brief connection.
@MainActor
@Observable
final class BonjourBrowser {
    struct DiscoveredService: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let endpoint: NWEndpoint

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    private(set) var services: [DiscoveredService] = []
    private(set) var isBrowsing = false

    private var browser: NWBrowser?

    func start() {
        stop()
        isBrowsing = true
        let browser = NWBrowser(
            for: .bonjour(type: "_ssh._tcp", domain: nil),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            let found = results.compactMap { result -> DiscoveredService? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                // One service advertised on several interfaces appears multiple
                // times — keep the first occurrence per name.
                guard seen.insert(name).inserted else { return nil }
                return DiscoveredService(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            // Already on the main queue (browser.start(queue: .main)), so assign
            // directly — an extra Task hop only adds latency and a reorder window.
            MainActor.assumeIsolated { self?.services = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    /// Resolves a Bonjour endpoint to a connectable host + port.
    ///
    /// **Primary path:** resolve the service's advertised mDNS hostname
    /// ("mac-mini.local") via NetService and return that. A hostname is
    /// stable across relaunches and network changes, and getaddrinfo
    /// re-resolves it to a correctly-scoped address on every connect —
    /// link-local IPv6 included.
    /// **Fallback:** the short-lived-TCP trick below, now preserving the
    /// IPv6 interface zone.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 5) async -> (host: String, port: Int)? {
        if case .service(let name, let type, let domain, _) = endpoint,
           let byHostname = await resolveHostname(name: name, type: type, domain: domain, timeout: timeout) {
            return byHostname
        }
        return await resolveConcreteAddress(endpoint, timeout: timeout)
    }

    /// Resolves the advertised mDNS hostname for a discovered service.
    /// NetService needs a live run loop: scheduled on `.main`, callbacks fire
    /// there, and the continuation resumes exactly once from that context.
    @MainActor
    private static func resolveHostname(name: String, type: String, domain: String, timeout: TimeInterval) async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let service = NetService(domain: domain.isEmpty ? "local." : domain, type: type, name: name)
            let delegate = HostnameResolveDelegate(service: service) { result in
                continuation.resume(returning: result)
            }
            delegate.start(timeout: timeout)
        }
    }

    /// mDNS hostnames arrive fully qualified ("mac-mini.local.") — trim the
    /// trailing root dot before storing or displaying.
    nonisolated static func normalizedHostname(_ raw: String) -> String {
        raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    }

    /// IPv4 addresses can carry a spurious "%interface" suffix that is not
    /// part of the address — strip it. IPv6 **keeps** its zone: a link-local
    /// (fe80::…) address is unroutable without "%en0", and stripping it is
    /// exactly what broke discovered-server connections.
    nonisolated static func sanitizedHost(_ raw: String) -> String {
        guard let percent = raw.firstIndex(of: "%") else { return raw }
        if raw.contains(":") { return raw }  // ":" ⇒ IPv6 ⇒ zone is meaningful
        return String(raw[..<percent])
    }

    /// Fallback: resolve to a concrete host + port by opening a short-lived
    /// TCP connection and reading the remote endpoint it landed on. Cancelled
    /// immediately — no SSH handshake happens.
    nonisolated static func resolveConcreteAddress(_ endpoint: NWEndpoint, timeout: TimeInterval = 5) async -> (host: String, port: Int)? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }
        return await withCheckedContinuation { continuation in
            let resumed = ResolveGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: (String, Int)?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        let raw = "\(host)"
                        resolved = (sanitizedHost(raw), Int(port.rawValue))
                    }
                    resumed.resumeOnce { continuation.resume(returning: resolved) }
                case .failed, .cancelled:
                    resumed.resumeOnce { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                resumed.resumeOnce { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Resolves one NetService to its advertised hostname, exactly once.
/// Main-run-loop-confined by construction; retains itself (and the service)
/// until resolution finishes, since NetService holds its delegate weakly.
private final class HostnameResolveDelegate: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var completion: (((host: String, port: Int)?) -> Void)?
    private var selfRetain: HostnameResolveDelegate?

    init(service: NetService, completion: @escaping (((host: String, port: Int)?) -> Void)) {
        self.service = service
        self.completion = completion
        super.init()
        self.selfRetain = self
        service.delegate = self
    }

    func start(timeout: TimeInterval) {
        service?.schedule(in: .main, forMode: .common)
        service?.resolve(withTimeout: timeout)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName, sender.port > 0 else { return finish(nil) }
        finish((BonjourBrowser.normalizedHostname(hostName), sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }

    func netServiceDidStop(_ sender: NetService) {
        finish(nil)  // covers timeout paths that stop without an error dict
    }

    private func finish(_ result: (host: String, port: Int)?) {
        guard let completion else { return }
        self.completion = nil
        service?.delegate = nil
        service?.stop()
        service?.remove(from: .main, forMode: .common)
        service = nil
        completion(result)
        selfRetain = nil
    }
}

private final class ResolveGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
