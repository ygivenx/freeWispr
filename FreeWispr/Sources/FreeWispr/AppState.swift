import AppKit
import AVFoundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "AppState")

/// Which engine turns speech into text. `.apple` is macOS 26+ only.
enum TranscriptionEngine: Hashable {
    case apple
    case whisper(ModelSize)
}

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isSwitchingModel = false
    @Published var statusMessage = "Ready"
    @Published var selectedModel: ModelSize = .base
    @Published var engine: TranscriptionEngine = .whisper(.base)
    /// True when SpeechTranscriber supports en-US on this Mac (macOS 26+).
    @Published var appleAvailable = false

    enum AICorrectionStatus {
        case unavailable  // not macOS 26+
        case needsSetup   // macOS 26+ but Apple Intelligence not enabled
        case active       // working
    }
    @Published var aiCorrectionStatus: AICorrectionStatus = .unavailable
    @Published var aiCorrectionEnabled = false

    private var isSetUp = false
    private var isProcessingRecording = false
    private var textCorrector: Any?
    /// AppleSpeechTranscriber (macOS 26+), stored untyped to avoid availability on the property.
    private var appleTranscriber: Any?
    /// Engine in use for the current recording, so a mid-flight switch can't mix paths.
    private var recordingEngine: TranscriptionEngine = .whisper(.base)
    private static let engineDefaultsKey = "transcriptionEngine"
    /// AI Cleanup runs on Apple results only when the weakest run is below this confidence.
    /// Benchmark: same accuracy gain as always-on while skipping ~32% of ~0.86 s LLM calls.
    private static let cleanupConfidenceThreshold = 0.7
    /// More than this fraction of clipped samples triggers the "lower input volume" hint.
    private static let clippingWarnFraction = 0.001
    /// Frontmost app captured at recording start for focus check and LLM context
    private var recordingTargetAppName: String?
    private var recordingTargetBundleID: String?

    let hotkeyManager = HotkeyManager()
    // People release the key slightly before finishing the last word.
    let audioRecorder = AudioRecorder(releaseTail: 0.25)
    let transcriber = WhisperTranscriber()
    let textInjector = TextInjector()
    let modelManager = ModelManager()
    let updateChecker = UpdateChecker()
    private let recordingIndicator = RecordingIndicator()
    /// Identifies the recording whose Apple partials may update the caption.
    private var previewSessionID: UUID?

    func setup() async {
        guard !isSetUp else { return }
        isSetUp = true

        // Check accessibility permission
        if !HotkeyManager.checkAccessibilityPermission() {
            statusMessage = "Needs Accessibility permission"
        }

        // Pick the engine: Apple speech by default when supported, unless the user chose Whisper.
        if #available(macOS 26.0, *), await AppleSpeechTranscriber.isSupported() {
            appleAvailable = true
            let wantsWhisper = UserDefaults.standard.string(forKey: Self.engineDefaultsKey) == "whisper"
            if !wantsWhisper {
                statusMessage = "Preparing Apple speech..."
                let apple = AppleSpeechTranscriber()
                do {
                    try await apple.prepare()
                    appleTranscriber = apple
                    engine = .apple
                } catch {
                    logger.error("Apple speech prepare failed, using Whisper: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Whisper is only downloaded/loaded when it is the active engine.
        if case .whisper = engine {
            engine = .whisper(selectedModel)
            if !modelManager.isModelDownloaded(selectedModel) || !modelManager.isCoreMLDownloaded(selectedModel) {
                statusMessage = "Downloading \(selectedModel.displayName) model..."
                do {
                    try await modelManager.downloadModel(selectedModel)
                } catch {
                    statusMessage = "Model download failed: \(error.localizedDescription)"
                    return
                }
            }

            do {
                try await loadWhisper(selectedModel)
            } catch {
                statusMessage = "Failed to load model: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = "Ready"

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
        startHotkeyListener()

        // Reserve the pipeline synchronously before scheduling transcription.
        audioRecorder.onRecordingComplete = { [weak self] samples in
            guard let self, !self.isProcessingRecording else { return }
            self.isRecording = false
            self.recordingIndicator.hide()
            self.isProcessingRecording = true
            Task { @MainActor in
                defer { self.isProcessingRecording = false }
                await self.transcribeAndInject(samples)
            }
        }
        audioRecorder.onRecordingInterrupted = { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.previewSessionID = nil
            self.recordingIndicator.hide()
            self.audioRecorder.onChunk = nil
            self.cancelAppleSession()
            self.showTemporaryStatus("Microphone changed — try recording again")
        }

        Task { await updateChecker.checkForUpdate() }
    }

    /// An untrusted app still gets an event tap, but macOS leaves it disabled forever. Only
    /// create it once Accessibility is granted, polling so no relaunch is needed after granting.
    private func startHotkeyListener() {
        if AXIsProcessTrusted(), hotkeyManager.start() { return }
        statusMessage = "Needs Accessibility permission"
        Task {
            while !(AXIsProcessTrusted() && hotkeyManager.start()) {
                try? await Task.sleep(for: .seconds(2))
            }
            statusMessage = "Ready"
        }
    }

    /// Apple prepared, or a Whisper model configured (its context may reload lazily).
    private var isEngineReady: Bool {
        switch engine {
        case .apple: return appleTranscriber != nil
        case .whisper: return transcriber.isModelLoaded
        }
    }

    func startRecording() {
        guard isSetUp, isEngineReady,
              !isRecording, !isTranscribing, !isProcessingRecording, !isSwitchingModel else { return }

        // Capture frontmost app on @MainActor for thread-safe use in LLM context and focus check
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        recordingTargetBundleID = frontmostApp?.bundleIdentifier
        recordingTargetAppName = frontmostApp?.localizedName

        recordingEngine = engine
        audioRecorder.onChunk = nil
        switch engine {
        case .apple:
            // Stream audio to the recognizer while the key is held.
            if #available(macOS 26.0, *), let apple = appleTranscriber as? AppleSpeechTranscriber {
                do {
                    // Live preview: only while this exact recording is still active, so a late
                    // partial after release (or during the next recording) can't show stale text.
                    let sessionID = UUID()
                    previewSessionID = sessionID
                    apple.onPartial = { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.isRecording, self.previewSessionID == sessionID else { return }
                            self.recordingIndicator.updatePreview(text)
                        }
                    }
                    try apple.beginSession()
                    audioRecorder.onChunk = { apple.append($0) }
                } catch {
                    logger.error("Apple session start failed: \(error.localizedDescription, privacy: .public)")
                    statusMessage = "Transcription failed — try again"
                    return
                }
            }
        case .whisper:
            transcriber.prewarm()  // reload overlaps with the user speaking if idle-unloaded
        }

        do {
            try audioRecorder.startRecording()
            isRecording = true
            statusMessage = "Listening..."
            recordingIndicator.show()
        } catch AudioRecorderError.micInUse {
            audioRecorder.onChunk = nil
            cancelAppleSession()
            showTemporaryStatus("Mic busy — another app is using the microphone")
        } catch {
            logger.error("Microphone start failed: \(String(describing: error), privacy: .public)")
            audioRecorder.onChunk = nil
            cancelAppleSession()
            showTemporaryStatus("Mic error — check the input device and retry")
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

    private func cancelAppleSession() {
        if #available(macOS 26.0, *), let apple = appleTranscriber as? AppleSpeechTranscriber {
            apple.cancel()
        }
    }

    private func finishAppleSession() async throws -> AppleTranscription {
        guard #available(macOS 26.0, *), let apple = appleTranscriber as? AppleSpeechTranscriber else {
            throw AppleSpeechError.noSession
        }
        return try await apple.finish()
    }

    private func transcribeAndInject(_ samples: [Float]) async {
        isRecording = false
        previewSessionID = nil
        recordingIndicator.hide()
        let usesApple = recordingEngine == .apple
        guard !isTranscribing else {
            if usesApple { cancelAppleSession() }
            return
        }
        guard !samples.isEmpty else {
            if usesApple { cancelAppleSession() }
            statusMessage = "Ready"
            return
        }

        // Reject recordings that are too short (< 0.3s)
        guard samples.count >= Self.minSampleCount else {
            if usesApple { cancelAppleSession() }
            showTemporaryStatus("Didn't catch that — hold longer")
            return
        }

        let analysis = AudioPreprocessor.analyze(samples)

        // Whisper hallucinates on silence, so gate it; Apple returns empty text instead.
        if !usesApple && !analysis.hasSpeech {
            showTemporaryStatus("Too quiet — speak louder or check mic")
            return
        }

        isTranscribing = true
        statusMessage = "Transcribing..."

        do {
            let text: String
            let wantsCleanup: Bool
            if usesApple {
                let r = try await finishAppleSession()
                text = r.text
                wantsCleanup = r.minConfidence.map { $0 < Self.cleanupConfidenceThreshold } ?? true
            } else {
                text = try await transcriber.transcribe(audioSamples: AudioPreprocessor.prepareForBatch(samples).samples)
                wantsCleanup = true
            }

            if text.isEmpty {
                if usesApple {
                    showTemporaryStatus(analysis.hasSpeech ? "Didn't catch that — try again"
                                                           : "Too quiet — speak louder or check mic")
                } else {
                    statusMessage = "Ready"
                }
            } else {
                var finalText = text
                // Terminal command mode: format spoken commands and skip the LLM (it would mangle them).
                let terminalCommand = recordingTargetBundleID.flatMap {
                    TerminalCommandFormatter.terminalBundleIDs.contains($0) ? TerminalCommandFormatter.format(text) : nil
                }
                if let terminalCommand { finalText = terminalCommand }
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *),
                   terminalCommand == nil,
                   aiCorrectionEnabled, wantsCleanup,
                   let corrector = textCorrector as? TextCorrector {
                    statusMessage = "Correcting..."
                    finalText = await corrector.correct(text, appName: recordingTargetAppName, bundleID: recordingTargetBundleID)
                }
                #endif
                textInjector.injectText(finalText)
                if analysis.clippedFraction > Self.clippingWarnFraction {
                    showTemporaryStatus("Mic is clipping — lower input volume", duration: 4.0)
                } else {
                    statusMessage = "Ready"
                }
            }
        } catch TranscriberError.timeout {
            logger.warning("Whisper inference timed out")
            showTemporaryStatus("Transcription timed out")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            showTemporaryStatus("Transcription failed — try again")
        }

        isTranscribing = false
    }

    /// Loads Whisper off the main thread (~1 s of synchronous work).
    private func loadWhisper(_ model: ModelSize) async throws {
        let transcriber = self.transcriber
        let path = modelManager.localModelPath(for: model)
        try await Task.detached { try transcriber.loadModel(at: path) }.value
    }

    func switchEngine(to target: TranscriptionEngine) async {
        guard !isSwitchingModel, !isRecording, !isTranscribing, !isProcessingRecording,
              target != engine else { return }
        isSwitchingModel = true
        defer { isSwitchingModel = false }

        switch target {
        case .apple:
            guard #available(macOS 26.0, *) else { return }
            statusMessage = "Preparing Apple speech..."
            let apple = (appleTranscriber as? AppleSpeechTranscriber) ?? AppleSpeechTranscriber()
            do {
                try await apple.prepare()
            } catch {
                statusMessage = "Apple speech failed: \(error.localizedDescription)"
                return
            }
            appleTranscriber = apple
            transcriber.unloadModel()  // Apple users shouldn't pay for a resident Whisper context
            engine = .apple

        case .whisper(let model):
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
                try await loadWhisper(model)
                selectedModel = model   // Commit only after successful load
                engine = target
            } catch {
                statusMessage = "Failed to load model: \(error.localizedDescription)"
                return
            }
        }
        UserDefaults.standard.set(target == .apple ? "apple" : "whisper", forKey: Self.engineDefaultsKey)
        statusMessage = "Ready"
    }
}
