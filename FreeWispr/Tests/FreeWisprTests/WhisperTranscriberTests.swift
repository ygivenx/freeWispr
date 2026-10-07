import XCTest
@testable import FreeWisprCore

final class WhisperTranscriberTests: XCTestCase {

    @MainActor
    func testTranscriberInitialState() async {
        let transcriber = WhisperTranscriber()
        XCTAssertFalse(transcriber.isModelLoaded)
        XCTAssertFalse(transcriber.isTranscribing)
    }

    @MainActor
    func testTranscribeSilence() async throws {
        let silence = [Float](repeating: 0.0, count: 16000)
        let transcriber = WhisperTranscriber()

        do {
            _ = try await transcriber.transcribe(audioSamples: silence)
            XCTFail("Should have thrown — no model loaded")
        } catch {
            // Expected
        }
    }
}
