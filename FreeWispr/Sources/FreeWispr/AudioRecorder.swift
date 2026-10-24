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

    private let releaseTail: TimeInterval
    private var tailWork: DispatchWorkItem?

    var onRecordingComplete: (([Float]) -> Void)?

    var onRecordingInterrupted: (() -> Void)?

    /// Receives each converted 16 kHz chunk on the capture queue while recording.
    /// Read once per recording at start, so changing it later never affects an in-flight capture.
    var onChunk: (([Float]) -> Void)?

    /// `releaseTail`: keep capturing this long after `stopRecording()` so the last
    /// word isn't clipped when the key is released early. 0 completes synchronously.
    init(makeEngine: @escaping () -> MicrophoneEngine = { FWMicrophoneEngine() },
         isMicrophoneInUse: @escaping () -> Bool = { FWMicrophoneEngine.isDefaultInputInUse() },
         releaseTail: TimeInterval = 0) {
        self.makeEngine = makeEngine
        self.isMicrophoneInUse = isMicrophoneInUse
        self.releaseTail = releaseTail
    }

    func startRecording() throws {
        guard !isRecording else { return }
        // A new press during the tail: deliver the pending recording first. Skip the in-use
        // check then, since our own just-stopped engine can still read as running.
        let hadPending = capture != nil
        completePendingRecording()
        if !hadPending, isMicrophoneInUse() { throw AudioRecorderError.micInUse }
        // Retry once with an entirely new engine if the device is transitioning.
        for attempt in 0..<2 {
            let engine = makeEngine()
            let capture = AudioCaptureBuffer(onChunk: onChunk)
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
        isRecording = false
        guard releaseTail > 0 else {
            completePendingRecording()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.completePendingRecording() }
        tailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseTail, execute: work)
    }

    /// Finishes the capture and delivers it. Idempotent: clearing `capture` ensures
    /// a recording is never delivered twice (tail timer vs. a new start).
    private func completePendingRecording() {
        guard capture != nil else { return }
        onRecordingComplete?(finishRecording())
    }

    private func handleConfigurationChange(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        // Already released (in the tail): what was captured is the whole utterance.
        guard isRecording else {
            completePendingRecording()
            return
        }
        // A disconnected/reconfigured mic yields an incomplete recording.
        // Discard it rather than unexpectedly injecting partial dictated text.
        _ = finishRecording()
        onRecordingInterrupted?()
    }

    private func finishRecording() -> [Float] {
        tailWork?.cancel()
        tailWork = nil
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
    private let onChunk: (([Float]) -> Void)?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000,
        channels: 1, interleaved: false
    )!

    init(onChunk: (([Float]) -> Void)? = nil) {
        self.onChunk = onChunk
    }

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
            let chunk = Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
            samples.append(contentsOf: chunk)
            onChunk?(chunk)  // still inside `active`: never fires after finish()
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
