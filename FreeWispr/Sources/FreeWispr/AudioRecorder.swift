import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.ygivenx.FreeWispr.audioBuffer")
    private var isTapInstalled = false

    var onRecordingComplete: (([Float]) -> Void)?

    private lazy var whisperFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Install the audio tap once during setup. This avoids recreating
    /// AudioConverters and triggering TCC permission checks on every recording.
    func prepareEngine() throws {
        guard !isTapInstalled else { return }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: whisperFormat) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot create audio format converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (16000.0 / hardwareFormat.sampleRate)
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.whisperFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, let channelData = converted.floatChannelData else { return }

            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))

            self.bufferQueue.async {
                self.audioBuffer.append(contentsOf: samples)
            }
        }

        audioEngine.prepare()
        isTapInstalled = true
    }

    func startRecording() throws {
        if !isTapInstalled {
            try prepareEngine()
        }
        bufferQueue.sync {
            audioBuffer.removeAll(keepingCapacity: true)
        }
        do {
            try audioEngine.start()
        } catch {
            // The hardware format may have changed (e.g. another app like Teams
            // reconfigured the mic). Rebuild the tap with the current format and
            // retry once.
            resetEngine()
            try prepareEngine()
            try audioEngine.start()
        }
        isRecording = true
    }

    /// Tear down the audio tap so the next attempt rebuilds with the current
    /// hardware format.
    private func resetEngine() {
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        audioEngine.stop()

        let finalBuffer = bufferQueue.sync { () -> [Float] in
            let copy = audioBuffer
            // Release capacity if buffer grew beyond 60s of audio (16kHz mono)
            // to prevent memory from ratcheting up after long recordings.
            let maxRetainedCapacity = 16000 * 60
            audioBuffer.removeAll(keepingCapacity: audioBuffer.capacity <= maxRetainedCapacity)
            return copy
        }
        onRecordingComplete?(finalBuffer)
    }
}
