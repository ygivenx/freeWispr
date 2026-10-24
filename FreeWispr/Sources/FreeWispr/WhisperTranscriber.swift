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

final class WhisperTranscriber: ObservableObject {
    /// True while a model is configured (even if its context is temporarily freed
    /// by the idle unload) — i.e. transcribe() can succeed by lazily reloading.
    @Published var isModelLoaded = false
    @Published var isTranscribing = false

    private static let inferenceTimeout: TimeInterval = 30
    private let refreshInterval = 50

    /// Free the whisper context after this long without a load/transcription.
    var idleUnloadInterval: TimeInterval = 10 * 60

    // All mutable state below is guarded by `lock` so loads can run off the main thread.
    private let lock = NSLock()
    private var whisper: Whisper?
    private var modelPath: URL?
    private var transcriptionCount = 0
    private var activeTranscriptions = 0
    /// Bumped by loadModel/unloadModel; background loads and idle timers that
    /// captured an older value discard their result.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private static func makeWhisper(at path: URL) -> Whisper {
        let params = WhisperParams(strategy: .greedy)
        params.language = .english       // Skip auto-detection
        params.print_progress = false    // Silence progress spam
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = true     // Treat as one segment — faster
        return Whisper(fromFileURL: path, withParams: params)
    }

    private func publish(_ change: @escaping () -> Void) {
        if Thread.isMainThread { change() } else { DispatchQueue.main.async(execute: change) }
    }

    /// Synchronous load (blocks the caller). Prefer calling off the main thread.
    func loadModel(at path: URL) throws {
        let w = Self.makeWhisper(at: path)
        lock.lock()
        generation += 1
        loadTask?.cancel(); loadTask = nil
        whisper = w
        modelPath = path
        transcriptionCount = 0
        scheduleIdleUnloadLocked()
        lock.unlock()
        publish { self.isModelLoaded = true }
    }

    func unloadModel() {
        lock.lock()
        generation += 1
        loadTask?.cancel(); loadTask = nil
        idleTask?.cancel(); idleTask = nil
        whisper = nil
        modelPath = nil
        transcriptionCount = 0
        lock.unlock()
        publish { self.isModelLoaded = false }
    }

    /// Call on hotkey-down: if the context was freed, start reloading it in the
    /// background so it overlaps with the user speaking. No-op if loaded/loading.
    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        startLoadLocked()
    }

    @discardableResult
    private func startLoadLocked() -> Task<Void, Never>? {
        if whisper != nil { return nil }
        if let t = loadTask { return t }
        guard let path = modelPath else { return nil }
        let gen = generation
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let w = Self.makeWhisper(at: path)
            self?.finishLoad(w, generation: gen)
        }
        loadTask = task
        return task
    }

    /// Must hold `lock`. Restarts the idle countdown.
    private func scheduleIdleUnloadLocked() {
        idleTask?.cancel()
        let gen = generation
        let interval = idleUnloadInterval
        idleTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            self?.idleExpired(generation: gen, interval: interval)
        }
    }

    private func finishLoad(_ w: Whisper, generation gen: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == gen else { return }
        whisper = w
        transcriptionCount = 0
        loadTask = nil
        scheduleIdleUnloadLocked()
        logger.info("Whisper context reloaded")
    }

    private func idleExpired(generation gen: Int, interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        // Never free mid-transcription; a newer load/touch replaces this task.
        if generation == gen, activeTranscriptions == 0, whisper != nil {
            whisper = nil
            logger.info("Whisper context unloaded after \(Int(interval))s idle")
        }
    }

    private enum Acquire { case ready(Whisper), loading(Task<Void, Never>?), busy, none }

    // Synchronous so the lock is never held across an await.
    private func tryAcquire() -> Acquire {
        lock.lock()
        defer { lock.unlock() }
        // A whisper.cpp context runs one inference at a time.
        if activeTranscriptions > 0 { return .busy }
        if let w = whisper {
            activeTranscriptions += 1
            idleTask?.cancel(); idleTask = nil
            return .ready(w)
        }
        guard modelPath != nil else { return .none }
        return .loading(startLoadLocked())
    }

    private func acquireContext() async throws -> Whisper {
        while true {
            switch tryAcquire() {
            case .ready(let w): return w
            case .none: throw TranscriberError.modelNotLoaded
            case .busy: throw TranscriberError.alreadyTranscribing
            case .loading(let task):
                await task?.value
                try Task.checkCancellation()
            }
        }
    }

    private func releaseContext(refresh: Bool) {
        lock.lock()
        activeTranscriptions -= 1
        if refresh { transcriptionCount += 1 }
        if activeTranscriptions == 0 {
            if transcriptionCount >= refreshInterval, modelPath != nil {
                // Periodically recreate the context to reclaim whisper.cpp's KV cache
                // and Core ML encoder memory. Drop it and reload in the background
                // instead of blocking; a failure-free path since reload can't throw.
                whisper = nil
                logger.info("Refreshing whisper context after \(self.transcriptionCount) transcriptions")
                startLoadLocked()
            } else if whisper != nil {
                scheduleIdleUnloadLocked()
            }
        }
        lock.unlock()
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        let whisper = try await acquireContext()
        var completed = false
        defer { releaseContext(refresh: completed) }

        publish { self.isTranscribing = true }
        defer { publish { self.isTranscribing = false } }

        // Start a timeout task that cancels inference after 30s.
        // SwiftWhisper's cancel() uses whisper.cpp's abort callback for clean cancellation.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(Self.inferenceTimeout))
            logger.warning("Whisper inference timed out after \(Self.inferenceTimeout)s — cancelling")
            try? await whisper.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            let segments = try await whisper.transcribe(audioFrames: audioSamples)
            timeoutTask.cancel()
            completed = true
            return segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
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
