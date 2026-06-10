import XCTest
@testable import Relay

final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AppSettingsTests")
        defaults.removePersistentDomain(forName: "AppSettingsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AppSettingsTests")
        super.tearDown()
    }

    func testDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoReattachTmux, "auto-reattach defaults ON (§4.1)")
        XCTAssertTrue(settings.scrollWheelBridge, "wheel bridge defaults ON (§4.3)")
        XCTAssertFalse(settings.autoSendDictation, "auto-send defaults OFF (§4.4)")
        XCTAssertFalse(settings.tmuxMouseHintShown)
    }

    func testPersistsAcrossInstances() {
        let settings = AppSettings(defaults: defaults)
        settings.autoReattachTmux = false
        settings.scrollWheelBridge = false
        settings.autoSendDictation = true
        settings.tmuxMouseHintShown = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autoReattachTmux)
        XCTAssertFalse(reloaded.scrollWheelBridge)
        XCTAssertTrue(reloaded.autoSendDictation)
        XCTAssertTrue(reloaded.tmuxMouseHintShown)
    }
}
