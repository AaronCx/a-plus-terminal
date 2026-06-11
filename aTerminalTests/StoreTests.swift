import XCTest
@testable import aTerminal

/// Product IDs are App Store Connect contracts — lock them down so a refactor
/// can't silently break live purchases.
final class StoreProductsTests: XCTestCase {
    func testProductIdentifiersAreStable() {
        XCTAssertEqual(StoreProducts.tips, [
            "com.aaroncx.relay.tip.small",
            "com.aaroncx.relay.tip.medium",
            "com.aaroncx.relay.tip.large",
        ])
        XCTAssertEqual(StoreProducts.subscriptions, [
            "com.aaroncx.relay.supporter.monthly",
            "com.aaroncx.relay.supporter.yearly",
        ])
        XCTAssertEqual(StoreProducts.all.count, 5)
    }

    // NOTE: a TipStore.load() happy-path test via StoreKitTest.SKTestSession
    // was tried (both configurationFileNamed: and contentsOf:, clean sim) —
    // the session initializes but Product.products(for:) returns [] on this
    // Xcode/simulator combo. Scheme-level storeKitConfiguration also never
    // applies to test actions. Don't re-add without verifying products load.

    /// A transient empty product response must surface as .failed (with its
    /// retry affordance), never latch as .loaded-with-no-rows — every view
    /// .task guards on != .loaded, so a latched empty state would persist
    /// until the app is force-quit.
    @MainActor
    func testEmptyProductResponseIsFailureNotLoaded() {
        if case .failed = TipStore.postLoadState(tipCount: 0, subscriptionCount: 0) {
            // expected
        } else {
            XCTFail("empty product response must map to .failed, not .loaded")
        }
        XCTAssertEqual(TipStore.postLoadState(tipCount: 3, subscriptionCount: 2), .loaded)
        // Partial results still render whatever arrived.
        XCTAssertEqual(TipStore.postLoadState(tipCount: 3, subscriptionCount: 0), .loaded)
    }

    func testStoreKitConfigurationListsEveryProduct() throws {
        // The local .storekit file must stay in sync with StoreProducts.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let config = try String(contentsOf: root.appendingPathComponent("aTerminal.storekit"), encoding: .utf8)
        for id in StoreProducts.all {
            XCTAssertTrue(config.contains("\"\(id)\""), "\(id) missing from aTerminal.storekit")
        }
    }
}
