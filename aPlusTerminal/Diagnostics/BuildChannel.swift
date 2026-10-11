import Foundation
import StoreKit

/// Where this binary came from. Decides on-device diagnostics defaults only —
/// never behaviour a user would notice.
enum BuildChannel: String, Codable, Sendable {
    /// A DEBUG build, or a Release build installed straight from Xcode.
    case debug
    case testFlight
    case appStore
    /// The channel could not be determined (no AppTransaction yet, offline
    /// first launch). Leaves whatever the last launch cached in place.
    case unknown

    /// Scroll trace default: on wherever the people running the build are
    /// testing it, off in the store. nil = no opinion (keep the cache).
    var scrollTraceDefault: Bool? {
        switch self {
        case .debug, .testFlight: return true
        case .appStore: return false
        case .unknown: return nil
        }
    }

    /// Synchronous, offline guess, good enough until `resolve()` answers.
    /// TestFlight installs carry a sandbox receipt. `appStoreReceiptURL` is
    /// deprecated since iOS 18; it is still the only synchronous signal.
    static var synchronousHint: BuildChannel {
        #if DEBUG
        return .debug
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return .testFlight
        }
        return .unknown
        #endif
    }

    /// The authoritative answer, from StoreKit's signed app transaction.
    /// DEBUG builds never ask: the answer is known, and StoreKit in a
    /// simulator test host can stall.
    static func resolve() async -> BuildChannel {
        #if DEBUG
        return .debug
        #else
        guard let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result
        else { return synchronousHint }
        switch transaction.environment {
        case .sandbox: return .testFlight
        case .xcode: return .debug
        case .production: return .appStore
        default: return .unknown
        }
        #endif
    }
}
