import AVFoundation
import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isMicBusy = false
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

    let hotkeyManager = HotkeyManager()
    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let textInjector = TextInjector()
    let modelManager = ModelManager()
    let updateChecker = UpdateChecker()

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
        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Listening..."
        } catch AudioRecorderError.micInUse {
            statusMessage = "Mic in use by another app"
            isMicBusy = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.resetMicBusyFlagIfNeeded()
            }
        } catch {
            statusMessage = "Mic busy — close other audio apps and retry"
        }
    }

    func stopAndTranscribe() {
        guard isRecording else { return }

        audioRecorder.stopRecording()
    }

    private func transcribeAndInject(_ samples: [Float]) async {
        isRecording = false
        guard !samples.isEmpty else {
            statusMessage = "Ready"
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."

        do {
            let text = try await transcriber.transcribe(audioSamples: samples)
            if !text.isEmpty {
                var finalText = text
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *),
                   aiCorrectionEnabled,
                   let corrector = textCorrector as? TextCorrector {
                    statusMessage = "Correcting..."
                    finalText = await corrector.correct(text)
                }
                #endif
                textInjector.injectText(finalText)
            }
            statusMessage = "Ready"
        } catch {

            statusMessage = "Transcription failed"
        }

        isTranscribing = false
    }

    func switchModel(to model: ModelSize) async {
        guard !isSwitchingModel else { return }
        isSwitchingModel = true
        defer { isSwitchingModel = false }

        transcriber.unloadModel()

        if !modelManager.isModelDownloaded(model) || !modelManager.isCoreMLDownloaded(model) {
            statusMessage = "Downloading \(model.displayName)..."
            do {
                try await modelManager.downloadModel(model)
            } catch {
                statusMessage = "Download failed: \(error.localizedDescription)"
                // Revert UI selection to the model that is still loaded (none now — stay on previous)
                return
            }
        }

        do {
            try transcriber.loadModel(at: modelManager.localModelPath(for: model))
            selectedModel = model   // Commit only after successful load
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    private func resetMicBusyFlagIfNeeded() {
        guard isMicBusy else { return }
        isMicBusy = false
        if !isRecording && !isTranscribing {
            statusMessage = "Ready"
        }
    }
}
