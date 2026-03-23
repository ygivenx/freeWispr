#if canImport(FoundationModels)
import XCTest
@testable import FreeWisprCore

@available(macOS 26.0, *)
final class TextCorrectorTests: XCTestCase {

    // MARK: - looksLikeRefusal

    func testRefusalPrefixDetected() {
        XCTAssertTrue(TextCorrector.looksLikeRefusal("I apologize, but I can't do that.", originalText: "hello world"))
        XCTAssertTrue(TextCorrector.looksLikeRefusal("I'm sorry, I cannot process this.", originalText: "test input"))
        XCTAssertTrue(TextCorrector.looksLikeRefusal("I can't help with that request.", originalText: "some text"))
        XCTAssertTrue(TextCorrector.looksLikeRefusal("Certainly! Here is the corrected text:", originalText: "fix this"))
        XCTAssertTrue(TextCorrector.looksLikeRefusal("Here is the corrected version:", originalText: "my text"))
        XCTAssertTrue(TextCorrector.looksLikeRefusal("Of course! The corrected text is:", originalText: "dictated"))
    }

    func testRefusalNotFlaggedWhenOriginalHasSamePrefix() {
        // If the user actually dictated "I apologize", don't flag the correction
        XCTAssertFalse(TextCorrector.looksLikeRefusal("I apologize for the delay.", originalText: "I apologize for the delay"))
        XCTAssertFalse(TextCorrector.looksLikeRefusal("Sorry, I'm running late.", originalText: "Sorry, I'm running late"))
    }

    func testLongResponseFlaggedAsRefusal() {
        let original = "Fix the bug."
        let longResponse = String(repeating: "This is a very long explanation about why the code is broken and here is what you should do. ", count: 5)
        XCTAssertTrue(longResponse.count > original.count * 3)
        XCTAssertTrue(longResponse.count > 100)
        XCTAssertTrue(TextCorrector.looksLikeRefusal(longResponse, originalText: original))
    }

    func testShortLongResponseNotFlagged() {
        // Long response relative to input, but under 100 chars total — not flagged
        let original = "Hi"
        let response = "Hello there, how are you doing today?"
        XCTAssertFalse(TextCorrector.looksLikeRefusal(response, originalText: original))
    }

    func testNormalCorrectionNotFlagged() {
        XCTAssertFalse(TextCorrector.looksLikeRefusal("Hello, world.", originalText: "hello world"))
        XCTAssertFalse(TextCorrector.looksLikeRefusal("The quick brown fox.", originalText: "the quick brown fox"))
    }

    // MARK: - buildInstructions

    func testBuildInstructionsCodeEditor() {
        let instructions = TextCorrector.buildInstructions(appName: "Xcode", bundleID: "com.apple.dt.Xcode")
        XCTAssertTrue(instructions.contains("code editor"))
        XCTAssertTrue(instructions.contains("camelCase"))
        XCTAssertTrue(instructions.contains("Xcode"))
    }

    func testBuildInstructionsVSCode() {
        let instructions = TextCorrector.buildInstructions(appName: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
        XCTAssertTrue(instructions.contains("code editor"))
        XCTAssertTrue(instructions.contains("snake_case"))
    }

    func testBuildInstructionsBrowser() {
        let instructions = TextCorrector.buildInstructions(appName: "Safari", bundleID: "com.apple.Safari")
        XCTAssertTrue(instructions.contains("browser"))
        // Browser should NOT get the code-specific instructions
        XCTAssertFalse(instructions.contains("camelCase"))
    }

    func testBuildInstructionsMessaging() {
        let instructions = TextCorrector.buildInstructions(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(instructions.contains("messaging"))
    }

    func testBuildInstructionsUnknownApp() {
        let instructions = TextCorrector.buildInstructions(appName: "Notes", bundleID: "com.apple.Notes")
        XCTAssertTrue(instructions.contains("general writing"))
        XCTAssertTrue(instructions.contains("Notes"))
    }

    func testBuildInstructionsNilBundleIDWithAppName() {
        let instructions = TextCorrector.buildInstructions(appName: "MyApp", bundleID: nil)
        XCTAssertTrue(instructions.contains("MyApp"))
        XCTAssertFalse(instructions.contains("general writing"))
    }

    func testBuildInstructionsNilBoth() {
        let instructions = TextCorrector.buildInstructions(appName: nil, bundleID: nil)
        // Should contain base instructions but no app-specific context
        XCTAssertTrue(instructions.contains("FreeWispr"))
        XCTAssertFalse(instructions.contains("typing in"))
    }

    // MARK: - appTypeCategories coverage

    func testAllCategoryMappingsExist() {
        let categories = TextCorrector.appTypeCategories
        // Verify known bundle IDs are mapped
        XCTAssertEqual(categories["com.apple.dt.Xcode"], "code editor")
        XCTAssertEqual(categories["com.microsoft.VSCode"], "code editor")
        XCTAssertEqual(categories["com.googlecode.iterm2"], "code editor")
        XCTAssertEqual(categories["com.apple.Terminal"], "code editor")
        XCTAssertEqual(categories["com.apple.Safari"], "browser")
        XCTAssertEqual(categories["com.google.Chrome"], "browser")
        XCTAssertEqual(categories["company.thebrowser.Browser"], "browser")
        XCTAssertEqual(categories["org.mozilla.firefox"], "browser")
        XCTAssertEqual(categories["com.apple.MobileSMS"], "messaging")
        XCTAssertEqual(categories["com.tinyspeck.slackmacgap"], "messaging")
        XCTAssertEqual(categories["us.zoom.xos"], "messaging")
    }
}
#endif
