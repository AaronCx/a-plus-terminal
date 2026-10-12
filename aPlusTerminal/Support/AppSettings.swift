import Foundation
import Observation

/// Behavior preferences, persisted to UserDefaults. Appearance lives in
/// ThemeStore.
@Observable
final class AppSettings {
    /// §4.1 — after a reconnect, automatically reattach to the last recorded
    /// multiplexer target (tmux/zellij/screen/…). Renamed from `autoReattachTmux`.
    /// Show the detected agent's mascot mark (session rows, Live Activity)
    /// instead of the generic terminal glyph.
    var agentMascotIcons: Bool {
        didSet { defaults.set(agentMascotIcons, forKey: Keys.agentMascotIcons) }
    }

    var autoReattachMultiplexer: Bool {
        didSet { defaults.set(autoReattachMultiplexer, forKey: Keys.autoReattachMultiplexer) }
    }

    #if MESHYY
    /// Carry the pty byte stream over meshyy when the host runs `meshyyd`.
    ///
    /// OFF by default, and the toggle is the ONLY fallback: there is no runtime
    /// switching between transports, because a session that changes transport mid-flight
    /// is two different shells sharing one screen. Off = exactly this app without
    /// meshyy in it.
    var meshyyTransport: Bool {
        didSet { defaults.set(meshyyTransport, forKey: Keys.meshyyTransport) }
    }
    #endif

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

    /// Pop-Out Sessions (beta) master toggle: a view-only PiP monitor of a
    /// session. While off, the PiP engine is never constructed — no toolbar
    /// button, no audio-session activity, no observable background-mode
    /// behavior.
    var popOutSessions: Bool {
        didSet { defaults.set(popOutSessions, forKey: Keys.popOutSessions) }
    }

    /// Sub-toggle: let the system start the pop-out on app switch
    /// (`canStartPictureInPictureAutomaticallyFromInline`).
    var autoPopOutOnAppSwitch: Bool {
        didSet { defaults.set(autoPopOutOnAppSwitch, forKey: Keys.autoPopOutOnAppSwitch) }
    }

    /// Preview console capture (preview brief §Phase 4): mirrors the previewed
    /// page's `console` output into a pane inside the preview sheet, because a
    /// phone has no devtools. OFF by default and deliberately a setting rather
    /// than always-on: this is the only part of the preview that injects
    /// JavaScript into the user's own page. While off, no `WKUserScript` is
    /// installed and no script-message handler is registered at all.
    var previewConsoleCapture: Bool {
        didSet { defaults.set(previewConsoleCapture, forKey: Keys.previewConsoleCapture) }
    }

    #if MESHYY
    /// Scroll trace (Settings → Diagnostics): the user's explicit choice, nil
    /// when they never touched the toggle. nil follows the build channel —
    /// ON for DEBUG and TestFlight builds, OFF for the App Store — so a
    /// TestFlight tester records the next dead swipe without having to know
    /// the toggle exists, and a store user never records anything unasked.
    var scrollTraceOverride: Bool? {
        didSet {
            if let scrollTraceOverride {
                defaults.set(scrollTraceOverride, forKey: Keys.scrollTraceOverride)
            } else {
                defaults.removeObject(forKey: Keys.scrollTraceOverride)
            }
        }
    }

    /// What the build channel says when there is no override. Starts from the
    /// value cached by the previous launch's channel resolution (or a
    /// synchronous hint on first launch) and is corrected once
    /// `BuildChannel.resolve()` answers.
    var scrollTraceChannelDefault: Bool {
        didSet { defaults.set(scrollTraceChannelDefault, forKey: Keys.scrollTraceChannelDefault) }
    }

    /// The effective switch. Writing it records an explicit override.
    var scrollTraceEnabled: Bool {
        get { scrollTraceOverride ?? scrollTraceChannelDefault }
        set { scrollTraceOverride = newValue }
    }

    /// Applies a resolved build channel to the default (never to an override).
    func applyBuildChannel(_ channel: BuildChannel) {
        guard let value = channel.scrollTraceDefault else { return }
        if scrollTraceChannelDefault != value {
            scrollTraceChannelDefault = value
        }
    }
    #endif

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migration: honor the old keys if the new ones were never written.
        self.agentMascotIcons = defaults.object(forKey: Keys.agentMascotIcons) as? Bool ?? true
        self.autoReattachMultiplexer = defaults.object(forKey: Keys.autoReattachMultiplexer) as? Bool
            ?? defaults.object(forKey: Keys.legacyAutoReattachTmux) as? Bool
            ?? true
        self.scrollWheelBridge = defaults.object(forKey: Keys.scrollWheelBridge) as? Bool ?? true
        #if MESHYY
        self.meshyyTransport = defaults.bool(forKey: Keys.meshyyTransport)
        #endif
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
        // Both default OFF for v1 (brief §3.3).
        self.popOutSessions = defaults.bool(forKey: Keys.popOutSessions)
        self.autoPopOutOnAppSwitch = defaults.bool(forKey: Keys.autoPopOutOnAppSwitch)
        // OFF by default — JS injection into the user's page is opt-in.
        self.previewConsoleCapture = defaults.bool(forKey: Keys.previewConsoleCapture)
        #if MESHYY
        self.scrollTraceOverride = defaults.object(forKey: Keys.scrollTraceOverride) as? Bool
        #if DEBUG
        self.scrollTraceChannelDefault = true
        #else
        // A definite receipt wins over the cache: a TestFlight tester who
        // installs the App Store build over it keeps UserDefaults (cached ON),
        // and offline the async resolve can't correct it.
        self.scrollTraceChannelDefault = BuildChannel.synchronousHint.scrollTraceDefault
            ?? defaults.object(forKey: Keys.scrollTraceChannelDefault) as? Bool
            ?? false
        #endif
        #endif
    }

    private enum Keys {
        static let autoReattachMultiplexer = "autoReattachMultiplexer"
        static let agentMascotIcons = "agentMascotIcons"
        static let scrollWheelBridge = "scrollWheelBridge"
        static let multiplexerHintShown = "multiplexerHintShown"
        static let autoSendDictation = "autoSendDictation"
        static let defaultAgentProfileID = "defaultAgentProfileID"
        static let defaultMultiplexerProfileID = "defaultMultiplexerProfileID"
        static let keyBarItems = "keyBarItems"
        static let popOutSessions = "popOutSessions"
        static let autoPopOutOnAppSwitch = "autoPopOutOnAppSwitch"
        static let previewConsoleCapture = "previewConsoleCapture"
        #if MESHYY
        static let meshyyTransport = "meshyyTransport"
        static let scrollTraceOverride = "scrollTraceEnabled"
        static let scrollTraceChannelDefault = "scrollTraceChannelDefault"
        #endif
        // Legacy keys, read-only for migration.
        static let legacyAutoReattachTmux = "autoReattachTmux"
        static let legacyTmuxMouseHintShown = "tmuxMouseHintShown"
    }
}
