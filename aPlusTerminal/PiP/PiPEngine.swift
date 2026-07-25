import AVFoundation
import AVKit
import CoreMedia
import os
import UIKit

/// 32BGRA, IOSurface-backed pixel-buffer pool for PiP surfaces. IOSurface
/// backing is mandatory for buffers wrapped into CMSampleBuffers headed for
/// an AVSampleBufferDisplayLayer.
enum PiPPixelBufferPool {
    static func make(size: CGSize) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        return status == kCVReturnSuccess ? pool : nil
    }
}

/// App-scoped Picture-in-Picture engine: one AVSampleBufferDisplayLayer fed
/// by a `PiPFrameSource` at a debounced ≤10 fps, presented as live video (no
/// scrubber). Constructed only when the Pop-Out setting is ON and the device
/// supports PiP, so the feature leaves zero footprint otherwise.
///
/// Review guardrails baked in (brief §5): PiP starts only from `start()`
/// (the toolbar tap) or the system's auto-inline flag; the audio session is
/// touched exclusively between willStart and didStop.
@MainActor
final class PiPEngine: NSObject {
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private let log = Logger(subsystem: "com.aaroncx.aplusterminal", category: "pip")
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let coalescer: PiPFrameCoalescer
    private var controller: AVPictureInPictureController?
    private var containerView: UIView?
    private var pool: CVPixelBufferPool?
    private var possibleObservation: NSKeyValueObservation?
    private(set) var source: (any PiPFrameSource)?

    private(set) var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            onActiveChanged?(isActive)
        }
    }
    var onActiveChanged: ((Bool) -> Void)?
    /// Present session X's screen; the engine completes the system restore
    /// transaction right after this returns.
    var onRestore: ((UUID) -> Void)?

    init(minFrameInterval: TimeInterval = 0.1) {
        self.coalescer = PiPFrameCoalescer(minInterval: minFrameInterval)
        super.init()
        coalescer.render = { [weak self] in self?.renderAndEnqueue() }
    }

    /// Attach a source and stand the PiP controller up so a start — the
    /// toolbar tap or the system's auto-inline path — can succeed.
    func arm(source newSource: any PiPFrameSource, autoStartOnAppSwitch: Bool) {
        guard Self.isSupported else { return }
        // PiP eligibility keys off the audio session CATEGORY: with the
        // default .soloAmbient in force, isPictureInPicturePossible stays
        // false and startPictureInPicture() is a silent no-op (no delegate
        // callback owed — the build-31 field bug). Setting the category is
        // inert (nothing is interrupted until setActive, which stays in
        // willStart), so the "session active only while PiP is live"
        // guardrail holds.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        } catch {
            log.error("pip: setCategory at arm failed: \(error.localizedDescription, privacy: .public)")
        }
        if let source, source !== newSource {
            source.detach()
        }
        source = newSource
        newSource.onInvalidate = { [weak self] in self?.coalescer.invalidate() }
        if pool == nil || newSource.preferredBufferSize != poolSize {
            pool = PiPPixelBufferPool.make(size: newSource.preferredBufferSize)
            poolSize = newSource.preferredBufferSize
        }
        installContainerIfNeeded()
        if controller == nil {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.delegate = self
            // Live monitor: play/pause only, no skip chrome.
            controller.requiresLinearPlayback = true
            self.controller = controller
        }
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStartOnAppSwitch
        coalescer.renderNow()
    }

    /// User-initiated start (the toolbar tap). `isPictureInPicturePossible`
    /// flips true a beat after the layer first renders, so a not-yet-possible
    /// start waits for that flip instead of failing.
    func start() {
        guard let controller, !isActive else { return }
        coalescer.renderNow()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] controller, change in
                guard change.newValue == true else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isActive else { return }
                    self.possibleObservation = nil
                    controller.startPictureInPicture()
                }
            }
        }
    }

    func stop() {
        possibleObservation = nil
        controller?.stopPictureInPicture()
    }

    /// Drop the source (screen left, feature disarmed). No-op while active —
    /// the pop-out keeps rendering until the user dismisses it.
    func disarm() {
        guard !isActive else { return }
        possibleObservation = nil
        coalescer.cancel()
        source?.detach()
        source = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
    }

    /// Full teardown (master toggle turned off): stop if needed and release
    /// every AVKit object so nothing observable remains.
    func invalidate() {
        possibleObservation = nil
        if isActive {
            controller?.stopPictureInPicture()
        }
        coalescer.cancel()
        source?.detach()
        source = nil
        controller?.contentSource = nil
        controller = nil
        containerView?.removeFromSuperview()
        containerView = nil
        pool = nil
        poolSize = nil
        if isActive {
            deactivateAudioSession()
            isActive = false
        }
    }

    // MARK: - Frames

    private var poolSize: CGSize?

    private func renderAndEnqueue() {
        guard let source, let pool else { return }
        guard let pixelBuffer = source.renderFrame(into: pool) else { return }
        enqueue(pixelBuffer)
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        // The layer-level enqueue/flush/status surface is deprecated as of
        // iOS 18; the renderer is the supported path and its status/flush
        // recover decoder loss after backgrounding.
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        guard let sample = Self.makeSampleBuffer(for: pixelBuffer) else {
            log.error("pip: sample buffer creation failed")
            return
        }
        renderer.enqueue(sample)
    }

    static func makeSampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        // Per-sample attachment (the CMSampleAttachmentKey contract): display
        // as soon as enqueued — the surface is a live monitor, not a stream.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    // MARK: - Layer hosting

    /// PiP will not start from a detached layer: the hosting view sits in the
    /// key window's layer tree — behind the opaque root UI at near-zero
    /// alpha, untouchable and invisible.
    private func installContainerIfNeeded() {
        guard containerView == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.keyWindow
            ?? scenes.first?.windows.first else {
            log.error("pip: no window to host the display layer")
            return
        }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 150))
        container.isUserInteractionEnabled = false
        container.alpha = 0.02
        displayLayer.frame = container.bounds
        displayLayer.videoGravity = .resizeAspect
        container.layer.addSublayer(displayLayer)
        window.insertSubview(container, at: 0)
        containerView = container
    }

    // MARK: - Audio session

    /// Category `.playback` (set at arm — a PiP-eligibility precondition)
    /// marks the app as media-playing so the pop-out keeps running in the
    /// background; `.mixWithOthers` so the user's music is never
    /// interrupted. ACTIVATION happens only here, between willStart and
    /// didStop (brief §3.2/§5) — the "engine never constructed when the
    /// toggle is off" guarantee plus this pairing keeps the audio session
    /// untouched outside a live pop-out.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            log.info("pip: audio session activated (.playback, .mixWithOthers)")
        } catch {
            log.error("pip: audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            log.info("pip: audio session deactivated")
        } catch {
            log.error("pip: audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
//
// AVKit delivers both delegates on the main queue; `nonisolated` +
// `MainActor.assumeIsolated` bridges that guarantee into the engine's
// main-actor isolation (the SessionIO precedent).

extension PiPEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            activateAudioSession()
            coalescer.renderNow()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = true
            log.info("pip: started")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            log.error("pip: failed to start: \(message, privacy: .public)")
            deactivateAudioSession()
            isActive = false
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            deactivateAudioSession()
            source?.followSuspended = false
            isActive = false
            log.info("pip: stopped")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            if let sessionID = source?.restoreSessionID {
                onRestore?(sessionID)
            }
            completionHandler(true)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPEngine: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            // System pause = freeze the tail; the engine keeps rendering so
            // the paused badge and resume are instant. Play resumes following.
            source?.followSuspended = !playing
            coalescer.renderNow()
            pictureInPictureController.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Effectively infinite: presents as live, no scrubber.
        CMTimeRange(start: .negativeInfinity, end: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated {
            source?.followSuspended ?? false
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        MainActor.assumeIsolated {
            // Let the source reveal more content in a bigger window (terminal
            // rows) rather than only magnifying; then re-render at the new
            // scale.
            source?.updateForRenderSize(CGSize(width: CGFloat(newRenderSize.width),
                                               height: CGFloat(newRenderSize.height)))
            coalescer.renderNow()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // requiresLinearPlayback hides skip controls; if the system still
        // asks, complete immediately so its UI never sticks in "seeking".
        completionHandler()
    }
}
