import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.ygivenx.FreeWispr.audioBuffer")
    private var isEngineRunning = false

    var onRecordingComplete: (([Float]) -> Void)?

    private lazy var whisperFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Start the audio engine once and keep it warm. Call this during app setup.
    func prepareEngine() throws {
        guard !isEngineRunning else { return }

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
        try audioEngine.start()
        isEngineRunning = true
    }

    func startRecording() throws {
        if !isEngineRunning {
            try prepareEngine()
        }
        bufferQueue.sync {
            audioBuffer.removeAll(keepingCapacity: true)
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        let finalBuffer = bufferQueue.sync { () -> [Float] in
            let copy = audioBuffer
            audioBuffer.removeAll(keepingCapacity: true)
            return copy
        }
        onRecordingComplete?(finalBuffer)
    }
}
