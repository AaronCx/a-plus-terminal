import Foundation
import Observation

/// How the Live Activity should behave across app close and device lock.
/// The platform offers a pick-two: ActivityKit's transient style dies with
/// the process (great: force-quit removes the card) but ALSO ends on device
/// lock; the standard style survives lock and backgrounding but lingers
/// after a background force-quit until the next launch reconciles it. There
/// is no style that does both, so the trade-off is the user's to make.
enum LiveActivityMode: String, CaseIterable, Identifiable {
    /// ActivityKit's transient style: the Activity dies with the process —
    /// and, as an iOS limitation of that style, on device lock too.
    case endOnClose
    /// The standard (style-less) request: survives lock and backgrounding;
    /// a force-quit orphan is cleared by the next launch's reconcile.
    case persistThroughLock

    var id: String { rawValue }

    /// Picker row label.
    var label: String {
        switch self {
        case .endOnClose: return "End when app closes"
        case .persistThroughLock: return "Stay through the lock screen"
        }
    }

    /// Settings footnote spelling out the mode's exact platform behavior.
    var footnote: String {
        switch self {
        case .endOnClose:
            return "The Live Activity disappears when you close the app — and also when the phone locks (an iOS limitation of this mode)."
        case .persistThroughLock:
            return "The Live Activity survives locking and backgrounding; after a force quit it clears the next time you open the app."
        }
    }
}

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

    /// §4.5 — Live Activity behavior across close/lock (see LiveActivityMode).
    /// Defaults to endOnClose: "the card is gone when I close the app" is the
    /// least surprising baseline; persisting through lock is the opt-in.
    var liveActivityMode: LiveActivityMode {
        didSet { defaults.set(liveActivityMode.rawValue, forKey: Keys.liveActivityMode) }
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
        self.liveActivityMode = defaults.string(forKey: Keys.liveActivityMode)
            .flatMap(LiveActivityMode.init(rawValue:)) ?? .endOnClose
    }

    private enum Keys {
        static let autoReattachMultiplexer = "autoReattachMultiplexer"
        static let scrollWheelBridge = "scrollWheelBridge"
        static let multiplexerHintShown = "multiplexerHintShown"
        static let autoSendDictation = "autoSendDictation"
        static let defaultAgentProfileID = "defaultAgentProfileID"
        static let defaultMultiplexerProfileID = "defaultMultiplexerProfileID"
        static let keyBarItems = "keyBarItems"
        static let liveActivityMode = "liveActivityMode"
        // Legacy keys, read-only for migration.
        static let legacyAutoReattachTmux = "autoReattachTmux"
        static let legacyTmuxMouseHintShown = "tmuxMouseHintShown"
    }
}
