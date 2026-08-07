import UIKit

/// User-supplied agent icons, one PNG per profile id, in the App Group so the
/// widget extension can draw them too. This is the "bring your own art" half
/// of the icons feature: the app SHIPS only original or licensed marks, and a
/// user who wants a vendor's real mascot drops it in themselves — their copy,
/// their use, nothing redistributed by the app.
enum CustomAgentIconStore {
    static let groupID = "group.com.aaroncx.aplusterminal"

    private static func directory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else { return nil }
        let dir = container.appendingPathComponent("AgentIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func imageURL(for profileID: String) -> URL? {
        guard let url = directory()?.appendingPathComponent("\(profileID).png"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Saves a user-picked image, normalized: square-padded, capped at 360px,
    /// re-encoded as PNG. Normalizing here means every consumer — rows, Live
    /// Activity, island — renders the same thing without per-site scaling
    /// surprises, and a 12 MB camera photo cannot ride into the widget's
    /// memory budget.
    @discardableResult
    static func save(_ data: Data, for profileID: String) -> Bool {
        guard let source = UIImage(data: data),
              let dir = directory() else { return false }
        let side: CGFloat = 360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let normalized = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { _ in
            let s = source.size
            guard s.width > 0, s.height > 0 else { return }
            let scale = min(side / s.width, side / s.height)
            let w = s.width * scale, h = s.height * scale
            source.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        guard let png = normalized.pngData() else { return false }
        do {
            try png.write(to: dir.appendingPathComponent("\(profileID).png"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func clear(for profileID: String) {
        guard let dir = directory() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(profileID).png"))
    }
}
