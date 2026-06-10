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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoReattachTmux = defaults.object(forKey: Keys.autoReattachTmux) as? Bool ?? true
    }

    private enum Keys {
        static let autoReattachTmux = "autoReattachTmux"
    }
}
