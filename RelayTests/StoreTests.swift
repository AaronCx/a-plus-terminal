import XCTest
@testable import Relay

/// Product IDs are App Store Connect contracts — lock them down so a refactor
/// can't silently break live purchases.
final class RelayProductsTests: XCTestCase {
    func testProductIdentifiersAreStable() {
        XCTAssertEqual(RelayProducts.tips, [
            "com.aaroncx.relay.tip.small",
            "com.aaroncx.relay.tip.medium",
            "com.aaroncx.relay.tip.large",
        ])
        XCTAssertEqual(RelayProducts.subscriptions, [
            "com.aaroncx.relay.supporter.monthly",
            "com.aaroncx.relay.supporter.yearly",
        ])
        XCTAssertEqual(RelayProducts.all.count, 5)
    }

    func testStoreKitConfigurationListsEveryProduct() throws {
        // The local .storekit file must stay in sync with RelayProducts.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let config = try String(contentsOf: root.appendingPathComponent("Relay.storekit"), encoding: .utf8)
        for id in RelayProducts.all {
            XCTAssertTrue(config.contains("\"\(id)\""), "\(id) missing from Relay.storekit")
        }
    }
}
