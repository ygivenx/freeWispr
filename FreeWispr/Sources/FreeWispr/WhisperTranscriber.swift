import Foundation
import os.log
import SwiftWhisper

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "WhisperTranscriber")

enum TranscriberError: Error {
    case modelNotLoaded
    case transcriptionFailed(String)
    case timeout
    case alreadyTranscribing
}

class WhisperTranscriber: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isTranscribing = false

    private var whisper: Whisper?
    private var modelPath: URL?
    private var transcriptionCount = 0
    private let refreshInterval = 50
    private static let inferenceTimeout: TimeInterval = 30

    func loadModel(at path: URL) throws {
        let params = WhisperParams(strategy: .greedy)
        params.language = .english       // Skip auto-detection
        params.print_progress = false    // Silence progress spam
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = true     // Treat as one segment — faster

        whisper = Whisper(fromFileURL: path, withParams: params)
        modelPath = path
        transcriptionCount = 0
        // @Published mutations must happen on the main thread to avoid data races
        // with SwiftUI's attribute graph. loadModel() is synchronous and may be
        // called from a background thread (periodic model refresh inside transcribe()),
        // so use async dispatch rather than a blocking hop.
        DispatchQueue.main.async { [weak self] in self?.isModelLoaded = true }
    }

    func unloadModel() {
        whisper = nil
        modelPath = nil
        transcriptionCount = 0
        DispatchQueue.main.async { [weak self] in self?.isModelLoaded = false }
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let whisper = whisper else {
            throw TranscriberError.modelNotLoaded
        }

        // Prevent re-entrant calls: two concurrent whisper.cpp inference sessions
        // on the same context would corrupt its internal state.
        guard !isTranscribing else {
            throw TranscriberError.alreadyTranscribing
        }

        // @Published mutations must happen on the main thread. Set the flag
        // synchronously before the first suspension point so that any concurrent
        // main-actor check (e.g. AppState.startRecording) sees the correct state.
        await MainActor.run { isTranscribing = true }

        // Start a timeout task that cancels inference after 30s.
        // SwiftWhisper's cancel() uses whisper.cpp's abort callback for clean cancellation.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(Self.inferenceTimeout))
            logger.warning("Whisper inference timed out after \(Self.inferenceTimeout)s — cancelling")
            try? await whisper.cancel()
        }

        do {
            let segments = try await whisper.transcribe(audioFrames: audioSamples)
            timeoutTask.cancel()
            let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

            // Periodically recreate the whisper context to reclaim accumulated
            // memory from whisper.cpp's internal KV cache and Core ML encoder.
            // Best-effort: if reload fails, keep using the current context and
            // return the transcription we already have.
            transcriptionCount += 1
            if transcriptionCount >= refreshInterval, let path = modelPath {
                do {
                    try loadModel(at: path)
                } catch {
                    // Reload failed — continue with existing context.
                }
            }

            // Clear the flag on the main thread before returning so that the
            // caller (AppState.transcribeAndInject, @MainActor) sees isTranscribing
            // as false the moment this await returns — no scheduling gap.
            await MainActor.run { isTranscribing = false }
            return text
        } catch is CancellationError {
            await MainActor.run { isTranscribing = false }
            throw TranscriberError.timeout
        } catch WhisperError.cancelled {
            await MainActor.run { isTranscribing = false }
            throw TranscriberError.timeout
        } catch {
            timeoutTask.cancel()
            await MainActor.run { isTranscribing = false }
            throw error
        }
    }
}
