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

    /// Resolves a Bonjour endpoint to a concrete host + port by opening a
    /// short-lived TCP connection and reading the remote endpoint it landed
    /// on. Cancelled immediately — no SSH handshake happens.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 5) async -> (host: String, port: Int)? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }
        return await withCheckedContinuation { continuation in
            let resumed = ResolveGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var resolved: (String, Int)?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        // Host renders like "192.168.1.20%en0" on some paths —
                        // the interface suffix isn't part of the address.
                        let raw = "\(host)"
                        let cleaned = raw.split(separator: "%").first.map(String.init) ?? raw
                        resolved = (cleaned, Int(port.rawValue))
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
