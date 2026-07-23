import Foundation

/// Debounces frame invalidations: a burst of terminal output coalesces into
/// at most one render per `minInterval` (default 100 ms — a hard 10 fps cap),
/// while a lone invalidation still renders promptly.
@MainActor
final class PiPFrameCoalescer {
    private let minInterval: TimeInterval
    private var pending: Task<Void, Never>?
    private var lastRenderAt: Date?

    /// The actual render work; assigned by the engine.
    var render: (() -> Void)?

    init(minInterval: TimeInterval = 0.1) {
        self.minInterval = minInterval
    }

    /// Content changed: schedule a render no sooner than `minInterval` after
    /// the previous one. Calls arriving while one is scheduled coalesce.
    func invalidate() {
        guard pending == nil else { return }
        let wait = lastRenderAt.map { max(0, minInterval - Date().timeIntervalSince($0)) } ?? 0
        pending = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.fire()
        }
    }

    /// Immediate render outside the debounce (PiP start, render-size change).
    /// Resets the pacing clock so a burst right after still coalesces.
    func renderNow() {
        pending?.cancel()
        pending = nil
        fire()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func fire() {
        lastRenderAt = Date()
        render?()
    }
}
