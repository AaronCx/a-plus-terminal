import CoreVideo
import SwiftTerm
import UIKit

/// The state chip on the pop-out surface.
enum PiPSessionChip: Equatable {
    case running
    case waitingForInput
    case disconnected

    var label: String {
        switch self {
        case .running: return "Running"
        case .waitingForInput: return "Waiting for input"
        case .disconnected: return "Disconnected"
        }
    }

    var color: UIColor {
        switch self {
        case .running: return .systemGreen
        case .waitingForInput: return .systemOrange
        case .disconnected: return .systemGray
        }
    }

    /// Session state + agent heuristic → chip. Anything not connected reads
    /// "disconnected"; a connected session surfaces the agent's waiting state.
    static func from(state: SessionState, agentStatus: AgentActivityMonitor.Status) -> PiPSessionChip {
        guard state == .connected else { return .disconnected }
        return agentStatus == .waiting ? .waitingForInput : .running
    }
}

/// What the pop-out surface shows — pure data, unit-testable without AVKit.
struct TerminalPiPSurfaceModel: Equatable {
    var title: String
    var chip: PiPSessionChip
    var rows: [String]
    var paused: Bool
}

/// Last-N-rows extraction from the emulator's visible grid.
enum TerminalTailWindow {
    /// The row range to show: the last `tail` rows ending at the cursor row
    /// in the primary buffer (skipping the blank rows below a short
    /// transcript), or the bottom `tail` rows of the grid in the alternate
    /// buffer (full-screen apps draw the whole grid, so the bottom rows are
    /// where the action is regardless of cursor parking).
    static func range(rows: Int, cursorRow: Int, isAlternate: Bool, tail: Int) -> Range<Int> {
        guard rows > 0, tail > 0 else { return 0..<0 }
        let end = isAlternate ? rows - 1 : min(max(cursorRow, 0), rows - 1)
        let start = max(0, end - tail + 1)
        return start..<(end + 1)
    }

    /// Read the window's text out of the emulator, NULs spaced and trailing
    /// padding trimmed.
    @MainActor
    static func text(from terminal: Terminal, tail: Int) -> [String] {
        let window = range(
            rows: terminal.rows,
            cursorRow: terminal.buffer.y,
            isAlternate: terminal.isCurrentBufferAlternate,
            tail: tail
        )
        return window.map { row in
            guard let line = terminal.getLine(row: row) else { return "" }
            var text = ""
            for col in 0..<terminal.cols {
                text.append(line[col].getCharacter())
            }
            let spaced = text.replacingOccurrences(of: "\0", with: " ")
            return String(spaced.reversed().drop(while: { $0 == " " }).reversed())
        }
    }
}

/// Renders the tail of a terminal session for the PiP window. Deliberately
/// decoupled from `TerminalSession`: it reads an emulator view directly and
/// pulls the title/state through closures, so unit tests drive it with a bare
/// emulator and no SSH stack (PiPCoordinator does the session wiring).
@MainActor
final class TerminalPiPFrameSource: PiPFrameSource {
    /// Default tail row count (brief §3.2 assumption — Aaron may retune).
    nonisolated static let defaultTailRows = 14

    private weak var terminalView: TerminalEmulatorView?
    private let title: () -> String
    private let chip: () -> PiPSessionChip
    /// Baseline rows shown at the default PiP window size; the effective
    /// count grows with the window (see updateForRenderSize).
    private let baseTailRows: Int
    /// Current tail row count — adapts to the PiP window height so a bigger
    /// window reveals MORE of the terminal instead of magnifying the same
    /// rows (field feedback).
    private var tailRows: Int
    private let renderer: TerminalPiPSurfaceRenderer
    /// Rows captured at the moment the user hit pause; nil while following.
    private var frozenRows: [String]?

    let restoreSessionID: UUID?
    var onInvalidate: (() -> Void)?
    /// Unwires session plumbing when the engine drops this source.
    var onDetach: (() -> Void)?

    var followSuspended: Bool = false {
        didSet {
            guard followSuspended != oldValue else { return }
            frozenRows = followSuspended ? currentModel().rows : nil
        }
    }

    init(
        terminalView: TerminalEmulatorView?,
        sessionID: UUID?,
        title: @escaping () -> String,
        chip: @escaping () -> PiPSessionChip,
        tailRows: Int = TerminalPiPFrameSource.defaultTailRows,
        renderer: TerminalPiPSurfaceRenderer = TerminalPiPSurfaceRenderer()
    ) {
        self.terminalView = terminalView
        self.restoreSessionID = sessionID
        self.title = title
        self.chip = chip
        self.baseTailRows = tailRows
        self.tailRows = tailRows
        self.renderer = renderer
    }

    var preferredBufferSize: CGSize { renderer.size }

    /// The PiP window's surface (buffer) aspect is fixed, so growing the
    /// window uniformly scales the buffer. To reveal MORE rows in a bigger
    /// window we render MORE rows into that same buffer — they draw smaller
    /// but the enlarged window keeps them legible. Rows scale with the
    /// window's longer dimension, floored at the baseline and capped at what
    /// the terminal actually has.
    func updateForRenderSize(_ size: CGSize) {
        let reference: CGFloat = 300   // ~default PiP long-edge in points
        let longEdge = max(size.width, size.height)
        guard longEdge > 0 else { return }
        let scaled = Int((CGFloat(baseTailRows) * longEdge / reference).rounded())
        let available = terminalView.map { $0.getTerminal().rows } ?? scaled
        tailRows = min(max(scaled, baseTailRows), max(baseTailRows, available))
    }

    func currentModel() -> TerminalPiPSurfaceModel {
        let rows: [String]
        if let frozenRows {
            rows = frozenRows
        } else if let terminalView {
            rows = TerminalTailWindow.text(from: terminalView.getTerminal(), tail: tailRows)
        } else {
            rows = []
        }
        return TerminalPiPSurfaceModel(
            title: title(),
            chip: terminalView == nil ? .disconnected : chip(),
            rows: rows,
            paused: frozenRows != nil
        )
    }

    func renderFrame(into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        renderer.draw(currentModel(), into: pool)
    }

    func detach() {
        onInvalidate = nil
        onDetach?()
        onDetach = nil
    }
}

/// Draws a surface model into a 32BGRA pixel buffer: a header row (title +
/// state chip, plus the paused badge) above the tail rows, monospaced.
struct TerminalPiPSurfaceRenderer {
    /// Purpose-built surface resolution. Taller than wide (3:4) so the PiP
    /// window is a tall strip that fits many terminal rows — the terminal
    /// pop-out was previously a 960×600 landscape that showed only a handful
    /// of magnified rows (field feedback).
    var size = CGSize(width: 900, height: 1200)

    func draw(_ model: TerminalPiPSurfaceModel, into pool: CVPixelBufferPool) -> CVPixelBuffer? {
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
        // Flip into UIKit's top-left origin for string drawing.
        context.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(buffer)))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawContent(model)
        return buffer
    }

    private func drawContent(_ model: TerminalPiPSurfaceModel) {
        let bounds = CGRect(origin: .zero, size: size)
        UIColor(white: 0.07, alpha: 1).setFill()
        UIRectFill(bounds)

        let headerHeight: CGFloat = 64
        let margin: CGFloat = 20

        // Header background.
        UIColor(white: 0.12, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: headerHeight))

        // Title, truncated from the tail.
        let titleFont = UIFont.monospacedSystemFont(ofSize: 26, weight: .semibold)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.white,
            .paragraphStyle: titleStyle,
        ]
        let chipFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let chipText = model.paused ? "Paused" : model.chip.label
        let chipColor = model.paused ? UIColor.systemYellow : model.chip.color
        let chipSize = (chipText as NSString).size(withAttributes: [.font: chipFont])
        let chipPadding: CGFloat = 12
        let chipWidth = chipSize.width + chipPadding * 2
        let titleRect = CGRect(
            x: margin,
            y: (headerHeight - titleFont.lineHeight) / 2,
            width: size.width - margin * 3 - chipWidth,
            height: titleFont.lineHeight
        )
        (model.title as NSString).draw(in: titleRect, withAttributes: titleAttributes)

        // State chip, right-aligned.
        let chipRect = CGRect(
            x: size.width - margin - chipWidth,
            y: (headerHeight - chipSize.height - 10) / 2,
            width: chipWidth,
            height: chipSize.height + 10
        )
        let chipPath = UIBezierPath(roundedRect: chipRect, cornerRadius: chipRect.height / 2)
        chipColor.withAlphaComponent(0.25).setFill()
        chipPath.fill()
        (chipText as NSString).draw(
            at: CGPoint(x: chipRect.minX + chipPadding, y: chipRect.minY + 5),
            withAttributes: [.font: chipFont, .foregroundColor: chipColor]
        )

        // Tail rows fill the rest, sized so the configured tail always fits.
        let bodyTop = headerHeight + 10
        let bodyHeight = size.height - bodyTop - 10
        let rowCount = max(model.rows.count, 1)
        let rowHeight = bodyHeight / CGFloat(rowCount)
        let rowFont = UIFont.monospacedSystemFont(ofSize: min(rowHeight * 0.68, 30), weight: .regular)
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.lineBreakMode = .byTruncatingTail
        let rowAttributes: [NSAttributedString.Key: Any] = [
            .font: rowFont,
            .foregroundColor: UIColor(white: 0.92, alpha: 1),
            .paragraphStyle: rowStyle,
        ]
        for (index, row) in model.rows.enumerated() {
            let rect = CGRect(
                x: margin,
                y: bodyTop + CGFloat(index) * rowHeight + (rowHeight - rowFont.lineHeight) / 2,
                width: size.width - margin * 2,
                height: rowFont.lineHeight
            )
            (row as NSString).draw(in: rect, withAttributes: rowAttributes)
        }
    }
}
