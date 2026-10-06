import AVFoundation
import Foundation
import MicrophoneCapture

protocol MicrophoneEngine: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
    func start(tap: @escaping AVAudioNodeTapBlock) throws
    func stop()
}

extension FWMicrophoneEngine: MicrophoneEngine {}

enum AudioRecorderError: LocalizedError {
    case micInUse

    var errorDescription: String? { "Microphone is in use by another app" }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    private let makeEngine: () -> MicrophoneEngine
    private let isMicrophoneInUse: () -> Bool
    private var sessionID: UUID?
    private var engine: MicrophoneEngine?
    private var capture: AudioCaptureBuffer?

    var onRecordingComplete: (([Float]) -> Void)?

    var onRecordingInterrupted: (() -> Void)?

    init(makeEngine: @escaping () -> MicrophoneEngine = { FWMicrophoneEngine() },
         isMicrophoneInUse: @escaping () -> Bool = { FWMicrophoneEngine.isDefaultInputInUse() }) {
        self.makeEngine = makeEngine
        self.isMicrophoneInUse = isMicrophoneInUse
    }

    func startRecording() throws {
        guard !isRecording else { return }
        guard !isMicrophoneInUse() else { throw AudioRecorderError.micInUse }
        // Retry once with an entirely new engine if the device is transitioning.
        for attempt in 0..<2 {
            let engine = makeEngine()
            let capture = AudioCaptureBuffer()
            let id = UUID()
            engine.onConfigurationChange = { [weak self] in
                // The native engine delivers route changes on the main queue.
                MainActor.assumeIsolated { self?.handleConfigurationChange(sessionID: id) }
            }
            do {
                try engine.start { buffer, _ in capture.append(buffer) }
                self.engine = engine
                self.capture = capture
                self.sessionID = id
                isRecording = true
                return
            } catch {
                // Close the buffer before stopping: late tap callbacks must not
                // leak samples into a later recording or a successful retry.
                _ = capture.finish()
                engine.onConfigurationChange = nil
                engine.stop()
                if attempt == 1 { throw error }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let samples = finishRecording()
        onRecordingComplete?(samples)
    }

    private func handleConfigurationChange(sessionID: UUID) {
        guard isRecording, self.sessionID == sessionID else { return }
        // A disconnected/reconfigured mic yields an incomplete recording.
        // Discard it rather than unexpectedly injecting partial dictated text.
        _ = finishRecording()
        onRecordingInterrupted?()
    }

    private func finishRecording() -> [Float] {
        isRecording = false
        sessionID = nil
        let samples = capture?.finish() ?? []
        engine?.onConfigurationChange = nil
        engine?.stop()
        engine = nil
        capture = nil
        return samples
    }
}

/// One recording attempt owns its converter and samples. All callback work and
/// finalization are serialized, including callbacks arriving after engine stop.
final class AudioCaptureBuffer {
    private let queue = DispatchQueue(label: "com.ygivenx.FreeWispr.audioBuffer")
    private var samples: [Float] = []
    private var active = true
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000,
        channels: 1, interleaved: false
    )!

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard active, buffer.frameLength > 0,
                  buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
                  buffer.format.channelCount > 0 else { return }

            // Use the actual delivered format, including changes during capture.
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            }
            guard let converter else { return }
            let capacity = ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)
            guard capacity > 0, capacity < Double(UInt32.max),
                  let converted = AVAudioPCMBuffer(
                    pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)
                  ) else { return }

            var suppliedInput = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                // A converter may request input more than once. Returning the
                // same buffer repeatedly duplicates audio and corrupts timing.
                guard !suppliedInput else {
                    status.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = converted.floatChannelData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
        }
    }

    func finish() -> [Float] {
        queue.sync {
            active = false
            let result = samples
            samples = []
            converter = nil
            return result
        }
    }
}
