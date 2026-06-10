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

final class ThemeTypeSizeTests: XCTestCase {
    func testAppTypeSizeMapping() {
        let defaults = UserDefaults(suiteName: "ThemeTypeSizeTests")!
        defaults.removePersistentDomain(forName: "ThemeTypeSizeTests")
        let store = ThemeStore(defaults: defaults)

        store.appFontSize = 14
        XCTAssertEqual(store.appTypeSize, .small)
        store.appFontSize = ThemeStore.defaultAppFontSize
        XCTAssertEqual(store.appTypeSize, .large, "default 17pt maps to the system default size")
        store.appFontSize = 22
        XCTAssertEqual(store.appTypeSize, .xxxLarge)
        defaults.removePersistentDomain(forName: "ThemeTypeSizeTests")
    }
}
