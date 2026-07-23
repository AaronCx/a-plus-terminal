import CoreVideo
import UIKit

/// PiP surface for a VNC monitor: the latest remote frame, aspect-fit into
/// the buffer (CoreGraphics downscale), throttled to at most 5 fps while the
/// pop-out is active (brief §4.3) via its own coalescer ahead of the
/// engine's. System pause freezes the frame and badges it.
@MainActor
final class VNCFrameSource: PiPFrameSource {
    private weak var session: VNCMonitorSession?
    /// Paces this source's invalidations at 5 fps before they ever reach
    /// the engine's 10 fps coalescer.
    private let pacer: PiPFrameCoalescer
    private var frozenFrame: CGImage?

    let preferredBufferSize = CGSize(width: 960, height: 600)
    var onInvalidate: (() -> Void)?
    var onDetach: (() -> Void)?

    var followSuspended: Bool = false {
        didSet {
            guard followSuspended != oldValue else { return }
            frozenFrame = followSuspended ? session?.lastFrame : nil
        }
    }

    var restoreSessionID: UUID? { session?.id }

    init(session: VNCMonitorSession, maxFrameInterval: TimeInterval = 0.2) {
        self.session = session
        self.pacer = PiPFrameCoalescer(minInterval: maxFrameInterval)
        pacer.render = { [weak self] in self?.onInvalidate?() }
    }

    /// Called (via the session's pipInvalidate slot) on every new frame.
    func noteFrame() {
        pacer.invalidate()
    }

    func renderFrame(into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var leased: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &leased) == kCVReturnSuccess,
              let buffer = leased else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        memset(base, 0, CVPixelBufferGetDataSize(buffer))
        guard let context = CGContext(
            data: base,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let bounds = CGRect(origin: .zero, size: preferredBufferSize)
        context.setFillColor(UIColor(white: 0.07, alpha: 1).cgColor)
        context.fill(bounds)

        let frame = frozenFrame ?? session?.lastFrame
        if let frame {
            let imageSize = CGSize(width: frame.width, height: frame.height)
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let fitted = CGRect(
                x: (bounds.width - imageSize.width * scale) / 2,
                y: (bounds.height - imageSize.height * scale) / 2,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            context.interpolationQuality = .medium
            context.draw(frame, in: fitted)
        }

        // Text/badge drawing wants UIKit's top-left origin.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        if frame == nil {
            let font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            let text = "Connecting to \(session?.server.name ?? "monitor")…"
            let size = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(
                at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: [.font: font, .foregroundColor: UIColor(white: 0.85, alpha: 1)]
            )
        }
        if followSuspended {
            drawPausedBadge(in: bounds)
        }
        return buffer
    }

    private func drawPausedBadge(in bounds: CGRect) {
        let font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let text = "Paused"
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let padding: CGFloat = 12
        let badge = CGRect(
            x: bounds.width - textSize.width - padding * 2 - 16,
            y: 16,
            width: textSize.width + padding * 2,
            height: textSize.height + 10
        )
        let path = UIBezierPath(roundedRect: badge, cornerRadius: badge.height / 2)
        UIColor.systemYellow.withAlphaComponent(0.3).setFill()
        path.fill()
        (text as NSString).draw(
            at: CGPoint(x: badge.minX + padding, y: badge.minY + 5),
            withAttributes: [.font: font, .foregroundColor: UIColor.systemYellow]
        )
    }

    func detach() {
        pacer.cancel()
        onInvalidate = nil
        onDetach?()
        onDetach = nil
    }
}
