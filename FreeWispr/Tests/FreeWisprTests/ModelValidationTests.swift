import XCTest
@testable import FreeWisprCore

@MainActor
final class ModelValidationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - validateGGMLFile

    func testValidGGMLFile() throws {
        let file = tempDir.appendingPathComponent("valid.bin")
        // "ggml" magic bytes followed by some payload
        var data = Data([0x67, 0x67, 0x6D, 0x6C])
        data.append(Data(repeating: 0x00, count: 100))
        try data.write(to: file)

        let manager = ModelManager()
        XCTAssertNoThrow(try manager.validateGGMLFile(at: file))
        // File should still exist after successful validation
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testTruncatedFileThrowsAndDeletes() throws {
        let file = tempDir.appendingPathComponent("truncated.bin")
        // Only 2 bytes — too small for the 4-byte header
        try Data([0x67, 0x67]).write(to: file)

        let manager = ModelManager()
        XCTAssertThrowsError(try manager.validateGGMLFile(at: file)) { error in
            guard let dlError = error as? ModelDownloadError,
                  case .corruptedModel(let reason) = dlError else {
                return XCTFail("Expected corruptedModel error, got \(error)")
            }
            XCTAssertTrue(reason.contains("truncated"))
        }
        // File should be deleted after corruption detected
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWrongMagicBytesThrowsAndDeletes() throws {
        let file = tempDir.appendingPathComponent("wrong_magic.bin")
        // Valid size but wrong header
        try Data([0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF]).write(to: file)

        let manager = ModelManager()
        XCTAssertThrowsError(try manager.validateGGMLFile(at: file)) { error in
            guard let dlError = error as? ModelDownloadError,
                  case .corruptedModel(let reason) = dlError else {
                return XCTFail("Expected corruptedModel error, got \(error)")
            }
            XCTAssertTrue(reason.contains("Invalid GGML header"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingFileThrows() {
        let file = tempDir.appendingPathComponent("nonexistent.bin")

        let manager = ModelManager()
        XCTAssertThrowsError(try manager.validateGGMLFile(at: file)) { error in
            guard let dlError = error as? ModelDownloadError,
                  case .corruptedModel(let reason) = dlError else {
                return XCTFail("Expected corruptedModel error, got \(error)")
            }
            XCTAssertTrue(reason.contains("Cannot open"))
        }
    }

    func testEmptyFileThrowsAndDeletes() throws {
        let file = tempDir.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        let manager = ModelManager()
        XCTAssertThrowsError(try manager.validateGGMLFile(at: file)) { error in
            guard let dlError = error as? ModelDownloadError,
                  case .corruptedModel(let reason) = dlError else {
                return XCTFail("Expected corruptedModel error, got \(error)")
            }
            XCTAssertTrue(reason.contains("truncated"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - ModelDownloadError descriptions

    func testCorruptedModelErrorDescription() {
        let err = ModelDownloadError.corruptedModel("bad header")
        XCTAssertTrue(err.errorDescription?.contains("bad header") == true)
    }
}
