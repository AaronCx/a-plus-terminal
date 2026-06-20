import XCTest
import UIKit
@testable import aPlusTerminal

@MainActor
final class AttachmentTests: XCTestCase {
    // MARK: - formatAttachment

    func testFormatAttachmentIsBarePathPlusTrailingSpace() {
        XCTAssertEqual(TerminalSession.formatAttachment(path: "/home/me/.aplusterminal-inbox/x.png"),
                       "/home/me/.aplusterminal-inbox/x.png ")
        XCTAssertFalse(TerminalSession.formatAttachment(path: "/x").contains("\n"),
                       "must never inject a newline — the user presses Enter")
    }

    // MARK: - sanitize

    func testSanitizePreservesExtensionAndReplacesUnsafeChars() {
        XCTAssertEqual(TerminalSession.sanitize("my report.pdf"), "my_report.pdf")
        XCTAssertEqual(TerminalSession.sanitize("a/b\\c:d.txt"), "a_b_c_d.txt")
        XCTAssertEqual(TerminalSession.sanitize("safe-name_1.tar.gz"), "safe-name_1.tar.gz")
    }

    func testSanitizeEmptyFallsBackToFile() {
        XCTAssertEqual(TerminalSession.sanitize(""), "file")
        XCTAssertEqual(TerminalSession.sanitize("///"), "___") // unsafe but non-empty stays
    }

    // MARK: - ImageNormalizer

    private func solidImage(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testNormalizeSmallPNGPassesThrough() {
        let png = solidImage(CGSize(width: 16, height: 16)).pngData()!
        let (data, ext) = ImageNormalizer.normalize(png, sourceExt: "png")
        XCTAssertEqual(ext, "png")
        XCTAssertEqual(data, png, "a small valid PNG must not be re-encoded")
    }

    func testNormalizeJpegExtensionCanonicalized() {
        let jpeg = solidImage(CGSize(width: 16, height: 16)).jpegData(compressionQuality: 0.9)!
        let (_, ext) = ImageNormalizer.normalize(jpeg, sourceExt: "jpeg")
        XCTAssertEqual(ext, "jpg", "jpeg should normalize to jpg")
    }

    func testNormalizeHEICLikeUnknownTranscodesToJpeg() {
        // Simulate a photo whose extension agents don't accept: a PNG payload
        // labeled "heic". It must be transcoded to a JPEG (photo path).
        let png = solidImage(CGSize(width: 64, height: 64)).pngData()!
        let (data, ext) = ImageNormalizer.normalize(png, sourceExt: "heic")
        XCTAssertEqual(ext, "jpg")
        XCTAssertNotNil(UIImage(data: data), "transcoded output must be a decodable image")
    }

    func testNormalizeDownscalesOversizedImageUnderCap() {
        // A large image whose encoding would exceed 5 MB must come back under it.
        let big = solidImage(CGSize(width: 8000, height: 8000))
        // Use the PNG path (lossless) on a non-passthrough ext to force work.
        let png = big.pngData()!
        let (data, _) = ImageNormalizer.normalize(png, sourceExt: "tiff")
        XCTAssertLessThanOrEqual(data.count, ImageNormalizer.maxBytes,
                                 "oversized images must be downscaled/compressed under the cap")
    }
}
