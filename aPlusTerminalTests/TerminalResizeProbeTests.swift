import UIKit
import XCTest
@testable import aPlusTerminal

/// Does SwiftTerm's emulator actually follow its view's height?
///
/// Everything about the "terminal stops filling the screen" bug hinges on this and it
/// was never checked. The app reads `terminal.rows` and reports it to the far end, so
/// if the emulator does not grow when the view does, the app faithfully reports a stale
/// size forever — and every fix aimed at the reporting path is aimed at the wrong half.
@MainActor
final class TerminalResizeProbeTests: XCTestCase {
    func testEmulatorRowsFollowTheViewHeight() {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.layoutIfNeeded()
        let short = view.getTerminal().rows

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        let tall = view.getTerminal().rows

        XCTAssertGreaterThan(short, 0, "the emulator never sized at all")
        XCTAssertGreaterThan(
            tall, short,
            "the emulator did NOT grow with its view (\(short) -> \(tall) rows). "
                + "If this is equal, reading terminal.rows can never report the larger "
                + "size and the remote stays clamped no matter what the app sends."
        )

        // And back down, since the keyboard appearing is the other half.
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        view.layoutIfNeeded()
        XCTAssertEqual(view.getTerminal().rows, short, "the emulator did not shrink back")
    }

    /// The layout hook the app relies on must actually fire.
    func testOnLayoutFiresWhenTheViewResizes() {
        let view = TerminalEmulatorView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var fired = 0
        view.onLayout = { fired += 1 }
        view.layoutIfNeeded()
        let afterFirst = fired

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(
            fired, afterFirst,
            "onLayout did not fire on resize, so nothing tells the far end the size changed"
        )
    }
}
