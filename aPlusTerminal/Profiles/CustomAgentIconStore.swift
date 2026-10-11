import UIKit

/// User-supplied agent icons, one PNG per profile id, in the App Group so the
/// widget extension can draw them too. This is the "bring your own art" half
/// of the icons feature: the app SHIPS only original or licensed marks, and a
/// user who wants a vendor's real mascot drops it in themselves — their copy,
/// their use, nothing redistributed by the app.
///
/// Compiled into BOTH the app and the widget extension (project.yml), so the
/// path the widget reads can never drift from the path the app writes.
enum CustomAgentIconStore {
    static let groupID = "group.com.aaroncx.aplusterminal"
    /// Bundled fallback for an agent with no art of its own (a custom agent
    /// before the user picks an icon). Without it, `Image("agent-<id>")`
    /// names an asset that doesn't exist and draws nothing.
    static let genericAssetName = "agent-generic"
    /// Stored edge length in pixels.
    static let side: CGFloat = 360

    private static func directory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else { return nil }
        let dir = container.appendingPathComponent("AgentIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The id becomes a file name: anything that isn't a valid profile id
    /// (path separators, "..") is refused here as well as at import.
    private static func fileURL(for profileID: String) -> URL? {
        guard AgentProfile.isValidID(profileID) else { return nil }
        return directory()?.appendingPathComponent("\(profileID).png")
    }

    static func imageURL(for profileID: String) -> URL? {
        guard let url = fileURL(for: profileID),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// "agent-<id>" → "<id>", the key the custom file is stored under.
    static func profileID(fromIconName iconName: String) -> String {
        iconName.hasPrefix("agent-") ? String(iconName.dropFirst(6)) : iconName
    }

    /// Where an icon name's art comes from, in the order every surface
    /// checks: the user's own PNG, the bundled doodle, the generic doodle.
    enum Source: Equatable {
        case custom(URL)
        case bundled(String)
        case generic

        /// Asset name to draw when the source isn't a custom file.
        var assetName: String {
            if case .bundled(let name) = self { return name }
            return CustomAgentIconStore.genericAssetName
        }

        /// Stable token for accessibility identifiers ("custom", "bundled",
        /// "generic") — lets UI tests assert WHICH art a row drew.
        var kind: String {
            switch self {
            case .custom: return "custom"
            case .bundled: return "bundled"
            case .generic: return "generic"
            }
        }
    }

    static func source(forIconName iconName: String) -> Source {
        if let url = imageURL(for: profileID(fromIconName: iconName)) {
            return .custom(url)
        }
        // UIImage(named:) looks in the CALLING process's main bundle; the
        // asset catalog is compiled into both the app and the widget.
        if UIImage(named: iconName) != nil {
            return .bundled(iconName)
        }
        return .generic
    }

    /// The stored form of a user-picked image: center-cropped to a square
    /// (aspect-fill — the short edge fills the frame, the long edge is
    /// trimmed evenly), 360px, PNG. Normalizing here means every consumer —
    /// rows, Live Activity, island — renders the same thing without per-site
    /// scaling surprises, and a 12 MB camera photo cannot ride into the
    /// widget's memory budget. Nil when the data isn't an image.
    static func normalizedPNG(from data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let s = source.size
        guard s.width > 0, s.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let normalized = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { _ in
            let scale = max(side / s.width, side / s.height)
            let w = s.width * scale, h = s.height * scale
            source.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        return normalized.pngData()
    }

    /// Normalizes and stores a user-picked image for a profile.
    @discardableResult
    static func save(_ data: Data, for profileID: String) -> Bool {
        guard let png = normalizedPNG(from: data) else { return false }
        return write(png: png, for: profileID)
    }

    /// Stores an already-normalized PNG (the editor stages one for preview
    /// and writes it on Save).
    @discardableResult
    static func write(png: Data, for profileID: String) -> Bool {
        guard let url = fileURL(for: profileID) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func clear(for profileID: String) {
        guard let url = fileURL(for: profileID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    #if DEBUG
    /// Test seam (TestSeed's agents reset): every stored icon, gone.
    static func removeAllForTesting() {
        guard let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }
    #endif
}
