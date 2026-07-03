import Foundation
import Network
import Observation

/// TCP reachability probe. iOS apps can't send raw ICMP, and a successful
/// connect to the SSH port is the honest "is it up" signal anyway. Compiled
/// into both the app and the widget extension.
enum ServerReachability {
    /// True if a TCP connection to host:port becomes ready within `timeout`.
    static func isReachable(host: String, port: Int, timeout: TimeInterval = 2) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        defer { connection.cancel() }

        return await withCheckedContinuation { continuation in
            let resumed = ResumeGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.resumeOnce { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    resumed.resumeOnce { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                resumed.resumeOnce { continuation.resume(returning: false) }
            }
        }
    }
}

/// Async gate on network availability: the reconnect loop pauses while the
/// radio is down and fires the moment the path returns.
enum NetworkPathWaiter {
    enum Result: Equatable {
        /// The path was satisfied when asked — no waiting happened.
        case alreadySatisfied
        /// The path was down and became satisfied within the timeout.
        case restored
        /// The path stayed unsatisfied for the whole timeout.
        case timedOut
    }

    static func awaitPath(timeout: TimeInterval) async -> Result {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return await withCheckedContinuation { continuation in
            let resumed = ResumeGuard()
            let sawUnsatisfied = LockedFlag()
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied {
                    let waited = sawUnsatisfied.isSet
                    resumed.resumeOnce {
                        continuation.resume(returning: waited ? .restored : .alreadySatisfied)
                    }
                } else {
                    sawUnsatisfied.set()
                }
            }
            monitor.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                resumed.resumeOnce { continuation.resume(returning: .timedOut) }
            }
        }
    }
}

/// Lock-protected boolean for cross-queue signaling.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Single-resume gate for continuation safety across racing callbacks.
private final class ResumeGuard: @unchecked Sendable {
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

/// In-app status cache: server ID → reachability, refreshed on demand.
@MainActor
@Observable
final class ReachabilityStore {
    enum Status {
        case unknown, checking, up, down
    }

    private(set) var statuses: [UUID: Status] = [:]

    /// Probes every server concurrently; UI updates as each result lands.
    func refresh(_ servers: [Server]) async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                statuses[server.id] = .checking
                group.addTask { @MainActor in
                    let up = await ServerReachability.isReachable(host: server.host, port: server.port)
                    self.statuses[server.id] = up ? .up : .down
                }
            }
        }
    }
}
