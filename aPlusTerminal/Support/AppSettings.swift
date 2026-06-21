import Foundation
import Observation

/// Behavior preferences, persisted to UserDefaults. Appearance lives in
/// ThemeStore.
@Observable
final class AppSettings {
    /// §4.1 — after a reconnect, automatically reattach to the last recorded
    /// multiplexer target (tmux/zellij/screen/…). Renamed from `autoReattachTmux`.
    var autoReattachMultiplexer: Bool {
        didSet { defaults.set(autoReattachMultiplexer, forKey: Keys.autoReattachMultiplexer) }
    }

    /// §4.3 — translate pan gestures into SGR mouse wheel events when the
    /// remote app requested mouse reporting.
    var scrollWheelBridge: Bool {
        didSet { defaults.set(scrollWheelBridge, forKey: Keys.scrollWheelBridge) }
    }

    /// One-time "enable mouse" hint (§4.3). Renamed from `tmuxMouseHintShown`.
    var multiplexerHintShown: Bool {
        didSet { defaults.set(multiplexerHintShown, forKey: Keys.multiplexerHintShown) }
    }

    /// §4.4 — dictation auto-inserts with Return after 1.5s of silence.
    var autoSendDictation: Bool {
        didSet { defaults.set(autoSendDictation, forKey: Keys.autoSendDictation) }
    }

    /// Global default agent profile id; "auto" detects any seeded agent.
    var defaultAgentProfileID: String {
        didSet { defaults.set(defaultAgentProfileID, forKey: Keys.defaultAgentProfileID) }
    }

    /// Global default multiplexer profile id; "tmux" preserves prior behavior.
    var defaultMultiplexerProfileID: String {
        didSet { defaults.set(defaultMultiplexerProfileID, forKey: Keys.defaultMultiplexerProfileID) }
    }

    /// Build 14 — the accessory key bar's items and order. Defaults to the
    /// original bar; user-editable in Settings.
    var keyBarItems: [KeyBarItem] {
        didSet { defaults.set(keyBarItems.map(\.rawValue), forKey: Keys.keyBarItems) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migration: honor the old keys if the new ones were never written.
        self.autoReattachMultiplexer = defaults.object(forKey: Keys.autoReattachMultiplexer) as? Bool
            ?? defaults.object(forKey: Keys.legacyAutoReattachTmux) as? Bool
            ?? true
        self.scrollWheelBridge = defaults.object(forKey: Keys.scrollWheelBridge) as? Bool ?? true
        self.multiplexerHintShown = defaults.object(forKey: Keys.multiplexerHintShown) as? Bool
            ?? defaults.bool(forKey: Keys.legacyTmuxMouseHintShown)
        self.autoSendDictation = defaults.bool(forKey: Keys.autoSendDictation)
        self.defaultAgentProfileID = defaults.string(forKey: Keys.defaultAgentProfileID) ?? "auto"
        self.defaultMultiplexerProfileID = defaults.string(forKey: Keys.defaultMultiplexerProfileID) ?? "tmux"
        if let raw = defaults.array(forKey: Keys.keyBarItems) as? [String] {
            let items = raw.compactMap(KeyBarItem.init(rawValue:))
            self.keyBarItems = items.isEmpty ? KeyBarItem.defaultItems : items
        } else {
            self.keyBarItems = KeyBarItem.defaultItems
        }
    }

    private enum Keys {
        static let autoReattachMultiplexer = "autoReattachMultiplexer"
        static let scrollWheelBridge = "scrollWheelBridge"
        static let multiplexerHintShown = "multiplexerHintShown"
        static let autoSendDictation = "autoSendDictation"
        static let defaultAgentProfileID = "defaultAgentProfileID"
        static let defaultMultiplexerProfileID = "defaultMultiplexerProfileID"
        static let keyBarItems = "keyBarItems"
        // Legacy keys, read-only for migration.
        static let legacyAutoReattachTmux = "autoReattachTmux"
        static let legacyTmuxMouseHintShown = "tmuxMouseHintShown"
    }
}
