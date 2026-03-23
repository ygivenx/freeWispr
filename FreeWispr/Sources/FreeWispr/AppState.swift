import AppKit
import AVFoundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "AppState")

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isSwitchingModel = false
    @Published var statusMessage = "Ready"
    @Published var selectedModel: ModelSize = .base

    enum AICorrectionStatus {
        case unavailable  // not macOS 26+
        case needsSetup   // macOS 26+ but Apple Intelligence not enabled
        case active       // working
    }
    @Published var aiCorrectionStatus: AICorrectionStatus = .unavailable
    @Published var aiCorrectionEnabled = false

    private var isSetUp = false
    private var textCorrector: Any?
    /// Frontmost app captured at recording start for focus check and LLM context
    private var recordingTargetAppName: String?
    private var recordingTargetBundleID: String?

    let hotkeyManager = HotkeyManager()
    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let textInjector = TextInjector()
    let modelManager = ModelManager()
    let updateChecker = UpdateChecker()
    private let recordingIndicator = RecordingIndicator()

    func setup() async {
        guard !isSetUp else { return }
        isSetUp = true

        // Check accessibility permission
        if !HotkeyManager.checkAccessibilityPermission() {
            statusMessage = "Needs Accessibility permission"
        }

        // Download model + Core ML encoder if needed
        if !modelManager.isModelDownloaded(selectedModel) || !modelManager.isCoreMLDownloaded(selectedModel) {
            statusMessage = "Downloading \(selectedModel.displayName) model..."
            do {
                try await modelManager.downloadModel(selectedModel)
            } catch {
                statusMessage = "Model download failed: \(error.localizedDescription)"
                return
            }
        }

        // Load model
        do {
            let modelPath = modelManager.localModelPath(for: selectedModel)
            try transcriber.loadModel(at: modelPath)
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model: \(error.localizedDescription)"
            return
        }

        // Initialize on-device LLM text corrector if available
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let corrector = TextCorrector()
            textCorrector = corrector
            aiCorrectionStatus = corrector.isAvailable ? .active : .needsSetup
        }
        #endif

        // Set up push-to-talk: hold to record, release to transcribe
        hotkeyManager.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkeyManager.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                self?.stopAndTranscribe()
            }
        }
        _ = hotkeyManager.start()

        // Set up audio completion handler and warm up the engine
        audioRecorder.onRecordingComplete = { [weak self] samples in
            Task { @MainActor in
                await self?.transcribeAndInject(samples)
            }
        }

        do {
            try audioRecorder.prepareEngine()
        } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"
        }

        Task { await updateChecker.checkForUpdate() }
    }

    func startRecording() {
        guard !isRecording else { return }

        // Capture frontmost app on @MainActor for thread-safe use in LLM context and focus check
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        recordingTargetBundleID = frontmostApp?.bundleIdentifier
        recordingTargetAppName = frontmostApp?.localizedName

        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Listening..."
            recordingIndicator.show()
        } catch {
            statusMessage = "Mic busy — close other audio apps and retry"
        }
    }

    func stopAndTranscribe() {
        guard isRecording else { return }

        audioRecorder.stopRecording()
    }

    /// Show a temporary status message that reverts to "Ready" after a delay.
    private func showTemporaryStatus(_ message: String, duration: TimeInterval = 2.0) {
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if statusMessage == message {
                statusMessage = "Ready"
            }
        }
    }

    /// Minimum sample count to attempt transcription (0.3s at 16kHz).
    private static let minSampleCount = 4800
    /// Peak amplitude below this threshold is considered silence.
    private static let silenceThreshold: Float = 0.01
    /// Target peak amplitude for normalization.
    private static let normalizationTarget: Float = 0.7

    private func transcribeAndInject(_ samples: [Float]) async {
        isRecording = false
        recordingIndicator.hide()
        guard !samples.isEmpty else {
            statusMessage = "Ready"
            return
        }

        // Reject recordings that are too short (< 0.3s)
        guard samples.count >= Self.minSampleCount else {
            showTemporaryStatus("Didn't catch that — hold longer")
            return
        }

        // Reject recordings that are too quiet (silence)
        let peak = samples.lazy.map { abs($0) }.max() ?? 0
        guard peak >= Self.silenceThreshold else {
            showTemporaryStatus("Too quiet — speak louder or check mic")
            return
        }

        // Normalize audio to consistent peak amplitude
        let normalizedSamples: [Float]
        if peak > 0 && peak < Self.normalizationTarget {
            let gain = Self.normalizationTarget / peak
            normalizedSamples = samples.map { $0 * gain }
        } else {
            normalizedSamples = samples
        }

        isTranscribing = true
        statusMessage = "Transcribing..."

        do {
            let text = try await transcriber.transcribe(audioSamples: normalizedSamples)
            if !text.isEmpty {
                var finalText = text
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *),
                   aiCorrectionEnabled,
                   let corrector = textCorrector as? TextCorrector {
                    statusMessage = "Correcting..."
                    finalText = await corrector.correct(text, appName: recordingTargetAppName, bundleID: recordingTargetBundleID)
                }
                #endif
                textInjector.injectText(finalText)
            }
            statusMessage = "Ready"
        } catch TranscriberError.timeout {
            logger.warning("Whisper inference timed out")
            showTemporaryStatus("Transcription timed out")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            showTemporaryStatus("Transcription failed — try again")
        }

        isTranscribing = false
    }

    func switchModel(to model: ModelSize) async {
        guard !isSwitchingModel else { return }
        isSwitchingModel = true
        defer { isSwitchingModel = false }

        if !modelManager.isModelDownloaded(model) || !modelManager.isCoreMLDownloaded(model) {
            statusMessage = "Downloading \(model.displayName)..."
            do {
                try await modelManager.downloadModel(model)
            } catch {
                statusMessage = "Download failed: \(error.localizedDescription)"
                return
            }
        }

        // Unload AFTER successful download so failed downloads keep the previous model working
        transcriber.unloadModel()

        do {
            try transcriber.loadModel(at: modelManager.localModelPath(for: model))
            selectedModel = model   // Commit only after successful load
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }
}
