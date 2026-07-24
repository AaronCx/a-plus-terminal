import CoreGraphics

/// Pure geometry between the canvas view (aspect-fitted remote image) and
/// framebuffer pixel coordinates. Kept UIKit-free so every mapping rule the
/// touch controls depend on is unit-testable.
enum VNCPointMapping {
    /// Where the aspect-fitted content sits inside the container.
    static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// View point → framebuffer pixel. Nil outside the fitted content (the
    /// letterbox is not the remote screen); results clamp to valid pixels.
    static func framebufferPoint(from viewPoint: CGPoint, content: CGSize, container: CGSize) -> CGPoint? {
        let fitted = fittedRect(content: content, in: container)
        guard fitted.width > 0, fitted.contains(viewPoint) else { return nil }
        let x = (viewPoint.x - fitted.minX) / fitted.width * content.width
        let y = (viewPoint.y - fitted.minY) / fitted.height * content.height
        return CGPoint(
            x: min(max(x, 0), content.width - 1),
            y: min(max(y, 0), content.height - 1)
        )
    }

    /// Framebuffer pixel → view point (cursor overlay placement).
    static func viewPoint(from framebufferPoint: CGPoint, content: CGSize, container: CGSize) -> CGPoint {
        let fitted = fittedRect(content: content, in: container)
        guard content.width > 0, content.height > 0, fitted.width > 0 else { return .zero }
        return CGPoint(
            x: fitted.minX + framebufferPoint.x / content.width * fitted.width,
            y: fitted.minY + framebufferPoint.y / content.height * fitted.height
        )
    }

    /// Scale from framebuffer pixels to view points inside the fitted rect.
    static func fitScale(content: CGSize, in container: CGSize) -> CGFloat {
        guard content.width > 0 else { return 1 }
        return fittedRect(content: content, in: container).width / content.width
    }
}
