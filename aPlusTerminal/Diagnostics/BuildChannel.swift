// Beta-only (`MESHYY`): its one consumer is the scroll trace default, and the
// trace exists to debug meshyy, so App Store candidates compile all of it out.
#if MESHYY
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
    /// TestFlight installs carry a sandbox receipt, App Store installs a
    /// production one (the URL names the environment whether or not the file
    /// exists yet). `appStoreReceiptURL` is deprecated since iOS 18; it is
    /// still the only synchronous signal.
    ///
    /// App Review installs also report sandbox, so reviewers get the trace on
    /// by default — on-device only, like everywhere else.
    static var synchronousHint: BuildChannel {
        #if DEBUG
        return .debug
        #else
        return channel(forReceiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent)
        #endif
    }

    static func channel(forReceiptName name: String?) -> BuildChannel {
        switch name {
        case "sandboxReceipt": return .testFlight
        case "receipt": return .appStore
        default: return .unknown
        }
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
#endif
