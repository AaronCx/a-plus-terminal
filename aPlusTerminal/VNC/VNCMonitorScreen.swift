import SwiftUI
import UIKit

/// Full-screen monitor of a remote screen: pinch-zoom/pan canvas, state
/// overlays, pop-out button — plus opt-in Control mode (tap = click, drag =
/// drag, long-press = right-click, keyboard sheet) with a client-rendered
/// cursor. Presented as a full-screen cover so the terminal tab's
/// NavigationStack (and its delicate tab-bar ownership) stays untouched.
struct VNCMonitorScreen: View {
    @Environment(VNCMonitorManager.self) private var vncManager
    @Environment(PiPCoordinator.self) private var pip
    @Environment(\.dismiss) private var dismiss

    let session: VNCMonitorSession

    @State private var showKeyboard = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VNCFramebufferCanvas(session: session)
                    .ignoresSafeArea(edges: .bottom)

                switch session.state {
                case .idle, .connecting:
                    statusCard {
                        ProgressView("Connecting to \(session.server.name)…")
                    }
                case .authenticating:
                    statusCard {
                        ProgressView("Authenticating…")
                    }
                case .reconnecting:
                    statusCard {
                        ProgressView("Reconnecting…")
                    }
                case .suspended:
                    VNCStateCard(
                        systemImage: "pause.circle.fill",
                        title: "Monitor Paused",
                        message: "The connection was closed while the app was in the background.",
                        primaryLabel: "Reconnect",
                        onPrimary: { session.retry() },
                        onClose: { closeSession() }
                    )
                case .failed(let message):
                    VNCStateCard(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Connection Failed",
                        message: message,
                        primaryLabel: "Retry",
                        onPrimary: { session.retry() },
                        onClose: { closeSession() }
                    )
                case .connected, .closed:
                    EmptyView()
                }
            }
            .navigationTitle(session.server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if session.state == .connected {
                    // Control mode: forwards your taps/keys to the host.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            session.setControlEnabled(!session.controlEnabled)
                        } label: {
                            Image(systemName: session.controlEnabled
                                ? "cursorarrow.motionlines"
                                : "cursorarrow.slash")
                        }
                        .accessibilityLabel(session.controlEnabled
                            ? "Disable Control (back to view-only)"
                            : "Enable Control")
                    }
                    if session.controlEnabled {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showKeyboard = true
                            } label: {
                                Image(systemName: "keyboard")
                            }
                            .accessibilityLabel("Type on the Host")
                        }
                    }
                }
                if pip.isAvailable && session.state == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            pip.popOut(vnc: session)
                        } label: {
                            Image(systemName: "pip.enter")
                        }
                        .accessibilityLabel("Pop Out Monitor")
                    }
                }
            }
            .sheet(isPresented: $showKeyboard) {
                VNCKeyboardSheet(session: session)
                    .presentationDetents([.height(280)])
            }
            .onAppear { pip.vncScreenAppeared(session) }
            .onDisappear { pip.vncScreenDisappeared(session) }
        }
    }

    private func closeSession() {
        vncManager.close(session)
        dismiss()
    }

    private func statusCard(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Failure/paused card matching the terminal screen's card treatment.
private struct VNCStateCard: View {
    let systemImage: String
    let title: String
    let message: String
    let primaryLabel: String
    var onPrimary: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Close", role: .cancel, action: onClose)
                    .buttonStyle(.bordered)
                Button(primaryLabel, action: onPrimary)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
    }
}

/// Text entry forwarded to the host — the way past a locked Mac's password
/// field from the phone. Secure by default (passwords are the primary use).
private struct VNCKeyboardSheet: View {
    let session: VNCMonitorSession

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var secure = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Type on \(session.server.name)")
                .font(.headline)
            HStack {
                Group {
                    if secure {
                        SecureField("Text to send", text: $text)
                    } else {
                        TextField("Text to send", text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { sendWithReturn() }
                Button {
                    secure.toggle()
                    // Swapping SecureField/TextField drops first-responder;
                    // re-focus so typing continues uninterrupted.
                    focused = true
                } label: {
                    Image(systemName: secure ? "eye.slash" : "eye")
                }
                .accessibilityLabel(secure ? "Show text" : "Hide text")
            }
            HStack(spacing: 10) {
                Button("Send") { send(appendReturn: false) }
                    .buttonStyle(.bordered)
                    .disabled(text.isEmpty)
                Button("Send + Return") { sendWithReturn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
            HStack(spacing: 10) {
                Button("Esc") { session.sendSpecialKey(.escape) }
                Button("Tab") { session.sendSpecialKey(.tab) }
                Button("Delete") { session.sendSpecialKey(.delete) }
                Button("Return") { session.sendSpecialKey(.return) }
            }
            .buttonStyle(.bordered)
            .font(.callout)
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func sendWithReturn() {
        send(appendReturn: true)
    }

    private func send(appendReturn: Bool) {
        guard !text.isEmpty else { return }
        session.sendText(text)
        if appendReturn {
            session.sendSpecialKey(.return)
        }
        text = ""
    }
}

/// UIScrollView-hosted canvas showing the latest remote frame, with the
/// client-rendered cursor overlay and (in Control mode) tap/drag/long-press
/// forwarding. View-only unless the session's Control mode is enabled.
struct VNCFramebufferCanvas: UIViewRepresentable {
    let session: VNCMonitorSession

    func makeUIView(context: Context) -> VNCCanvasScrollView {
        let view = VNCCanvasScrollView()
        view.onPointer = { [weak session] action, point in
            session?.sendPointer(action, at: point)
        }
        view.onTap = { [weak session] point in
            session?.sendTap(at: point)
        }
        return view
    }

    func updateUIView(_ view: VNCCanvasScrollView, context: Context) {
        view.display(
            frame: session.lastFrame,
            size: session.framebufferSize,
            cursor: VNCCanvasScrollView.CursorState(
                shape: session.cursorShape,
                hotspot: session.cursorHotspot,
                position: session.cursorPosition
            ),
            controlEnabled: session.controlEnabled
        )
    }
}

final class VNCCanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    struct CursorState {
        var shape: CGImage?
        var hotspot: CGPoint
        var position: CGPoint?
    }

    /// Pointer events mapped to framebuffer pixels (Control mode only).
    var onPointer: ((VNCPointerAction, CGPoint) -> Void)?
    var onTap: ((CGPoint) -> Void)?

    private let imageView = UIView()
    private let cursorLayer = CALayer()
    private var contentSizeSet = false
    private var framebufferSize: CGSize = .zero
    private var cursor = CursorState(shape: nil, hotspot: .zero, position: nil)
    private var controlEnabled = false
    /// True between our leftDown and leftUp — the release must fire exactly
    /// once even across off-content exits and gesture cancellation.
    private var dragButtonHeld = false

    private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    private lazy var longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    private lazy var dragRecognizer: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        pan.maximumNumberOfTouches = 1
        return pan
    }()

    /// Default arrow drawn once — shown until the server sends a shape
    /// (macOS Screen Sharing never does; probe-verified).
    private static let defaultArrow: CGImage? = {
        let size = CGSize(width: 12, height: 19)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return format
        }())
        return renderer.image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 16))
            path.addLine(to: CGPoint(x: 4, y: 12.5))
            path.addLine(to: CGPoint(x: 7, y: 19))
            path.addLine(to: CGPoint(x: 9.5, y: 17.8))
            path.addLine(to: CGPoint(x: 6.5, y: 11.5))
            path.addLine(to: CGPoint(x: 11.5, y: 11))
            path.close()
            UIColor.black.setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }.cgImage
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        imageView.layer.contentsGravity = .resizeAspect
        imageView.layer.contentsScale = 1
        // Linear, not trilinear: trilinear regenerates a full mip chain for
        // the (large) remote-screen texture on EVERY frame.
        imageView.layer.minificationFilter = .linear
        imageView.layer.magnificationFilter = .linear
        addSubview(imageView)
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        imageView.layer.addSublayer(cursorLayer)

        tapRecognizer.delegate = self
        longPressRecognizer.delegate = self
        dragRecognizer.delegate = self
        imageView.addGestureRecognizer(tapRecognizer)
        imageView.addGestureRecognizer(longPressRecognizer)
        imageView.addGestureRecognizer(dragRecognizer)
        imageView.isUserInteractionEnabled = true
        setControlRecognizers(enabled: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !contentSizeSet || zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
            contentSizeSet = true
        }
        // Rotation/size changes arrive without a new frame — the overlay
        // must re-map or it drifts (review finding).
        layoutCursor()
    }

    func display(frame: CGImage?, size: CGSize, cursor: CursorState, controlEnabled: Bool) {
        imageView.layer.contents = frame
        framebufferSize = size
        self.cursor = cursor
        if self.controlEnabled != controlEnabled {
            self.controlEnabled = controlEnabled
            setControlRecognizers(enabled: controlEnabled)
        }
        layoutCursor()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    // MARK: - Control gestures

    /// In Control mode a single finger belongs to the host (tap/drag); the
    /// canvas itself pans with two fingers. View-only restores one-finger
    /// panning.
    private func setControlRecognizers(enabled: Bool) {
        tapRecognizer.isEnabled = enabled
        longPressRecognizer.isEnabled = enabled
        dragRecognizer.isEnabled = enabled
        panGestureRecognizer.minimumNumberOfTouches = enabled ? 2 : 1
    }

    private func framebufferPoint(for gesture: UIGestureRecognizer) -> CGPoint? {
        VNCPointMapping.framebufferPoint(
            from: gesture.location(in: imageView),
            content: framebufferSize,
            container: imageView.bounds.size
        )
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let point = framebufferPoint(for: gesture) else { return }
        onTap?(point)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let point = framebufferPoint(for: gesture) else { return }
            // A held touch is a right-click, never also a drag: cancel the
            // pan (disable/enable resets its tracking) so "hold then move"
            // can't chase the right-click with a left-drag through the
            // just-opened context menu (review finding). Movement before
            // the hold threshold fails the long-press naturally, so real
            // drags are unaffected.
            dragRecognizer.isEnabled = false
            onPointer?(.move, point)
            onPointer?(.rightClick, point)
        case .ended, .cancelled, .failed:
            dragRecognizer.isEnabled = controlEnabled
        default:
            break
        }
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        guard let point = framebufferPoint(for: gesture) else {
            if dragButtonHeld, gesture.state == .ended || gesture.state == .cancelled {
                // Finger left the content mid-drag: release where we last were.
                dragButtonHeld = false
                onPointer?(.leftUp, cursor.position ?? .zero)
            }
            return
        }
        switch gesture.state {
        case .began:
            dragButtonHeld = true
            onPointer?(.move, point)
            onPointer?(.leftDown, point)
        case .changed:
            onPointer?(.move, point)
        case .ended, .cancelled:
            // Guarded so a cancel arriving after an off-content release (or
            // the long-press disabling us) can never double-release or
            // strand a phantom up-event.
            if dragButtonHeld {
                dragButtonHeld = false
                onPointer?(.leftUp, point)
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Tap + long-press can coexist; the one-finger drag must not fight
        // the two-finger scroll pan.
        !(gestureRecognizer === dragRecognizer && other === panGestureRecognizer)
    }

    // MARK: - Cursor overlay

    private func layoutCursor() {
        guard let position = cursor.position, framebufferSize.width > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let container = imageView.bounds.size
        let scale = VNCPointMapping.fitScale(content: framebufferSize, in: container)
        let shape = cursor.shape ?? Self.defaultArrow
        guard let shape, scale > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let anchor = VNCPointMapping.viewPoint(
            from: position, content: framebufferSize, container: container
        )
        // Server shapes are framebuffer pixels — scale them through the
        // fitted rect like any content. Our fallback arrow is a UI affordance
        // and draws at a FIXED view-point size: framebuffer-scaling it made
        // it ~3pt tall on a 1920px-wide desktop, imperceptible (review
        // finding — the field symptom that started all of this).
        let size: CGSize
        let hotspotOffset: CGPoint
        if cursor.shape != nil {
            size = CGSize(width: CGFloat(shape.width) * scale, height: CGFloat(shape.height) * scale)
            hotspotOffset = CGPoint(x: cursor.hotspot.x * scale, y: cursor.hotspot.y * scale)
        } else {
            size = CGSize(width: 14, height: 22)
            hotspotOffset = .zero
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = shape
        cursorLayer.frame = CGRect(
            x: anchor.x - hotspotOffset.x,
            y: anchor.y - hotspotOffset.y,
            width: size.width,
            height: size.height
        )
        cursorLayer.isHidden = false
        CATransaction.commit()
    }
}
