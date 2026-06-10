import SwiftUI
import Observation

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide appearance and font preferences, persisted to UserDefaults.
@Observable
final class ThemeStore {
    static let defaultAppFontSize: Double = 17
    static let defaultTerminalFontSize: Double = 13

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    var appFontSize: Double {
        didSet { defaults.set(appFontSize, forKey: Keys.appFontSize) }
    }

    var terminalFontSize: Double {
        didSet { defaults.set(terminalFontSize, forKey: Keys.terminalFontSize) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        let appSize = defaults.double(forKey: Keys.appFontSize)
        self.appFontSize = appSize > 0 ? appSize : Self.defaultAppFontSize
        let termSize = defaults.double(forKey: Keys.terminalFontSize)
        self.terminalFontSize = termSize > 0 ? termSize : Self.defaultTerminalFontSize
    }

    /// App-wide type size derived from the Application font slider (§4.6).
    var appTypeSize: DynamicTypeSize {
        switch appFontSize {
        case ..<15: return .small
        case ..<16.5: return .medium
        case ..<18: return .large
        case ..<19.5: return .xLarge
        case ..<21: return .xxLarge
        default: return .xxxLarge
        }
    }

    func resetAppFontSize() {
        appFontSize = Self.defaultAppFontSize
    }

    func resetTerminalFontSize() {
        terminalFontSize = Self.defaultTerminalFontSize
    }

    private enum Keys {
        static let theme = "theme"
        static let appFontSize = "appFontSize"
        static let terminalFontSize = "terminalFontSize"
    }
}
