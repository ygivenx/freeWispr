import AVFoundation
import Foundation

class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.ygivenx.FreeWispr.audioBuffer")
    private var isTapInstalled = false
    /// Thread-safe recording flag read by the audio tap callback via bufferQueue
    private var _isCapturing = false
    /// Set when the audio hardware config changes mid-session (e.g. BT headset
    /// connects, another app reconfigures the mic). The tap is rebuilt on the
    /// next startRecording() call.
    private var needsRebuild = false

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

        // Observe hardware configuration changes (BT headset, mic switch, etc.)
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: audioEngine)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: whisperFormat) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot create audio format converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            // Read _isCapturing under bufferQueue to avoid data race
            let capturing = self.bufferQueue.sync { self._isCapturing }
            guard capturing else { return }

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
        if !isTapInstalled || needsRebuild {
            resetEngine()
            try prepareEngine()
            needsRebuild = false
        }
        bufferQueue.sync {
            audioBuffer.removeAll(keepingCapacity: true)
            _isCapturing = true
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

    @objc private func handleConfigurationChange(_ notification: Notification) {
        // Mark for rebuild — don't tear down now since we may be mid-recording.
        // The tap will be rebuilt on the next startRecording() call.
        needsRebuild = true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        bufferQueue.sync { _isCapturing = false }
        audioEngine.stop()

        let finalBuffer = bufferQueue.sync { () -> [Float] in
            let copy = audioBuffer
            audioBuffer.removeAll(keepingCapacity: true)
            return copy
        }
        onRecordingComplete?(finalBuffer)
    }
}
