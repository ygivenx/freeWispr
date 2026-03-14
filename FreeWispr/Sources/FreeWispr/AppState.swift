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
    private var pendingModelSelection: ModelSize?

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
            try await transcriber.loadModel(at: modelPath)
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

    func switchModel(to targetModel: ModelSize) async {
        if isSwitchingModel {
            pendingModelSelection = targetModel
            return
        }

        isSwitchingModel = true
        let previousModel = selectedModel
        if previousModel != targetModel {
            selectedModel = targetModel
        }
        defer {
            isSwitchingModel = false
            if let pending = pendingModelSelection {
                pendingModelSelection = nil
                if pending != selectedModel {
                    Task { await self.switchModel(to: pending) }
                }
            }
        }

        transcriber.unloadModel()

        if !modelManager.isModelDownloaded(targetModel) || !modelManager.isCoreMLDownloaded(targetModel) {
            statusMessage = "Downloading \(targetModel.displayName)..."
            do {
                try await modelManager.downloadModel(targetModel)
            } catch {
                statusMessage = "Download failed: \(error.localizedDescription)"
                selectedModel = previousModel
                return
            }
        }

        do {
            try await transcriber.loadModel(at: modelManager.localModelPath(for: targetModel))
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model: \(error.localizedDescription)"
            selectedModel = previousModel
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
