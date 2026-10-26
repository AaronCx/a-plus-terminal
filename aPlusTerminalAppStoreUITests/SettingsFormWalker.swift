import XCTest

// Compiled into BOTH UI test targets (project.yml): the App Store test and its
// beta mirror must walk the form identically, or the mirror proves nothing.

/// Scrolls a Settings Form top to bottom, snapshotting every element on each
/// page. A Form is lazy — rows off screen are not in the accessibility tree —
/// so one query at the top would miss most of it.
///
/// Each step is a held drag of under half the screen, not a swipe: a swipe's
/// momentum can carry the form past rows that then never appear in any
/// snapshot. A held drag has no momentum, so consecutive pages overlap, and
/// the walk checks they do — a gap fails the test instead of passing silently.
struct SettingsFormWalker {
    let app: XCUIApplication

    struct Page {
        /// Every label, identifier, value, title and placeholder on the page.
        var texts: [String]
        /// Labels of the rows inside the form only (no nav or tab bar, which
        /// are on every page) — what the overlap and bottom checks compare.
        var rows: Set<String>
        var meshyyHits: [String] { texts.filter { $0.localizedCaseInsensitiveContains("meshyy") } }
    }

    func walk(maxDrags: Int = 40) throws -> [Page] {
        let form = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Settings form present")
        var pages: [Page] = [try page(of: form)]
        for _ in 0..<maxDrags {
            // Near the leading edge (labels, not toggles), 40% of the form's
            // height — well under the visible area between the bars.
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.75))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            let next = try page(of: form)
            let previous = pages.last!
            // Unchanged after a drag = the bottom of the form.
            if next.rows == previous.rows { return pages }
            XCTAssertFalse(next.rows.isDisjoint(with: previous.rows),
                           "Settings scrolled past rows unseen: no row shared between \(previous.rows.sorted()) and \(next.rows.sorted())")
            pages.append(next)
        }
        XCTFail("Settings never stopped scrolling after \(maxDrags) drags")
        return pages
    }

    /// One accessibility snapshot of the whole app — every element of every
    /// type, in one round trip, so the strings are compared in-process.
    private func page(of form: XCUIElement) throws -> Page {
        var texts: [String] = []
        func visit(_ element: XCUIElementSnapshot) {
            let candidates: [Any?] = [element.label, element.identifier, element.value,
                                      element.title, element.placeholderValue]
            for case let value? in candidates {
                let text = (value as? String) ?? String(describing: value)
                if !text.isEmpty { texts.append(text) }
            }
            element.children.forEach(visit)
        }
        visit(try app.snapshot())

        var rows: Set<String> = []
        func visitRows(_ element: XCUIElementSnapshot) {
            if !element.label.isEmpty { rows.insert(element.label) }
            element.children.forEach(visitRows)
        }
        visitRows(try form.snapshot())
        return Page(texts: texts, rows: rows)
    }
}
