import Foundation
import os.log
import SwiftWhisper

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "WhisperTranscriber")

enum TranscriberError: Error {
    case modelNotLoaded
    case transcriptionFailed(String)
    case timeout
}

class WhisperTranscriber: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isTranscribing = false

    private var whisper: Whisper?
    private static let inferenceTimeout: TimeInterval = 30

    func loadModel(at path: URL) throws {
        let params = WhisperParams(strategy: .greedy)
        params.language = .english       // Skip auto-detection
        params.print_progress = false    // Silence progress spam
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = true     // Treat as one segment — faster

        whisper = Whisper(fromFileURL: path, withParams: params)
        isModelLoaded = true
    }

    func unloadModel() {
        whisper = nil
        isModelLoaded = false
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let whisper = whisper else {
            throw TranscriberError.modelNotLoaded
        }

        isTranscribing = true
        defer { isTranscribing = false }

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
            return text
        } catch is CancellationError {
            throw TranscriberError.timeout
        } catch WhisperError.cancelled {
            throw TranscriberError.timeout
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }
}
