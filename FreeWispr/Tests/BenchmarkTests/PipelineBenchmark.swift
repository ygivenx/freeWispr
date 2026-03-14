// Full Pipeline Benchmark: WAV → Whisper → TextCorrector
// Run: cd FreeWispr && swift test --filter BenchmarkTests

import XCTest
@testable import FreeWisprCore

private func loadWAV(at path: URL) throws -> [Float] {
    let data = try Data(contentsOf: path)
    guard data.count >= 44 else { fatalError("WAV too small") }

    let riff = String(data: data[0..<4], encoding: .ascii)
    let wave = String(data: data[8..<12], encoding: .ascii)
    guard riff == "RIFF", wave == "WAVE" else { fatalError("Not a WAV") }

    var offset = 12
    while offset + 8 < data.count {
        let chunkID = String(data: data[offset..<offset+4], encoding: .ascii)
        let chunkSize = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset + 4, as: UInt32.self)
        }
        if chunkID == "data" {
            let dataStart = offset + 8
            let dataEnd = min(dataStart + Int(chunkSize), data.count)
            let pcmData = data[dataStart..<dataEnd]
            let sampleCount = pcmData.count / 2
            var samples = [Float](repeating: 0, count: sampleCount)
            pcmData.withUnsafeBytes { raw in
                let int16Ptr = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    samples[i] = Float(int16Ptr[i]) / 32768.0
                }
            }
            return samples
        }
        offset += 8 + Int(chunkSize)
    }
    fatalError("No data chunk")
}

/// Normalized character edit distance on lowercased, whitespace-normalized text.
/// Returns 0.0 for identical strings, 1.0 when completely different.
private func computeCER(reference: String, hypothesis: String) -> Double {
    func normalize(_ s: String) -> [Character] {
        Array(s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " "))
    }
    let ref = normalize(reference), hyp = normalize(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }
    let m = ref.count, n = hyp.count
    var prev = Array(0...n), curr = [Int](repeating: 0, count: n + 1)
    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            curr[j] = ref[i-1] == hyp[j-1] ? prev[j-1] : 1 + min(prev[j], curr[j-1], prev[j-1])
        }
        prev = curr
    }
    return Double(prev[n]) / Double(m)
}

final class PipelineBenchmark: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        return super.defaultTestSuite
    }

    @MainActor
    func testFullPipeline() async throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dataDir = repoRoot.appendingPathComponent("scripts/benchmark-data")

        let fm = FileManager.default
        guard fm.fileExists(atPath: dataDir.path) else {
            throw XCTSkip("Benchmark data not downloaded yet")
        }

        let wavFiles = try fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !wavFiles.isEmpty else {
            throw XCTSkip("No WAV files")
        }

        let modelSizeName = ProcessInfo.processInfo.environment["BENCHMARK_MODEL"] ?? "base"
        guard let modelSize = ModelSize(rawValue: modelSizeName) else {
            throw XCTSkip("Unknown model size: \(modelSizeName)")
        }
        let modelManager = ModelManager()
        let modelPath = modelManager.localModelPath(for: modelSize)

        guard fm.fileExists(atPath: modelPath.path) else {
            throw XCTSkip("Whisper model not found")
        }

        print("\nFull Pipeline Benchmark")
        print(String(repeating: "=", count: 70))
        print("Model: \(modelSizeName)  |  Samples: \(wavFiles.count)")
        print(String(repeating: "=", count: 70))
        print()

        let transcriber = WhisperTranscriber()
        try await transcriber.loadModel(at: modelPath)

        var correctorAvailable = false
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let c = TextCorrector()
            correctorAvailable = c.isAvailable
        }
        #endif

        if !correctorAvailable {
            print("NOTE: TextCorrector unavailable — showing Whisper-only results")
            print()
        }

        var totalWhisperTime: Double = 0
        var totalCorrectionTime: Double = 0
        var totalRawCER: Double = 0
        var totalOutCER: Double = 0
        var tsvRows: [String] = []

        for (i, wavFile) in wavFiles.enumerated() {
            let stem = wavFile.deletingPathExtension().lastPathComponent
            let txtFile = dataDir.appendingPathComponent("\(stem).txt")

            let groundTruth = (try? String(contentsOf: txtFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no ground truth)"

            let samples = try loadWAV(at: wavFile)

            let whisperStart = CFAbsoluteTimeGetCurrent()
            let rawText = try await transcriber.transcribe(audioSamples: samples)
            let whisperTime = CFAbsoluteTimeGetCurrent() - whisperStart
            totalWhisperTime += whisperTime

            var correctedText = rawText
            var correctionTime: Double = 0

            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), correctorAvailable {
                let corrector = TextCorrector()
                let corrStart = CFAbsoluteTimeGetCurrent()
                correctedText = await corrector.correct(rawText)
                correctionTime = CFAbsoluteTimeGetCurrent() - corrStart
                totalCorrectionTime += correctionTime
            }
            #endif

            let rawCER = computeCER(reference: groundTruth, hypothesis: rawText)
            let outCER = computeCER(reference: groundTruth, hypothesis: correctedText)
            totalRawCER += rawCER
            totalOutCER += outCER

            let gt = groundTruth.replacingOccurrences(of: "\t", with: " ")
            let rawTsv = rawText.replacingOccurrences(of: "\t", with: " ")
            let outTsv = correctedText.replacingOccurrences(of: "\t", with: " ")
            tsvRows.append("\(i+1)\t\(stem)\t\(String(format: "%.2f", whisperTime))\t\(String(format: "%.2f", correctionTime))\t\(String(format: "%.3f", rawCER))\t\(String(format: "%.3f", outCER))\t\(gt)\t\(rawTsv)\t\(outTsv)")

            let timingStr: String
            if correctorAvailable {
                timingStr = "whisper: \(String(format: "%.2f", whisperTime))s, correction: \(String(format: "%.2f", correctionTime))s, rawCER: \(String(format: "%.1f", rawCER * 100))%, outCER: \(String(format: "%.1f", outCER * 100))%"
            } else {
                timingStr = "whisper: \(String(format: "%.2f", whisperTime))s, CER: \(String(format: "%.1f", rawCER * 100))%"
            }

            print("[\(i + 1)] \(stem) (\(timingStr))")
            print("  GT:  \(groundTruth)")
            print("  RAW: \(rawText)")
            if correctorAvailable {
                print("  OUT: \(correctedText)")
            }
            print()
        }

        print(String(repeating: "=", count: 70))
        let totalTime = totalWhisperTime + totalCorrectionTime
        print("Total time:        \(String(format: "%.2f", totalTime))s")
        print("  Whisper:         \(String(format: "%.2f", totalWhisperTime))s (avg \(String(format: "%.2f", totalWhisperTime / Double(wavFiles.count)))s)")
        if correctorAvailable {
            print("  Correction:      \(String(format: "%.2f", totalCorrectionTime))s (avg \(String(format: "%.2f", totalCorrectionTime / Double(wavFiles.count)))s)")
        }
        let n = Double(wavFiles.count)
        print(String(format: "Avg RAW CER:       %.1f%%", totalRawCER / n * 100))
        if correctorAvailable {
            print(String(format: "Avg OUT CER:       %.1f%%", totalOutCER / n * 100))
        }
        print("Samples:           \(wavFiles.count)")

        // Save TSV
        let tsvHeader = "#\tsample\twhisper_s\tcorrection_s\traw_cer\tout_cer\tground_truth\traw\tcorrected"
        let tsvContent = ([tsvHeader] + tsvRows).joined(separator: "\n") + "\n"
        let tsvPath = repoRoot.appendingPathComponent("scripts/benchmark-results.tsv")
        try tsvContent.write(to: tsvPath, atomically: true, encoding: .utf8)
        print("\nTSV saved to: \(tsvPath.path)")
    }
}
