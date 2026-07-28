import CoreVideo
import UIKit
import WebKit

/// PiP surface for the localhost preview: the live `WKWebView` of a forwarded
/// dev server, captured asynchronously and blitted into the pop-out window.
///
/// **Why a preview pop-out is not a gimmick.** `PreviewScreen`'s footer says it
/// plainly: the preview only works while a+Terminal is on screen. The tunnel is
/// a loopback listener owned by this process (`SSHPortForward`) — switch apps,
/// iOS suspends the process, the listener closes, the forward closes with it,
/// and the page dies mid-request. That is also why the sheet deliberately has
/// no "open in Safari" button for the tunnel URL: handing that URL to another
/// app is guaranteed to background this one and kill the very server the URL
/// points at.
///
/// A live PiP window is the one and only exception to that rule. While the
/// pop-out is up the process keeps running instead of being suspended, so the
/// loopback listener stays bound and the forward stays open. Popping the
/// preview out is therefore not "the same page, smaller" — it is the only way
/// to keep watching a dev server (a build log page, a dashboard, an HMR
/// reload) while doing something else on the phone. Close the pop-out and the
/// tunnel goes back to being foreground-only.
///
/// **Why capture is asynchronous.** Measured in the iOS 26 Simulator against a
/// real loaded page in a real key window (`PreviewSnapshotBenchmarkTests`, 15
/// iterations after warm-up):
///
/// | strategy                                | median  | p90     | pixels? |
/// |-----------------------------------------|---------|---------|---------|
/// | `takeSnapshot` (default)                | 15.1 ms | 15.2 ms | BLANK   |
/// | `takeSnapshot(afterScreenUpdates:false)`|  0.44ms |  0.46ms | BLANK   |
/// | `takeSnapshot(snapshotWidth: 300)`      | 15.1 ms | 15.1 ms | BLANK   |
/// | `drawHierarchy(afterScreenUpdates:false)`| 0.79ms |  0.87ms | BLANK   |
/// | `drawHierarchy(afterScreenUpdates:true)`| 25.1 ms | 32.8 ms | RENDERS |
///
/// Two conclusions drive the whole design of this class:
///
/// 1. The only strategy *proven* to produce pixels in the Simulator is
///    `drawHierarchy(in:afterScreenUpdates: true)`. `takeSnapshot` returning a
///    non-nil but uniform image is the known out-of-process WebContent artifact
///    — on real hardware `takeSnapshot` generally does work, and it is the
///    cheaper and more correct API when it does. So this source hard-depends on
///    neither: it probes once and latches (see `CaptureStrategy`).
/// 2. At ~25 ms (p90 33 ms) a capture is far too expensive to run inside
///    `renderFrame(into:)`, which is synchronous and on the main actor. Even
///    with `PiPFrameCoalescer` capping rendering at 10 fps, that would be a
///    25–33% main-thread duty cycle spent snapshotting — visible jank in
///    whatever the user is actually doing.
///
/// Hence: a capture `Task` writes into a cached `UIImage`, and `renderFrame`
/// only blits that cache. Behaviourally this is an *image* source, exactly like
/// `VNCFrameSource`, not a content source that packs discrete units like
/// `TerminalPiPFrameSource`.
@MainActor
final class PreviewPiPFrameSource: PiPFrameSource {
    /// Which capture API this attachment settled on. Latched after the first
    /// capture and then never revisited — see `capture()`.
    enum CaptureStrategy: String, Equatable {
        /// Nothing captured yet; the next capture tries `takeSnapshot` first.
        case probing
        /// `takeSnapshot` produced real pixels here (the expected outcome on
        /// device): cheaper than `drawHierarchy` and it renders the WebContent
        /// process's own output rather than the host view's layer tree.
        case snapshot
        /// `takeSnapshot` came back nil or uniform once, so it is not usable in
        /// this environment (the Simulator, or a WebContent process that
        /// refuses to vend a snapshot). Fall back to the slow-but-proven path.
        case drawHierarchy
    }

    /// 2 Hz. Justified against the benchmark: one capture costs ~25 ms median /
    /// ~33 ms p90 of main-actor time on the fallback path. Capturing at the
    /// engine's 10 fps ceiling would burn a quarter to a third of the main
    /// thread on snapshots; at 2 Hz it is ~5–6%, which is affordable for a
    /// window whose whole job is at-a-glance monitoring. It is also honest
    /// about the content: a dev server's page changes when the user saves a
    /// file or a build finishes — human cadence — so a worst-case 500 ms lag
    /// behind the real page is imperceptible, while a smoother capture rate
    /// would buy nothing but heat.
    nonisolated static let captureInterval: TimeInterval = 0.5

    /// Point width requested from `takeSnapshot`, derived rather than guessed.
    ///
    /// `snapshotWidth` is in POINTS and WebKit returns the image at the
    /// window's scale, so a fixed 480 was measured returning a 1440x2585 image
    /// (~14.9 MB) from a 390pt-wide view — *larger* than the ~9.8 MB the
    /// default produces, i.e. it upscaled while claiming to economise. What the
    /// surface can actually use is `renderer.size.width` PIXELS, so the request
    /// has to be that divided by the screen scale, and never more points than
    /// the view genuinely has.
    private func snapshotPointWidth(for webView: WKWebView) -> CGFloat {
        let scale = max(1, webView.window?.screen.scale ?? UIScreen.main.scale)
        return min(webView.bounds.width, renderer.size.width / scale)
    }

    /// Resolved per tick rather than captured once. `PreviewScreen` rebuilds
    /// its `WKWebView` whenever console capture is toggled (it applies `.id()`
    /// to force exactly that), and the handle holds the view weakly — so a
    /// source that latched onto one instance would render a dead page forever
    /// while the live one sat right there. Asking the handle each time picks
    /// the new view up on the next tick.
    private let resolveWebView: () -> WKWebView?
    private var webView: WKWebView? { resolveWebView() }
    private let title: () -> String
    private let subtitle: () -> String?
    private let renderer: PreviewPiPSurfaceRenderer
    /// Injectable clock (tests).
    private let now: () -> Date

    /// The async capture loop. Started when the engine attaches (sets
    /// `onInvalidate`) and cancelled when it detaches — same didSet idiom as
    /// `TerminalPiPFrameSource`'s ticker, for the same reason: the source must
    /// never keep doing work for a window that is gone.
    private var captureTask: Task<Void, Never>?
    /// Last successful capture. `renderFrame` blits this and nothing else, so
    /// it must survive pause, capture failures, and the web view going away.
    private var cachedImage: UIImage?
    /// When `cachedImage` was last replaced, stamped from the injected clock.
    /// Exposed so tests can assert the loop actually ran without reaching into
    /// the image itself.
    private(set) var lastCaptureAt: Date?
    /// Latched capture API for this attachment. Exposed for tests.
    private(set) var strategy: CaptureStrategy = .probing

    let restoreSessionID: UUID?

    /// Starting/stopping the capture loop follows the engine attaching
    /// (non-nil) and detaching (nil) this source.
    var onInvalidate: (() -> Void)? {
        didSet {
            if onInvalidate != nil { startCapturing() } else { stopCapturing() }
        }
    }

    /// Unwires preview plumbing when the engine drops this source.
    var onDetach: (() -> Void)?

    /// System pause: stop capturing, keep showing the last frame. Nothing to
    /// freeze explicitly — the cache *is* the frozen frame, and the capture
    /// loop checks this flag on every tick, so clearing it resumes following
    /// within one interval.
    var followSuspended: Bool = false

    convenience init(
        webView: WKWebView?,
        sessionID: UUID?,
        title: @escaping () -> String,
        subtitle: @escaping () -> String?,
        renderer: PreviewPiPSurfaceRenderer = PreviewPiPSurfaceRenderer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            resolveWebView: { [weak webView] in webView },
            sessionID: sessionID,
            title: title,
            subtitle: subtitle,
            renderer: renderer,
            now: now
        )
    }

    init(
        resolveWebView: @escaping () -> WKWebView?,
        sessionID: UUID?,
        title: @escaping () -> String,
        subtitle: @escaping () -> String?,
        renderer: PreviewPiPSurfaceRenderer = PreviewPiPSurfaceRenderer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.resolveWebView = resolveWebView
        self.restoreSessionID = sessionID
        self.title = title
        self.subtitle = subtitle
        self.renderer = renderer
        self.now = now
    }

    var preferredBufferSize: CGSize { renderer.size }

    /// No-op: this is an image source, like `VNCFrameSource`. A bigger PiP
    /// window shows the same page bigger, because a web page has no discrete
    /// unit to reveal more of — unlike the terminal, where more window height
    /// legitimately means more rows.
    func updateForRenderSize(_ size: CGSize) {}

    // MARK: - Capture loop

    /// Consecutive failed or blank captures after which the surface admits it
    /// is not tracking any more. ~1.5 s at the capture interval: long enough
    /// that a page repainting between frames never trips it, short enough that
    /// a user glancing at the window learns the truth quickly.
    private static let staleAfterFailures = 3
    /// How many times `takeSnapshot` may return nil before this environment is
    /// judged unable to vend snapshots at all. nil is a hard API failure — a
    /// real signal, unlike a uniform image, which is usually just a page that
    /// has not painted.
    private static let snapshotNilBudget = 3

    private var consecutiveFailures = 0
    private var snapshotNilCount = 0
    /// Bumped on every (re)attachment. A capture suspended across `await` can
    /// outlive the attachment that started it and land its verdict on the next
    /// one; the generation check is what stops a stale probe from writing a
    /// strategy measured against a different web view.
    private var generation = 0

    private func startCapturing() {
        guard captureTask == nil else { return }
        generation += 1
        // Re-probe on each fresh attachment: the web view (and the environment
        // it lives in) may not be the one the previous attachment measured.
        strategy = .probing
        snapshotNilCount = 0
        consecutiveFailures = 0
        let mine = generation
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Capture first, sleep after: the first frame should land as
                // fast as the API allows, not `captureInterval` late.
                await self.captureTick(generation: mine)
                try? await Task.sleep(for: .seconds(Self.captureInterval))
            }
        }
    }

    private func stopCapturing() {
        captureTask?.cancel()
        captureTask = nil
    }

    private func captureTick(generation mine: Int) async {
        guard !followSuspended else { return }
        let captured = await capture()
        // The attachment can end, or the user can hit pause, during the ~25 ms
        // the capture took. Neither result should land — and a result from a
        // previous attachment must never land at all.
        guard !Task.isCancelled, mine == generation, !followSuspended else { return }

        guard let image = captured else {
            consecutiveFailures += 1
            return
        }
        // A uniform frame arriving after a real one is usually a failed capture
        // (backgrounded window, WebContent process not vending pixels) rather
        // than a page that genuinely turned one flat colour, and a blank pop-out
        // reads as broken. But the filter is BOUNDED: a page that really is
        // blank — a crashed WebContent process, a dev server serving a white
        // "rebuilding" shell, `document.body.innerHTML = ''` — must eventually
        // be shown, because presenting a photograph of a page that no longer
        // exists as though it were live is worse than showing the blank truth.
        if cachedImage != nil, Self.isBlank(image), consecutiveFailures < Self.staleAfterFailures {
            consecutiveFailures += 1
            return
        }
        consecutiveFailures = 0
        cachedImage = image
        lastCaptureAt = now()
        onInvalidate?()
    }

    /// One capture, using the latched strategy — or choosing it.
    ///
    /// **The latch only ever fires on positive evidence.** An earlier version
    /// latched `.drawHierarchy` the first time `takeSnapshot` returned a blank
    /// image, which is exactly what a page that has not painted yet produces:
    /// tapping Pop Out while the dev server was still white would condemn the
    /// whole attachment to the 25 ms path even on hardware where `takeSnapshot`
    /// works perfectly. So a blank keeps us in `.probing` (using the fallback
    /// for that tick only), and only a *nil* — a hard API failure, repeated
    /// `snapshotNilBudget` times — demotes to `.drawHierarchy`.
    private func capture() async -> UIImage? {
        guard let webView, webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        // Off-window views have nothing to snapshot by either route, and a
        // probe taken there is guaranteed blank — which would mislatch.
        guard webView.window != nil else { return nil }

        // `drawHierarchy(afterScreenUpdates: true)` forces a screen update, and
        // a backgrounded app does not get one — so in the background it returns
        // a blank bitmap (and is a documented stall risk) no matter what the
        // latch says. Backgrounded is precisely the state this whole surface
        // exists for, so `takeSnapshot` is the only candidate there.
        let backgrounded = UIApplication.shared.applicationState != .active

        switch strategy {
        case .snapshot:
            return await snapshot(webView)

        case .drawHierarchy where !backgrounded:
            return drawHierarchySnapshot(webView)

        case .probing, .drawHierarchy:
            if let image = await snapshot(webView) {
                snapshotNilCount = 0
                if !Self.isBlank(image) {
                    strategy = .snapshot   // positive evidence, latch it
                    return image
                }
                // Uniform: could be a real blank page. Stay probing; prefer the
                // fallback's pixels this tick when we can get them.
                return backgrounded ? image : (drawHierarchySnapshot(webView) ?? image)
            }
            snapshotNilCount += 1
            if snapshotNilCount >= Self.snapshotNilBudget {
                strategy = .drawHierarchy
            }
            return backgrounded ? nil : drawHierarchySnapshot(webView)
        }
    }

    /// `takeSnapshot`, bounded.
    ///
    /// The timeout is not defensive padding: the page controls whether its
    /// WebContent process survives, and if WebKit drops the reply block instead
    /// of erroring it, an unbounded `withCheckedContinuation` suspends the
    /// capture loop *forever* — `cancel()` cannot resume a checked continuation,
    /// so `detach()` and `deinit` would both fail to stop anything and the
    /// source, its cached image and the web view would leak for the process
    /// lifetime. `PreviewScreen` implements `webViewWebContentProcessDidTerminate`
    /// precisely because that state is expected here.
    private func snapshot(_ webView: WKWebView) async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(snapshotPointWidth(for: webView)))
        let raw: UIImage? = await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    let once = OnceFlag()
                    webView.takeSnapshot(with: configuration) { image, _ in
                        // The error is not worth surfacing: the caller's only
                        // recourse is the fallback, which it takes on nil.
                        if once.trySet() { continuation.resume(returning: image) }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.captureInterval * 4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return raw.map(normalized)
    }

    /// The ~25 ms path. `afterScreenUpdates: true` is not optional here — the
    /// benchmark shows `false` returns a blank rectangle, because the web
    /// view's content is composited by another process and there is nothing in
    /// this process's layer tree to draw until the update is forced.
    private func drawHierarchySnapshot(_ webView: WKWebView) -> UIImage? {
        let bounds = webView.bounds
        let scale = min(1, snapshotPointWidth(for: webView) / bounds.width)
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        var drew = false
        let image = UIGraphicsImageRenderer(size: target, format: format).image { context in
            // Scale the CONTEXT and then draw the view at its natural bounds,
            // rather than passing a smaller rect to `drawHierarchy` and
            // trusting it to scale rather than crop. Whether that call scales
            // or clips is exactly the kind of undocumented detail that would
            // silently ship a pop-out showing only the page's top-left corner —
            // and only where the surface is narrower than the view, so `scale`
            // drops below 1. A context
            // transform has no such ambiguity.
            context.cgContext.scaleBy(x: scale, y: scale)
            drew = webView.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        // The Bool actually means something: false is "nothing was rendered",
        // which happens whenever the window cannot be updated. Discarding it
        // would cache a blank bitmap as though it were the page.
        return drew ? image : nil
    }

    /// Redraw at scale 1, sized for the surface.
    ///
    /// `snapshotWidth` is in POINTS and the returned image comes back at the
    /// window's scale, so asking for 480pt on a 3x phone yields a ~1440px-wide
    /// bitmap — roughly 12 MB retained, and a full Core Graphics downscale on
    /// the main actor for every frame the engine renders. That would put the
    /// per-frame cost straight back into `renderFrame`, which is the one thing
    /// this class is built to avoid. Normalising once per capture instead
    /// keeps the cache under a megabyte and makes the blit ~1:1.
    private func normalized(_ image: UIImage) -> UIImage {
        let maxWidth = renderer.size.width
        guard image.scale != 1 || image.size.width * image.scale > maxWidth else { return image }
        let ratio = min(1, maxWidth / (image.size.width * image.scale))
        let target = CGSize(
            width: (image.size.width * image.scale * ratio).rounded(),
            height: (image.size.height * image.scale * ratio).rounded()
        )
        guard target.width >= 1, target.height >= 1 else { return image }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// True when the image carries essentially no variation — the white/clear
    /// rectangle an out-of-process web view snapshot degrades to. Cheap by
    /// construction: the image is drawn once into a 24×24 buffer and only the
    /// min/max of one channel is compared, so this costs microseconds even for
    /// a full-resolution capture. Same approach (and same threshold) as
    /// `PreviewSnapshotBenchmarkTests`, so the shipped behaviour and the
    /// benchmark that justified it cannot drift apart. `static` so tests can
    /// call it directly.
    nonisolated static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let width = 24, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // The context, the draw, and the reads all live inside
        // `withUnsafeMutableBytes`. Passing `&pixels` to `CGContext(data:)` and
        // then using that context after the call returns is undefined
        // behaviour — the pointer is only guaranteed for the duration of the
        // call it is passed to — and it is the kind that works until an
        // optimiser change turns it into heap corruption or a garbage verdict.
        // Neither TerminalPiPFrameSource nor VNCFrameSource has this problem;
        // they draw into a CVPixelBuffer whose base address really is stable.
        return pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return true }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = raw.bindMemory(to: UInt8.self)
            var minLuma = 255, maxLuma = 0
            for index in stride(from: 0, to: width * height * 4, by: 4) {
                // Real luma across all three channels. Sampling byte 0 alone
                // reads only RED, so a page whose viewport is a blue or green
                // gradient has a constant R and reads as "blank" no matter how
                // much visible variation it has — which would mislatch the
                // capture strategy and then silently drop every frame.
                let luma = (299 * Int(bytes[index])
                            + 587 * Int(bytes[index + 1])
                            + 114 * Int(bytes[index + 2])) / 1000
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
            }
            return maxLuma - minLuma < 8
        }
    }

    // MARK: - PiPFrameSource

    func currentModel() -> PreviewPiPSurfaceModel {
        PreviewPiPSurfaceModel(
            title: title(),
            subtitle: subtitle(),
            paused: followSuspended,
            // Not tracking any more, and say so. The web view can vanish under
            // us — `PreviewScreen` rebuilds it when the console setting flips,
            // and "Done" tears the whole sheet (and the tunnel the subtitle
            // names) down while the pop-out is still up. Without this the
            // window would keep presenting the last captured frame, beside a
            // live-looking "localhost:5173", as if it were current: the user
            // watches a dead tunnel believing it is real. TerminalPiPFrameSource
            // handles the same case by degrading its chip to `.disconnected`.
            isStale: !followSuspended && (webView == nil || consecutiveFailures >= Self.staleAfterFailures),
            hasImage: cachedImage != nil
        )
    }

    /// Pure blit — no capture, no WebKit call. Everything expensive already
    /// happened on the capture loop.
    func renderFrame(into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        renderer.draw(currentModel(), image: cachedImage, into: pool)
    }

    func detach() {
        onInvalidate = nil   // didSet cancels the capture task
        onDetach?()
        onDetach = nil
    }

    deinit { captureTask?.cancel() }
}

/// What the preview pop-out shows — pure data, unit-testable without AVKit or
/// WebKit. Mirrors `TerminalPiPSurfaceModel`'s shape. `hasImage` rather than the
/// image itself so the model stays cheaply `Equatable`: the renderer takes the
/// image separately, and tests can assert the header/placeholder decision
/// without owning a `UIImage`.
struct PreviewPiPSurfaceModel: Equatable {
    var title: String
    /// The tunnel this is a view of, e.g. "localhost:5173". nil until bound.
    var subtitle: String?
    var paused: Bool
    /// Capture has stopped landing — the web view went away, or several
    /// consecutive attempts failed. Distinct from `paused`, which the user
    /// asked for and expects.
    var isStale: Bool = false
    var hasImage: Bool
}

/// Draws a preview surface into a 32BGRA pixel buffer: a header (title +
/// tunnel, plus the paused badge) above the captured page, aspect-fit.
struct PreviewPiPSurfaceRenderer {
    /// Purpose-built surface resolution, 4:3 landscape.
    ///
    /// `TerminalPiPSurfaceRenderer` deliberately went *portrait* (900×1200):
    /// its content is N text rows, so every extra vertical pixel is another
    /// row of information. That reasoning does not transfer. A web page here is
    /// a single image, aspect-fit — extra surface height buys letterboxing, not
    /// content, and a tall PiP window covers an unreasonable slice of whatever
    /// app the user switched to (the whole point of popping the preview out).
    ///
    /// 4:3 rather than 16:9 is the compromise between the two shapes this
    /// actually has to hold: a phone-width page (portrait, roughly 9:16, which
    /// letterboxes on the sides no matter what) and a desktop-layout page from
    /// the sheet's desktop-UA toggle (wide). At 16:9 the portrait case would be
    /// squeezed to ~540 px tall; 720 px keeps it readable while the window
    /// still reads as a landscape monitor rather than a column.
    var size = CGSize(width: 960, height: 720)

    func draw(_ model: PreviewPiPSurfaceModel, image: UIImage?, into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var leased: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &leased) == kCVReturnSuccess,
              let buffer = leased else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        // Pool buffers are recycled, not zeroed — clear the whole allocation
        // (row padding included) so identical models render identical bytes.
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
        // Flip into UIKit's top-left origin: both the string drawing and
        // `UIImage.draw(in:)` below assume it.
        context.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(buffer)))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawContent(model, image: image)
        return buffer
    }

    private func drawContent(_ model: PreviewPiPSurfaceModel, image: UIImage?) {
        let bounds = CGRect(origin: .zero, size: size)
        UIColor(white: 0.07, alpha: 1).setFill()
        UIRectFill(bounds)

        let headerHeight: CGFloat = 76
        let margin: CGFloat = 20

        UIColor(white: 0.12, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: headerHeight))

        // Paused badge, right-aligned and vertically centred in the header.
        var titleLimit = size.width - margin
        // Paused outranks stale: the user asked for paused and already knows
        // why the picture stopped moving.
        let badgeText = model.paused ? "Paused" : (model.isStale ? "Not updating" : nil)
        if let badgeText {
            let badgeColor = model.paused ? UIColor.systemYellow : UIColor.systemGray
            let badgeFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
            let textSize = (badgeText as NSString).size(withAttributes: [.font: badgeFont])
            let padding: CGFloat = 12
            let badge = CGRect(
                x: size.width - margin - textSize.width - padding * 2,
                y: (headerHeight - textSize.height - 10) / 2,
                width: textSize.width + padding * 2,
                height: textSize.height + 10
            )
            badgeColor.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: badge, cornerRadius: badge.height / 2).fill()
            (badgeText as NSString).draw(
                at: CGPoint(x: badge.minX + padding, y: badge.minY + 5),
                withAttributes: [.font: badgeFont, .foregroundColor: badgeColor]
            )
            titleLimit = badge.minX - 12
        }

        // Title over tunnel: two stacked lines, because the tunnel ("the port
        // I'm looking at") is the identity of this window and must not be the
        // thing that gets truncated away when the session name is long.
        let titleFont = UIFont.systemFont(ofSize: 27, weight: .semibold)
        let subtitleFont = UIFont.monospacedSystemFont(ofSize: 21, weight: .regular)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let textWidth = max(0, titleLimit - margin)
        let block = titleFont.lineHeight + (model.subtitle == nil ? 0 : subtitleFont.lineHeight + 2)
        var y = (headerHeight - block) / 2
        (model.title as NSString).draw(
            in: CGRect(x: margin, y: y, width: textWidth, height: titleFont.lineHeight),
            withAttributes: [
                .font: titleFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: truncating,
            ]
        )
        if let subtitle = model.subtitle {
            y += titleFont.lineHeight + 2
            (subtitle as NSString).draw(
                in: CGRect(x: margin, y: y, width: textWidth, height: subtitleFont.lineHeight),
                withAttributes: [
                    .font: subtitleFont,
                    .foregroundColor: UIColor(white: 0.72, alpha: 1),
                    .paragraphStyle: truncating,
                ]
            )
        }

        let body = CGRect(
            x: 0,
            y: headerHeight,
            width: size.width,
            height: size.height - headerHeight
        )
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(body.width / image.size.width, body.height / image.size.height)
            let fitted = CGRect(
                x: body.midX - image.size.width * scale / 2,
                y: body.midY - image.size.height * scale / 2,
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            image.draw(in: fitted)
            if model.isStale {
                // Dimmed, not hidden: the last frame is still the most useful
                // thing on screen, it just must not look current.
                UIColor(white: 0.07, alpha: 0.55).setFill()
                UIRectFill(fitted)
            }
        } else {
            // Never a nil frame just because the first capture hasn't landed:
            // the pop-out window appears the instant the user taps it, and an
            // empty black rectangle for the first half-second reads as a
            // crash. Header plus a placeholder is honest and immediate.
            let font = UIFont.systemFont(ofSize: 26, weight: .semibold)
            let text = "Waiting for preview…"
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            (text as NSString).draw(
                at: CGPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2),
                withAttributes: [.font: font, .foregroundColor: UIColor(white: 0.85, alpha: 1)]
            )
        }
    }
}
