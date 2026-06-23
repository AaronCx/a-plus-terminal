import XCTest
import Speech
@testable import aPlusTerminal

/// Locks the headline privacy promise: dictation is on-device only and never
/// falls back to Apple's server recognition. Without this, a refactor that
/// dropped `requiresOnDeviceRecognition` would silently route audio to a
/// server while every other test kept passing.
final class DictationEngineTests: XCTestCase {
    func testRecognitionRequestIsOnDeviceOnly() {
        let request = DictationEngine.makeRecognitionRequest()
        XCTAssertTrue(request.requiresOnDeviceRecognition,
                      "dictation must never send audio off the device")
        XCTAssertTrue(request.shouldReportPartialResults,
                      "partial results drive the live transcript preview")
    }
}
