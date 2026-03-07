import AVFoundation
import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready"
    @Published var selectedModel: ModelSize = .base
    private var isSetUp = false

    let hotkeyManager = HotkeyManager()
    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let textInjector = TextInjector()
    let modelManager = ModelManager()

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

        // Set up audio completion handler
        audioRecorder.onRecordingComplete = { [weak self] samples in
            Task { @MainActor in
                await self?.transcribeAndInject(samples)
            }
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Listening..."
            } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"

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
                textInjector.injectText(text)
            }
            statusMessage = "Ready"
        } catch {

            statusMessage = "Transcription failed"
        }

        isTranscribing = false
    }

    func switchModel(to model: ModelSize) async {
        selectedModel = model
        transcriber.unloadModel()

        if !modelManager.isModelDownloaded(model) || !modelManager.isCoreMLDownloaded(model) {
            statusMessage = "Downloading \(model.displayName)..."
            do {
                try await modelManager.downloadModel(model)
            } catch {
                statusMessage = "Download failed"
                return
            }
        }

        do {
            try transcriber.loadModel(at: modelManager.localModelPath(for: model))
            statusMessage = "Ready"
        } catch {
            statusMessage = "Failed to load model"
        }
    }
}
