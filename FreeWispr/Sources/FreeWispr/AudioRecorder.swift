import AVFoundation
import CoreAudio
import Foundation

enum AudioRecorderError: LocalizedError {
    case micInUse
    case formatError

    var errorDescription: String? {
        switch self {
        case .micInUse: "Microphone is in use by another app"
        case .formatError: "Cannot create audio format converter"
        }
    }
}

@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    // Accessed from the audio tap callback (non-main thread).
    // Thread safety is ensured by serializing all access through bufferQueue.
    nonisolated(unsafe) private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.ygivenx.FreeWispr.audioBuffer")
    private var isTapInstalled = false

    // Written on main thread before engine start / after engine stop.
    // Read from audio tap callback. Safe because writes happen only while
    // the engine is stopped, creating a happens-before relationship.
    nonisolated(unsafe) private var isCapturing = false

    var onRecordingComplete: (([Float]) -> Void)?

    private lazy var whisperFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    /// Check if another process is currently using the default input device.
    /// Uses CoreAudio HAL queries that don't need main thread, but note that
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` reports ANY process
    /// including this one — safe here because our engine is stopped when called.
    nonisolated static func isMicInUseByAnotherProcess() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        let runStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return runStatus == noErr && isRunning != 0
    }

    /// Install the audio tap once during setup. This avoids recreating
    /// AudioConverters and triggering TCC permission checks on every recording.
    func prepareEngine() throws {
        guard !isTapInstalled else { return }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: whisperFormat) else {
            throw AudioRecorderError.formatError
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) {
            [weak self] buffer, _ in
            guard let self = self, self.isCapturing else { return }

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
        if Self.isMicInUseByAnotherProcess() {
            throw AudioRecorderError.micInUse
        }
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
        isCapturing = true
        isRecording = true
    }

    /// Tear down the audio tap so the next attempt rebuilds with the current
    /// hardware format.
    private func resetEngine() {
        isCapturing = false
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isCapturing = false
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
