import XCTest
@testable import aPlusTerminal

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
        XCTAssertTrue(settings.autoReattachMultiplexer, "auto-reattach defaults ON (§4.1)")
        XCTAssertTrue(settings.scrollWheelBridge, "wheel bridge defaults ON (§4.3)")
        XCTAssertFalse(settings.autoSendDictation, "auto-send defaults OFF (§4.4)")
        XCTAssertFalse(settings.multiplexerHintShown)
        XCTAssertEqual(settings.defaultAgentProfileID, "auto")
        XCTAssertEqual(settings.defaultMultiplexerProfileID, "tmux")
    }

    func testPersistsAcrossInstances() {
        let settings = AppSettings(defaults: defaults)
        settings.autoReattachMultiplexer = false
        settings.scrollWheelBridge = false
        settings.autoSendDictation = true
        settings.multiplexerHintShown = true
        settings.defaultAgentProfileID = "codex"
        settings.defaultMultiplexerProfileID = "zellij"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autoReattachMultiplexer)
        XCTAssertFalse(reloaded.scrollWheelBridge)
        XCTAssertTrue(reloaded.autoSendDictation)
        XCTAssertTrue(reloaded.multiplexerHintShown)
        XCTAssertEqual(reloaded.defaultAgentProfileID, "codex")
        XCTAssertEqual(reloaded.defaultMultiplexerProfileID, "zellij")
    }

    func testMigratesLegacyKeys() {
        // A pre-refactor install wrote the old keys; the new properties must
        // honor them when the new keys are absent.
        defaults.set(false, forKey: "autoReattachTmux")
        defaults.set(true, forKey: "tmuxMouseHintShown")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoReattachMultiplexer, "legacy autoReattachTmux must carry over")
        XCTAssertTrue(settings.multiplexerHintShown, "legacy tmuxMouseHintShown must carry over")
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
