import Foundation

enum ModelSize: String, CaseIterable, Identifiable {
    case tiny, base, small, medium

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "~75 MB"
        case .base: return "~142 MB"
        case .small: return "~466 MB"
        case .medium: return "~1.5 GB"
        }
    }
}

@MainActor
class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var currentModel: ModelSize = .base

    nonisolated let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FreeWispr/models")
    }

    nonisolated func downloadURL(for model: ModelSize) -> URL {
        URL(string: "\(baseURL)/ggml-\(model.rawValue).bin")!
    }

    nonisolated func coreMLDownloadURL(for model: ModelSize) -> URL {
        URL(string: "\(baseURL)/ggml-\(model.rawValue)-encoder.mlmodelc.zip")!
    }

    nonisolated func localModelPath(for model: ModelSize) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FreeWispr/models/ggml-\(model.rawValue).bin")
    }

    nonisolated func localCoreMLPath(for model: ModelSize) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FreeWispr/models/ggml-\(model.rawValue)-encoder.mlmodelc")
    }

    func isModelDownloaded(_ model: ModelSize) -> Bool {
        FileManager.default.fileExists(atPath: localModelPath(for: model).path)
    }

    func isCoreMLDownloaded(_ model: ModelSize) -> Bool {
        FileManager.default.fileExists(atPath: localCoreMLPath(for: model).path)
    }

    func downloadModel(_ model: ModelSize) async throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        // Download GGML model
        if !isModelDownloaded(model) {
            isDownloading = true
            downloadProgress = 0
            print("[ModelManager] Downloading GGML model: \(model.rawValue)")

            let delegate = DownloadProgressDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress * 0.7 // 70% for GGML
                }
            }
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL(for: model), delegate: delegate)
            try FileManager.default.moveItem(at: tempURL, to: localModelPath(for: model))
        }

        // Download Core ML encoder
        if !isCoreMLDownloaded(model) {
            print("[ModelManager] Downloading Core ML encoder: \(model.rawValue)")
            isDownloading = true

            let delegate = DownloadProgressDelegate { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = 0.7 + progress * 0.3 // Last 30%
                }
            }
            let (tempZip, _) = try await URLSession.shared.download(from: coreMLDownloadURL(for: model), delegate: delegate)

            // Unzip the Core ML model into the models directory
            let unzipDir = modelsDirectory
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", tempZip.path, "-d", unzipDir.path]
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                print("[ModelManager] Warning: unzip failed for Core ML model")
            } else {
                print("[ModelManager] Core ML encoder extracted to \(localCoreMLPath(for: model).path)")
            }

            try? FileManager.default.removeItem(at: tempZip)
        }

        downloadProgress = 1.0
        isDownloading = false
    }

    func deleteModel(_ model: ModelSize) throws {
        let path = localModelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

private class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        didCreateTask task: URLSessionTask
    ) {
        task.delegate = self
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {}
}

extension DownloadProgressDelegate: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }
}
