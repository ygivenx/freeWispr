import XCTest
@testable import FreeWispr

final class AudioRecorderTests: XCTestCase {

    func testRMSSilence() {
        let silence = [Float](repeating: 0.0, count: 100)
        XCTAssertEqual(AudioRecorder.calculateRMS(silence), 0.0)
    }

    func testRMSNonZero() {
        let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
        let rms = AudioRecorder.calculateRMS(samples)
        XCTAssertEqual(rms, 1.0, accuracy: 0.001)
    }

    func testRMSEmpty() {
        XCTAssertEqual(AudioRecorder.calculateRMS([]), 0.0)
    }
}
