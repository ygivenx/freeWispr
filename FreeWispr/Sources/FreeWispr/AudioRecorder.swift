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
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            // 16 kHz mono float32 is universally supported; failing here indicates a
            // serious system-level audio misconfiguration that warrants a hard stop.
            fatalError("FreeWispr: cannot create 16 kHz mono PCM format — audio subsystem unavailable")
        }
        return format
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
        // AVAudioEngine automatically removes the installed tap and stops itself
        // when the hardware configuration changes (e.g. another app like Teams
        // releases the microphone). Dispatch all state mutations to the main
        // thread: the notification can arrive on an unspecified thread in some
        // configurations, and @Published properties must only be mutated on the
        // main thread to avoid data races that cause SwiftUI actor-isolation
        // crashes (EXC_BAD_ACCESS in swift_task_isCurrentExecutorWithFlagsImpl).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Reflect the engine's auto-removal of the tap so that the next
            // resetEngine() call does not attempt to remove an already-absent
            // tap, which produces undefined behaviour / NSException.
            self.isTapInstalled = false
            self.needsRebuild = true
            // If a recording was in progress when the hardware changed, stop it
            // cleanly so AppState can reset its UI state via onRecordingComplete.
            if self.isRecording {
                self.stopRecording()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        bufferQueue.sync { _isCapturing = false }
        audioEngine.stop()

        let finalBuffer = bufferQueue.sync { () -> [Float] in
            let copy = audioBuffer
            // Release capacity if buffer grew beyond 60s of audio (16kHz mono)
            // to prevent memory from ratcheting up after long recordings.
            let maxRetainedCapacity = 16000 * 60
            audioBuffer.removeAll(keepingCapacity: audioBuffer.capacity <= maxRetainedCapacity)
            return copy
        }
        // Always deliver the completion callback on the main thread. stopRecording()
        // may be called from handleConfigurationChange (already main-dispatched) or
        // directly from AppState (@MainActor), so this is typically a no-op hop, but
        // it guards against any future call-site that runs off main.
        // Capture the closure value now (before any potential dealloc) rather than
        // capturing self weakly to avoid an unnecessary retain cycle.
        let completion = onRecordingComplete
        if Thread.isMainThread {
            completion?(finalBuffer)
        } else {
            DispatchQueue.main.async { completion?(finalBuffer) }
        }
    }

    deinit {
        // Remove the AVAudioEngineConfigurationChange observer so that a hardware-change
        // notification arriving after this object is released does not invoke the
        // @objc selector on a dangling pointer (EXC_BAD_ACCESS).
        NotificationCenter.default.removeObserver(self)
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
}
