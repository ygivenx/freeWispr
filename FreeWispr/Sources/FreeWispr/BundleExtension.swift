import Foundation

extension Foundation.Bundle {
    /// Locates the resource bundle correctly in both .app bundles and SPM dev builds.
    /// Signed .app bundles keep resources inside Contents/Resources/.
    /// Returns main bundle as a safe fallback so callers can degrade gracefully.
    static let appResources: Bundle = {
        let bundleName = "FreeWispr_FreeWisprCore"

        // Contents/Resources/ — correct location in a signed .app bundle
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // SwiftPM/debug fallback: resource bundle adjacent to executable
        if let executableURL = Bundle.main.executableURL {
            let candidate = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(bundleName).bundle")
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }

        // Safe fallback: no crash if bundle is missing.
        return .main
    }()
}
