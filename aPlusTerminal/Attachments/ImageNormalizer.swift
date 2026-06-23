import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Prepares an image picked on the phone for a CLI AI agent on the server:
/// agents accept JPEG/PNG/GIF/WebP up to ~5 MB, while iOS photos are often HEIC
/// and can be large. Already-valid, small-enough payloads pass through
/// untouched; everything else is transcoded (PNG for lossless sources, JPEG
/// otherwise) and downscaled under the cap. No third-party dependency — only
/// ImageIO/UIKit, which keeps the zero-data, no-new-SDK contract.
enum ImageNormalizer {
    /// Agent-friendly upper bound; see spec §"Processing".
    static let maxBytes = 5 * 1024 * 1024
    /// Longest-side ceiling when downscaling to fit the cap.
    static let maxDimension: CGFloat = 4096

    private static let passthroughExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    /// Returns the bytes to upload and the file extension to use.
    /// - Parameters:
    ///   - data: raw bytes from the picker.
    ///   - sourceExt: the picker's reported extension (may be empty/`heic`).
    static func normalize(_ data: Data, sourceExt: String) -> (data: Data, ext: String) {
        let ext = sourceExt.lowercased()

        // Fast path: a format agents already read, already under the cap.
        if passthroughExtensions.contains(ext), data.count <= maxBytes {
            return (data, ext == "jpeg" ? "jpg" : ext)
        }

        // An animated GIF over the cap can't be losslessly downscaled with
        // UIKit; re-encoding flattens it to a single still frame. Pass the
        // original bytes through instead (the agent enforces its own size cap)
        // rather than silently dropping the animation.
        if ext == "gif", Self.isAnimated(data) {
            return (data, "gif")
        }

        guard let image = UIImage(data: data) else {
            // Undecodable here means we can't improve it; ship the original
            // bytes with a best-effort extension rather than dropping the file.
            let fallbackExt = passthroughExtensions.contains(ext) ? (ext == "jpeg" ? "jpg" : ext) : "bin"
            return (data, fallbackExt)
        }

        // Lossless sources (PNG, GIF) keep PNG; photos become JPEG.
        let preferPNG = (ext == "png" || ext == "gif")
        if let encoded = encode(image, preferPNG: preferPNG, within: maxBytes) {
            return encoded
        }
        // Couldn't get under the cap — return the smallest we produced anyway.
        return encode(image, preferPNG: preferPNG, within: .max) ?? (data, preferPNG ? "png" : "jpg")
    }

    /// Encodes `image`, downscaling the longest side in steps until the result
    /// fits `limit`. Returns nil only if no encoding step fits.
    private static func encode(_ image: UIImage, preferPNG: Bool, within limit: Int) -> (data: Data, ext: String)? {
        // Each scale is a fraction of the ORIGINAL — resize from `image` every
        // step. Resizing the previously-scaled result instead compounds the
        // factors (0.75·0.5·0.35·… ≈ 0.5% by the last step), shrinking images
        // to thumbnails when only a modest downscale was needed.
        let scales: [CGFloat] = [1.0, 0.75, 0.5, 0.35, 0.25, 0.15]
        for scale in scales {
            let scaled = scale == 1.0 ? image : ImageNormalizer.resize(image, scale: scale)
            if preferPNG, let png = clamp(scaled), let data = png.pngData(), data.count <= limit {
                return (data, "png")
            }
            if let jpeg = jpegUnderLimit(scaled, limit: limit) {
                return jpeg
            }
        }
        return nil
    }

    /// Encodes JPEG, lowering quality before giving up on this size.
    private static func jpegUnderLimit(_ image: UIImage, limit: Int) -> (data: Data, ext: String)? {
        for quality in [CGFloat(0.8), 0.6, 0.4] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= limit {
                return (data, "jpg")
            }
        }
        return nil
    }

    /// Caps the longest side at `maxDimension` without upscaling.
    private static func clamp(_ image: UIImage) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        return resize(image, scale: maxDimension / longest)
    }

    /// True when `data` decodes to more than one frame (animated GIF).
    private static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    private static func resize(_ image: UIImage, scale: CGFloat) -> UIImage {
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
