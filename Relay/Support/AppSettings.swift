import Foundation
import Observation

/// Behavior preferences, persisted to UserDefaults. Appearance lives in
/// ThemeStore.
@Observable
final class AppSettings {
    /// §4.1 — after a reconnect, automatically `tmux attach` to the last
    /// recorded target.
    var autoReattachTmux: Bool {
        didSet { defaults.set(autoReattachTmux, forKey: Keys.autoReattachTmux) }
    }

    /// §4.3 — translate pan gestures into SGR mouse wheel events when the
    /// remote app requested mouse reporting.
    var scrollWheelBridge: Bool {
        didSet { defaults.set(scrollWheelBridge, forKey: Keys.scrollWheelBridge) }
    }

    /// One-time tmux `set -g mouse on` hint (§4.3).
    var tmuxMouseHintShown: Bool {
        didSet { defaults.set(tmuxMouseHintShown, forKey: Keys.tmuxMouseHintShown) }
    }

    /// §4.4 — dictation auto-inserts with Return after 1.5s of silence.
    var autoSendDictation: Bool {
        didSet { defaults.set(autoSendDictation, forKey: Keys.autoSendDictation) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoReattachTmux = defaults.object(forKey: Keys.autoReattachTmux) as? Bool ?? true
        self.scrollWheelBridge = defaults.object(forKey: Keys.scrollWheelBridge) as? Bool ?? true
        self.tmuxMouseHintShown = defaults.bool(forKey: Keys.tmuxMouseHintShown)
        self.autoSendDictation = defaults.bool(forKey: Keys.autoSendDictation)
    }

    private enum Keys {
        static let autoReattachTmux = "autoReattachTmux"
        static let scrollWheelBridge = "scrollWheelBridge"
        static let tmuxMouseHintShown = "tmuxMouseHintShown"
        static let autoSendDictation = "autoSendDictation"
    }
}
