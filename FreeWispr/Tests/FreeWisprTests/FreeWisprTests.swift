import XCTest
import AppKit
@testable import FreeWisprCore

// MARK: - ModelDownloadError

final class ModelDownloadErrorTests: XCTestCase {

    func testUnzipErrorDescription() {
        let err = ModelDownloadError.unzipFailed(1)
        XCTAssertTrue(err.errorDescription?.contains("exit code 1") == true)
    }

    func testOutputMissingDescription() {
        let err = ModelDownloadError.outputMissing("/some/path")
        XCTAssertTrue(err.errorDescription?.contains("/some/path") == true)
    }

    func testCorruptedModelDescription() {
        let err = ModelDownloadError.corruptedModel("bad magic")
        XCTAssertTrue(err.errorDescription?.contains("bad magic") == true)
    }
}

// MARK: - ModelSize

final class ModelSizeTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(ModelSize.tiny.displayName, "Tiny")
        XCTAssertEqual(ModelSize.base.displayName, "Base")
        XCTAssertEqual(ModelSize.small.displayName, "Small")
        XCTAssertEqual(ModelSize.medium.displayName, "Medium")
    }

    func testSizeDescriptions() {
        XCTAssertEqual(ModelSize.tiny.sizeDescription, "~75 MB")
        XCTAssertEqual(ModelSize.base.sizeDescription, "~142 MB")
        XCTAssertEqual(ModelSize.small.sizeDescription, "~466 MB")
        XCTAssertEqual(ModelSize.medium.sizeDescription, "~1.5 GB")
    }

    func testAllCasesCount() {
        XCTAssertEqual(ModelSize.allCases.count, 4)
    }

    func testIdentifiable() {
        for size in ModelSize.allCases {
            XCTAssertEqual(size.id, size.rawValue)
        }
    }
}

// MARK: - TextInjector clipboard preservation

final class TextInjectorClipboardTests: XCTestCase {

    // After injection the restore timer should put back a plain string.
    func testStringClipboardRestored() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        TextInjector().injectText("dictated")

        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")

        let exp = expectation(description: "restored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // A third-party clipboard write during the delay must not be clobbered.
    func testClipboardNotRestoredIfModified() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        TextInjector().injectText("dictated")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pasteboard.clearContents()
            pasteboard.setString("third-party", forType: .string)
        }

        let exp = expectation(description: "not clobbered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            XCTAssertEqual(pasteboard.string(forType: .string), "third-party")
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    // Multi-type pasteboard items (e.g. image data alongside string) are preserved.
    func testRichItemsPreserved() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("rich", forType: .string)
        item.setData(Data([0xDE, 0xAD]), forType: .tiff)
        pasteboard.writeObjects([item])

        TextInjector().injectText("dictated")

        let exp = expectation(description: "rich restored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            XCTAssertEqual(pasteboard.string(forType: .string), "rich")
            XCTAssertEqual(pasteboard.data(forType: .tiff), Data([0xDE, 0xAD]))
            exp.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}
