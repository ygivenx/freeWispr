import XCTest
@testable import FreeWisprCore

@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: - isNewer semver comparison

    func testNewerMajor() {
        let checker = UpdateChecker()
        XCTAssertTrue(checker.isNewer("2.0.0", than: "1.0.0"))
    }

    func testNewerMinor() {
        let checker = UpdateChecker()
        XCTAssertTrue(checker.isNewer("1.2.0", than: "1.1.0"))
    }

    func testNewerPatch() {
        let checker = UpdateChecker()
        XCTAssertTrue(checker.isNewer("1.1.1", than: "1.1.0"))
    }

    func testNotNewerWhenEqual() {
        let checker = UpdateChecker()
        XCTAssertFalse(checker.isNewer("1.2.0", than: "1.2.0"))
    }

    func testNotNewerWhenOlder() {
        let checker = UpdateChecker()
        XCTAssertFalse(checker.isNewer("1.0.0", than: "1.2.0"))
    }

    func testNewerWithDifferentLengths() {
        let checker = UpdateChecker()
        // "1.2" vs "1.1.5" — 1.2 is newer (missing .0 implied)
        XCTAssertTrue(checker.isNewer("1.2", than: "1.1.5"))
    }

    func testNewerWithFourSegments() {
        let checker = UpdateChecker()
        XCTAssertTrue(checker.isNewer("1.2.0.1", than: "1.2.0.0"))
    }

    func testNotNewerSingleDigit() {
        let checker = UpdateChecker()
        XCTAssertFalse(checker.isNewer("1", than: "2"))
    }

    // MARK: - updateAvailable

    func testUpdateAvailableWhenNoVersion() {
        let checker = UpdateChecker()
        // latestVersion is nil by default
        XCTAssertFalse(checker.updateAvailable)
    }
}
