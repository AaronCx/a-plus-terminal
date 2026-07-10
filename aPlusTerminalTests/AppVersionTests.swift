import XCTest
@testable import aPlusTerminal

final class AppVersionTests: XCTestCase {
    func testVersionAndBuild() {
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: "18"), "a+Terminal 1.0 (18)")
    }

    func testMissingBuildOmitsParentheses() {
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: nil), "a+Terminal 1.0")
        XCTAssertEqual(AppVersion.displayString(short: "1.0", build: "  "), "a+Terminal 1.0")
    }

    func testMissingVersionStillShowsBuild() {
        XCTAssertEqual(AppVersion.displayString(short: nil, build: "18"), "a+Terminal (18)")
    }

    func testBothMissingFallsBackToAppName() {
        XCTAssertEqual(AppVersion.displayString(short: nil, build: nil), "a+Terminal")
        XCTAssertEqual(AppVersion.displayString(short: "", build: ""), "a+Terminal")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(AppVersion.displayString(short: " 1.0 ", build: " 18 "), "a+Terminal 1.0 (18)")
    }

    func testCurrentReadsHostAppBundle() {
        // Tests run hosted in the app, so Bundle.main carries the real
        // version — the string must include more than the bare app name.
        let current = AppVersion.current
        XCTAssertTrue(current.hasPrefix("a+Terminal "), "got: \(current)")
    }
}
