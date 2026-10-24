import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "AppleSpeechTranscriber")

struct AppleTranscription {
    let text: String
    /// Lowest / mean per-run confidence (0...1); nil if the framework reported none.
    let minConfidence: Double?
    let averageConfidence: Double?
}

enum AppleSpeechError: LocalizedError {
    case unsupportedLocale
    case noSession
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: return "Apple speech recognition does not support en-US on this Mac"
        case .noSession: return "No active Apple speech session"
        case .timedOut: return "Apple speech finalization timed out"
        }
    }
}

/// Streaming wrapper around macOS 26 SpeechAnalyzer/SpeechTranscriber. Audio is fed while
/// the hotkey is held so only finalization remains after release.
///
/// Threading: `beginSession`/`finish`/`cancel` are called from the main actor, `append` from
/// the audio converter's serial queue. All session state is guarded by `lock`, and a session
/// is detached from `current` before it is torn down, so a late `append` is a no-op.
@available(macOS 26.0, *)
final class AppleSpeechTranscriber: @unchecked Sendable {
    private static let locale = Locale(identifier: "en-US")
    private static let finishTimeout: Duration = .seconds(10)

    private struct Accumulated {
        var text = ""
        var confidences: [Double] = []
    }

    private final class Session {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let converter: AVAudioConverter?
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        var framesSent: Int64 = 0
        var startTask: Task<Void, Error>!
        var collector: Task<Accumulated, Error>!
        var previewTask: Task<Void, Never>?
        // Preview runs on its own analyzer: modules sharing one analyzer share one configuration,
        // so fastResults there would also degrade the final text.
        var previewAnalyzer: SpeechAnalyzer?
        var previewContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var previewStart: Task<Void, Error>?

        init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer,
             continuation: AsyncStream<AnalyzerInput>.Continuation,
             converter: AVAudioConverter?, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.continuation = continuation
            self.converter = converter
            self.inputFormat = inputFormat
            self.outputFormat = outputFormat
        }
    }

    /// Receives the live preview text (finalized so far + in-progress words) while a session
    /// is recording. Captured by `beginSession()`; called on an arbitrary thread, never after
    /// `finish()`/`cancel()` has detached that session.
    var onPartial: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var current: Session?
    private var analyzerFormat: AVAudioFormat?
    private var prepared = false

    /// True when the en-US locale is supported by SpeechTranscriber on this Mac.
    static func isSupported() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Final results only; they carry the confidence attribute that `finish()` reports.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.transcriptionConfidence])
    }

    /// Separate module for the live caption: fastResults cuts first-word latency from ~4 s to ~1 s
    /// but costs accuracy, so it never feeds the pasted text.
    private static func makePreviewTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    /// Installs the on-device model if missing and caches the analyzer's preferred audio format.
    func prepare() async throws {
        if lock.withLock({ prepared }) { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) else {
            throw AppleSpeechError.unsupportedLocale
        }
        let probe = Self.makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            logger.info("Installing Apple speech assets")
            try await request.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        lock.withLock {
            analyzerFormat = format
            prepared = true
        }
        logger.info("Apple speech ready, format: \(format?.description ?? "default", privacy: .public)")
    }

    func beginSession() throws {
        let (format, replaced): (AVAudioFormat?, Session?) = lock.withLock {
            let old = current
            current = nil
            return (analyzerFormat, old)
        }
        if let replaced { Self.teardown(replaced) }  // only one session at a time

        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                              channels: 1, interleaved: false) else {
            throw AppleSpeechError.noSession
        }
        let outputFormat = format ?? inputFormat
        var converter: AVAudioConverter?
        if outputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        let transcriber = Self.makeTranscriber(locale: Self.locale)
        let onPartial = self.onPartial
        let preview = onPartial == nil ? nil : Self.makePreviewTranscriber(locale: Self.locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let session = Session(transcriber: transcriber, analyzer: analyzer, continuation: continuation,
                              converter: converter, inputFormat: inputFormat, outputFormat: outputFormat)

        // Start the collectors before analysis so no result is missed.
        session.collector = Task {
            var acc = Accumulated()
            for try await result in transcriber.results where result.isFinal {
                acc.text += String(result.text.characters)
                for run in result.text.runs {
                    if let c = run.transcriptionConfidence { acc.confidences.append(c) }
                }
            }
            return acc
        }
        if let preview, let onPartial {
            session.previewTask = Task { [weak self, weak session] in
                var finalized = ""
                var volatile = ""  // each volatile result replaces the last until a final covers it
                do {
                    for try await result in preview.results {
                        if result.isFinal {
                            finalized += String(result.text.characters)
                            volatile = ""
                        } else {
                            volatile = String(result.text.characters)
                        }
                        // Under the lock so a partial can't land after finish()/cancel() detaches the session.
                        self?.lock.withLock {
                            if let session, self?.current === session { onPartial(finalized + volatile) }
                        }
                    }
                } catch {}  // preview is best-effort
            }
        }
        if let preview {
            let previewAnalyzer = SpeechAnalyzer(modules: [preview])
            let (pStream, pCont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            session.previewAnalyzer = previewAnalyzer
            session.previewContinuation = pCont
            session.previewStart = Task {
                try await previewAnalyzer.prepareToAnalyze(in: outputFormat)
                try await previewAnalyzer.start(inputSequence: pStream)
            }
        }
        // Prewarm, then start consuming. Audio appended meanwhile waits in the unbounded stream.
        session.startTask = Task {
            try await analyzer.prepareToAnalyze(in: outputFormat)
            try await analyzer.start(inputSequence: stream)
        }
        lock.withLock { current = session }
    }

    /// Feeds 16 kHz mono Float32 samples. Safe to call from any (serial) queue.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let session = current else { return }

        guard let input = AVAudioPCMBuffer(pcmFormat: session.inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        let buffer: AVAudioPCMBuffer
        if let converter = session.converter {
            let ratio = session.outputFormat.sampleRate / session.inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: session.outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, out.frameLength > 0 else {
                logger.error("Chunk conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            buffer = out
        } else {
            buffer = input
        }

        // Explicit start times keep the timeline contiguous regardless of delivery jitter.
        let start = CMTime(value: session.framesSent, timescale: CMTimeScale(session.outputFormat.sampleRate))
        session.framesSent += Int64(buffer.frameLength)
        let chunk = AnalyzerInput(buffer: buffer, bufferStartTime: start)
        session.continuation.yield(chunk)
        session.previewContinuation?.yield(chunk)
    }

    /// Ends input, finalizes, and returns the transcript. Throws on timeout (10 s) or analyzer error.
    func finish() async throws -> AppleTranscription {
        guard let session = lock.withLock({ () -> Session? in
            let s = current
            current = nil
            return s
        }) else { throw AppleSpeechError.noSession }

        session.continuation.finish()
        Self.stopPreview(session)  // preview isn't awaited: post-release latency stays unchanged
        do {
            let acc = try await withThrowingTaskGroup(of: Accumulated?.self) { group in
                group.addTask {
                    try await session.startTask.value
                    try await session.analyzer.finalizeAndFinishThroughEndOfInput()
                    return try await session.collector.value
                }
                group.addTask {
                    try await Task.sleep(for: Self.finishTimeout)
                    // The group waits for every child, so unblock a hung finalize before returning.
                    await session.analyzer.cancelAndFinishNow()
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let acc = first else {
                    throw AppleSpeechError.timedOut
                }
                return acc
            }
            let text = acc.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let conf = acc.confidences
            return AppleTranscription(
                text: text,
                minConfidence: conf.min(),
                averageConfidence: conf.isEmpty ? nil : conf.reduce(0, +) / Double(conf.count))
        } catch {
            logger.error("Finish failed: \(error.localizedDescription, privacy: .public)")
            Self.teardown(session)
            throw error
        }
    }

    /// Discards the current session (recording rejected or mic failed).
    func cancel() {
        guard let session = lock.withLock({ () -> Session? in
            let s = current
            current = nil
            return s
        }) else { return }
        Self.teardown(session)
    }

    private static func stopPreview(_ session: Session) {
        session.previewContinuation?.finish()
        guard let analyzer = session.previewAnalyzer else { return }
        Task {
            await analyzer.cancelAndFinishNow()
            session.previewStart?.cancel()
            session.previewTask?.cancel()
        }
    }

    private static func teardown(_ session: Session) {
        session.continuation.finish()
        stopPreview(session)
        Task {
            await session.analyzer.cancelAndFinishNow()
            session.startTask.cancel()
            session.collector.cancel()
            session.previewTask?.cancel()
        }
    }
}
