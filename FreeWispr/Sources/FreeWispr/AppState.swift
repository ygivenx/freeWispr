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

        // Download default model if needed
        if !modelManager.isModelDownloaded(selectedModel) {
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
            print("[Pipeline] Recording started")
        } catch {
            statusMessage = "Mic error: \(error.localizedDescription)"
            print("[Pipeline] Mic error: \(error)")
        }
    }

    func stopAndTranscribe() {
        guard isRecording else { return }
        print("[Pipeline] Stopping recording...")
        audioRecorder.stopRecording()
    }

    private func transcribeAndInject(_ samples: [Float]) async {
        isRecording = false
        let durationSec = Double(samples.count) / 16000.0
        print("[Pipeline] Got \(samples.count) samples (\(String(format: "%.1f", durationSec))s audio)")

        guard !samples.isEmpty else {
            print("[Pipeline] Empty samples, skipping")
            statusMessage = "Ready"
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."

        do {
            let text = try await transcriber.transcribe(audioSamples: samples)
            print("[Pipeline] Transcription result: '\(text)'")
            if !text.isEmpty {
                print("[Pipeline] Injecting text into focused app...")
                textInjector.injectText(text)
                print("[Pipeline] Text injection done")
            } else {
                print("[Pipeline] Empty transcription result")
            }
            statusMessage = "Ready"
        } catch {
            print("[Pipeline] Transcription error: \(error)")
            statusMessage = "Transcription failed"
        }

        isTranscribing = false
    }

    func switchModel(to model: ModelSize) async {
        selectedModel = model
        transcriber.unloadModel()

        if !modelManager.isModelDownloaded(model) {
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
