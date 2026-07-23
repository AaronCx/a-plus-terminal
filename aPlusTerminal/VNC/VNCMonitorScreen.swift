import SwiftUI
import UIKit

/// Full-screen view-only monitor of a remote screen: pinch-zoom/pan canvas,
/// state overlays, pop-out button. Presented as a full-screen cover so the
/// terminal tab's NavigationStack (and its delicate tab-bar ownership) stays
/// untouched.
struct VNCMonitorScreen: View {
    @Environment(VNCMonitorManager.self) private var vncManager
    @Environment(PiPCoordinator.self) private var pip
    @Environment(\.dismiss) private var dismiss

    let session: VNCMonitorSession

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

/// UIScrollView-hosted canvas showing the latest remote frame. Strictly
/// view-only: the scroll view only zooms and pans locally; no gesture is
/// ever forwarded to the host (there is no input path to forward into —
/// the connection is opened with input disabled).
struct VNCFramebufferCanvas: UIViewRepresentable {
    let session: VNCMonitorSession

    func makeUIView(context: Context) -> VNCCanvasScrollView {
        VNCCanvasScrollView()
    }

    func updateUIView(_ view: VNCCanvasScrollView, context: Context) {
        view.display(frame: session.lastFrame, size: session.framebufferSize)
    }
}

final class VNCCanvasScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIView()
    private var contentSizeSet = false

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
        // Trilinear keeps downscaled text legible (vendor demo setting).
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        addSubview(imageView)
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
    }

    func display(frame: CGImage?, size: CGSize) {
        imageView.layer.contents = frame
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}
