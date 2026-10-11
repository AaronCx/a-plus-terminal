import XCTest

// Compiled into BOTH UI test targets (project.yml): the App Store test and its
// beta mirror must walk the form identically, or the mirror proves nothing.

/// Scrolls a Settings Form top to bottom, snapshotting every element on each
/// page. A Form is lazy — rows off screen are not in the accessibility tree —
/// so one query at the top would miss most of it.
struct SettingsFormWalker {
    let app: XCUIApplication

    struct Page {
        /// Every label, identifier, value, title and placeholder on the page.
        var texts: [String]
        var meshyyHits: [String] { texts.filter { $0.localizedCaseInsensitiveContains("meshyy") } }
    }

    func walk(maxSwipes: Int = 30) throws -> [Page] {
        let form = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Settings form present")
        var pages: [Page] = [try page()]
        for _ in 0..<maxSwipes {
            form.swipeUp(velocity: .fast)
            let next = try page()
            // Unchanged after a swipe = the bottom of the form.
            if Set(next.texts) == Set(pages.last!.texts) { return pages }
            pages.append(next)
        }
        XCTFail("Settings never stopped scrolling after \(maxSwipes) swipes")
        return pages
    }

    /// One accessibility snapshot of the whole app — every element of every
    /// type, in one round trip, so the strings are compared in-process.
    private func page() throws -> Page {
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
        return Page(texts: texts)
    }
}
