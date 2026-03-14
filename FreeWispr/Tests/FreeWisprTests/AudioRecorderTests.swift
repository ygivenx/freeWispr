import XCTest
@testable import FreeWisprCore

@MainActor
final class AudioRecorderTests: XCTestCase {

    func testInitialState() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isRecording)
    }
}
