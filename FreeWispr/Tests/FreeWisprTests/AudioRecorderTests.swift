import AVFoundation
import XCTest
import MicrophoneCapture
import MicrophoneCaptureTestSupport
@testable import FreeWisprCore

final class AudioRecorderTests: XCTestCase {
    @MainActor
    func testInitialState() async {
        XCTAssertFalse(AudioRecorder().isRecording)
    }

    @MainActor
    func testFailedStartRetriesWithFreshEngineAndDiscardsFailedAudio() async throws {
        let failed = FakeMicrophoneEngine(fails: true)
        let working = FakeMicrophoneEngine()
        var attempts = [failed, working]
        let recorder = AudioRecorder(makeEngine: { attempts.removeFirst() }, isMicrophoneInUse: { false })
        var result: [Float]?
        recorder.onRecordingComplete = { result = $0 }

        try recorder.startRecording()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(failed.stopCount, 1)
        // Simulate a delayed callback from the failed engine.
        failed.tap?(Self.buffer(rate: 16000, channels: 1), AVAudioTime(sampleTime: 0, atRate: 16000))
        recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(result?.count, 1600)
        XCTAssertEqual(working.stopCount, 1)
    }

    @MainActor
    func testRepeatedFailureLeavesRecorderReadyForNextAttempt() async throws {
        var engines: [FakeMicrophoneEngine] = []
        let recorder = AudioRecorder(makeEngine: {
            let engine = FakeMicrophoneEngine(fails: engines.count < 2)
            engines.append(engine)
            return engine
        }, isMicrophoneInUse: { false })
        var completions = 0
        recorder.onRecordingComplete = { _ in completions += 1 }
        XCTAssertThrowsError(try recorder.startRecording())
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(engines.count, 2)
        XCTAssertTrue(engines.allSatisfy { $0.stopCount == 1 })
        recorder.stopRecording()
        XCTAssertEqual(completions, 0)

        try recorder.startRecording()
        try recorder.startRecording() // Holding the hotkey must not reopen the mic.
        XCTAssertEqual(engines.count, 3)
        recorder.stopRecording()
        recorder.stopRecording()
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testBusyMicrophoneDoesNotCreateAnEngineAndRecovers() async throws {
        var busy = true
        var creations = 0
        let recorder = AudioRecorder(makeEngine: {
            creations += 1
            return FakeMicrophoneEngine()
        }, isMicrophoneInUse: { busy })
        XCTAssertThrowsError(try recorder.startRecording()) { error in
            guard case AudioRecorderError.micInUse = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(creations, 0)
        XCTAssertFalse(recorder.isRecording)
        busy = false
        try recorder.startRecording()
        XCTAssertTrue(recorder.isRecording)
        recorder.stopRecording()
    }

    @MainActor
    func testRouteChangeDiscardsAudioAndIgnoresOldSessionNotifications() async throws {
        let first = FakeMicrophoneEngine()
        let second = FakeMicrophoneEngine()
        var engines = [first, second]
        let recorder = AudioRecorder(makeEngine: { engines.removeFirst() }, isMicrophoneInUse: { false })
        var interruptions = 0
        var completions = 0
        recorder.onRecordingInterrupted = { interruptions += 1 }
        recorder.onRecordingComplete = { _ in completions += 1 }
        try recorder.startRecording()
        let staleNotification = first.onConfigurationChange
        staleNotification?()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(interruptions, 1)
        XCTAssertEqual(completions, 0)
        recorder.stopRecording()
        try recorder.startRecording()
        staleNotification?()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(interruptions, 1)
        recorder.stopRecording()
        XCTAssertEqual(completions, 1)
    }

    func testNativeAudioExceptionBecomesRecoverableError() throws {
        let engine = FWMicrophoneEngine(engineFactory: { FWThrowingAudioEngine() })
        for _ in 0..<2 {
            XCTAssertThrowsError(try engine.start { _, _ in }) { error in
                let nativeError = error as NSError
                XCTAssertEqual(nativeError.domain, "FreeWispr.Microphone")
                XCTAssertEqual(nativeError.code, 2)
                XCTAssertEqual(nativeError.userInfo["exceptionReason"] as? String,
                               "Simulated microphone configuration change")
            }
            engine.stop()
        }
    }

    func testConvertsChangingUSBFormatsToMono16kHz() {
        let capture = AudioCaptureBuffer()
        for rate in [48000.0, 44100.0, 16000.0] {
            for _ in 0..<10 {
                capture.append(Self.buffer(rate: rate, channels: rate == 16000 ? 1 : 2))
            }
        }
        let result = capture.finish()
        // Three seconds, allowing for resampler startup latency at format changes.
        XCTAssertGreaterThan(result.count, 47000)
        XCTAssertLessThanOrEqual(result.count, 48000)
        XCTAssertTrue(result.allSatisfy { $0.isFinite })
        XCTAssertEqual(result[result.count / 2], 0.25, accuracy: 0.01)
    }

    func testLateCallbacksAndRepeatedFinishDoNotReturnMoreAudio() {
        let capture = AudioCaptureBuffer()
        capture.append(Self.buffer(rate: 16000, channels: 1))
        XCTAssertEqual(capture.finish().count, 1600)
        capture.append(Self.buffer(rate: 16000, channels: 1))
        XCTAssertTrue(capture.finish().isEmpty)
    }

    fileprivate static func buffer(rate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let length = AVAudioFrameCount(rate / 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length)!
        buffer.frameLength = length
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(length) {
                buffer.floatChannelData![channel][frame] = 0.25
            }
        }
        return buffer
    }
}

private final class FakeMicrophoneEngine: MicrophoneEngine {
    var onConfigurationChange: (() -> Void)?
    let fails: Bool
    var stopCount = 0
    var tap: AVAudioNodeTapBlock?

    init(fails: Bool = false) { self.fails = fails }

    func start(tap: @escaping AVAudioNodeTapBlock) throws {
        self.tap = tap
        tap(AudioRecorderTests.buffer(rate: 16000, channels: 1), AVAudioTime(sampleTime: 0, atRate: 16000))
        if fails { throw NSError(domain: "TestMicrophone", code: 1) }
    }

    func stop() { stopCount += 1 }
}
