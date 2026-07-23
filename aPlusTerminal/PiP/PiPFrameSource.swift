import CoreVideo
import Foundation

/// A content source for the shared PiP engine: something that can render its
/// current state into a pixel buffer and signal when that state changed. The
/// engine decides *when* to render (debounced, frame-rate capped); sources
/// only signal invalidation and draw on demand.
@MainActor
protocol PiPFrameSource: AnyObject {
    /// Pixel size of the buffers the engine should allocate for this source.
    var preferredBufferSize: CGSize { get }

    /// Fired (main actor) whenever content changed and a fresh frame should
    /// eventually be rendered. Assigned by the engine while attached.
    var onInvalidate: (() -> Void)? { get set }

    /// Set by the engine when the user hits the system pause button. Sources
    /// freeze their surface (stop following live content) while true and
    /// resume following the moment it clears.
    var followSuspended: Bool { get set }

    /// The session whose screen the app should present when the user taps
    /// back into the app from the PiP window.
    var restoreSessionID: UUID? { get }

    /// Draw the current content into a buffer leased from `pool`. Returns nil
    /// when no buffer could be leased — the engine keeps the previous frame.
    func renderFrame(into pool: CVPixelBufferPool) -> CVPixelBuffer?

    /// The engine stopped using this source: unhook invalidation plumbing.
    func detach()
}
