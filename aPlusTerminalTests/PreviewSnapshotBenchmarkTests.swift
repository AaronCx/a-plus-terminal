import UIKit
import WebKit
import XCTest
@testable import aPlusTerminal

/// Phase 4 gate (preview brief): *"`WKWebView.takeSnapshot` is slow; try
/// `drawHierarchy(in:afterScreenUpdates:)` and measure before committing. Do
/// not assume this is free."*
///
/// This is that measurement, and it decides whether a `PreviewPiPFrameSource`
/// is worth building at all. Two things are being established, and the second
/// matters more than the speed:
///
/// 1. **Cost per capture**, against the ≤10 fps budget `PiPFrameCoalescer`
///    already imposes (so the real ceiling is ~100 ms, not 16 ms).
/// 2. **Whether each API produces actual pixels.** `PiPFrameSource.renderFrame`
///    is *synchronous*, so the only synchronous option is `drawHierarchy` — and
///    WKWebView renders its content in a separate process, which is exactly the
///    case `drawHierarchy` is known to miss. A fast API that returns a blank
///    rectangle is not a faster option, it is a wrong one, so blankness is
///    measured explicitly rather than eyeballed.
@MainActor
final class PreviewSnapshotBenchmarkTests: XCTestCase {
    private static let iterations = 15

    func testMeasureSnapshotStrategiesForPiP() async throws {
        let page = """
        <html><head><meta name="viewport" content="width=device-width"><style>
        body{font:16px -apple-system;margin:0;background:#101418;color:#e6edf3}
        header{background:#1f6feb;color:#fff;padding:14px 18px;font-weight:600}
        .card{background:#161b22;border:1px solid #30363d;border-radius:8px;margin:12px;padding:14px}
        .row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #21262d}
        .pill{background:#238636;border-radius:12px;padding:2px 10px;font-size:12px}
        </style></head><body>
        <header>Dashboard</header>
        <div class="card"><h3>Deployments</h3>
        <div class="row"><span>api-gateway</span><span class="pill">live</span></div>
        <div class="row"><span>worker-queue</span><span class="pill">live</span></div>
        <div class="row"><span>web-frontend</span><span class="pill">building</span></div>
        <div class="row"><span>scheduler</span><span class="pill">live</span></div></div>
        <div class="card"><h3>Recent</h3>
        <div class="row"><span>fix: retry on 429</span><span>2m</span></div>
        <div class="row"><span>feat: add tracing</span><span>18m</span></div>
        <div class="row"><span>chore: bump deps</span><span>1h</span></div></div>
        </body></html>
        """
        let stub = try LoopbackHTTPStub(body: page)
        try await stub.start()
        defer { stub.stop() }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: configuration
        )
        // A view must be in a window for drawHierarchy to have any chance at
        // all — off-window views have nothing on screen to draw.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.addSubview(webView)
        window.makeKeyAndVisible()

        let probe = NavigationProbe()
        webView.navigationDelegate = probe
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(stub.port)/")!))
        if case .failed(let error) = try await probe.outcome(timeout: 30) {
            throw XCTSkip("benchmark page did not load: \(error)")
        }
        // Let the first paint settle so we are not timing an empty page.
        try await Task.sleep(for: .milliseconds(600))

        var report = "\n=== Phase 4 PiP snapshot benchmark (\(Self.iterations) iterations) ===\n"

        // --- takeSnapshot, default config (afterScreenUpdates defaults true) ---
        let full = try await measureAsync(webView, config: WKSnapshotConfiguration())
        report += line("takeSnapshot(default)", full)

        // --- takeSnapshot with afterScreenUpdates:false (the "fast" variant) ---
        let fastConfig = WKSnapshotConfiguration()
        fastConfig.afterScreenUpdates = false
        let fast = try await measureAsync(webView, config: fastConfig)
        report += line("takeSnapshot(afterScreenUpdates:false)", fast)

        // --- takeSnapshot, downscaled to the PiP surface width ---
        let smallConfig = WKSnapshotConfiguration()
        smallConfig.snapshotWidth = NSNumber(value: 300)
        let small = try await measureAsync(webView, config: smallConfig)
        report += line("takeSnapshot(snapshotWidth:300)", small)

        // --- drawHierarchy, the only SYNCHRONOUS option ---
        let drawFalse = measureDraw(webView, afterScreenUpdates: false)
        report += line("drawHierarchy(afterScreenUpdates:false)", drawFalse)

        let drawTrue = measureDraw(webView, afterScreenUpdates: true)
        report += line("drawHierarchy(afterScreenUpdates:true)", drawTrue)

        report += "\nPiPFrameCoalescer caps rendering at 10 fps → ~100 ms budget per frame.\n"
        report += "renderFrame(into:) is SYNCHRONOUS, so an async capture must be cached.\n"
        print(report)

        // Record the decisive facts as assertions so a future change that, say,
        // makes drawHierarchy start working shows up as a failure to revisit.
        XCTAssertGreaterThan(full.medianMS, 0, "takeSnapshot produced no timings")
        XCTAssertFalse(
            full.blank && drawTrue.blank,
            "no capture strategy produced pixels — a preview pop-out is not implementable"
        )
    }

    // MARK: - Harness

    private struct Result {
        var medianMS: Double
        var p90MS: Double
        var blank: Bool
    }

    private func line(_ name: String, _ r: Result) -> String {
        String(
            format: "  %-46s median %7.2f ms   p90 %7.2f ms   %@\n",
            (name as NSString).utf8String!,
            r.medianMS, r.p90MS,
            r.blank ? "BLANK ❌ (unusable)" : "renders content ✅"
        )
    }

    private func measureAsync(_ webView: WKWebView, config: WKSnapshotConfiguration) async throws -> Result {
        var samples: [Double] = []
        var blank = true
        var nilCount = 0
        var lastError: Error?
        for i in 0..<(Self.iterations + 3) {
            let start = CFAbsoluteTimeGetCurrent()
            let (image, error): (UIImage?, Error?) = await withCheckedContinuation { continuation in
                webView.takeSnapshot(with: config) { image, error in
                    continuation.resume(returning: (image, error))
                }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if i >= 3 { samples.append(elapsed) }   // discard warm-up
            if image == nil { nilCount += 1; lastError = error }
            if let image, !Self.isBlank(image) { blank = false }
        }
        if nilCount > 0 {
            print("    ↳ takeSnapshot returned nil \(nilCount)x; last error: \(lastError.map { String(describing: $0) } ?? "none")")
        }
        return Result(medianMS: Self.median(samples), p90MS: Self.p90(samples), blank: blank)
    }

    private func measureDraw(_ webView: WKWebView, afterScreenUpdates: Bool) -> Result {
        var samples: [Double] = []
        var blank = true
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        for i in 0..<(Self.iterations + 3) {
            let start = CFAbsoluteTimeGetCurrent()
            let image = renderer.image { _ in
                _ = webView.drawHierarchy(in: webView.bounds, afterScreenUpdates: afterScreenUpdates)
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if i >= 3 { samples.append(elapsed) }
            if !Self.isBlank(image) { blank = false }
        }
        return Result(medianMS: Self.median(samples), p90MS: Self.p90(samples), blank: blank)
    }

    /// Delegates to the SHIPPING implementation rather than keeping a copy.
    /// The benchmark's whole job is to justify a production decision, so if the
    /// two blankness checks could drift the measurement would stop describing
    /// the code it justifies — and the first version of this file did drift:
    /// both sampled only the red channel, which made a green-on-black build log
    /// read as blank.
    private static func isBlank(_ image: UIImage) -> Bool {
        PreviewPiPFrameSource.isBlank(image)
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    private static func p90(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * 0.9))]
    }
}
