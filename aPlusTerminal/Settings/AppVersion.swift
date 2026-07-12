import Foundation

/// Formats the marketing version + build number shown at the bottom of
/// Settings — so "which build am I on" is answerable in-app.
enum AppVersion {
    /// e.g. "a+Terminal 1.0 (18)". Degrades gracefully when either value is
    /// missing (only plausible in test bundles or a misconfigured Info.plist).
    static func displayString(short: String?, build: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (short.isEmpty, build.isEmpty) {
        case (false, false): return "a+Terminal \(short) (\(build))"
        case (false, true): return "a+Terminal \(short)"
        case (true, false): return "a+Terminal (\(build))"
        case (true, true): return "a+Terminal"
        }
    }

    /// The running app's version, read from the main bundle.
    static var current: String {
        let info = Bundle.main.infoDictionary
        return displayString(
            short: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }
}
