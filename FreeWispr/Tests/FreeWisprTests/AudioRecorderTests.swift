import XCTest
@testable import FreeWispr

final class AudioRecorderTests: XCTestCase {

    func testInitialState() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isRecording)
    }
}
