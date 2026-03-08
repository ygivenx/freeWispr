import Foundation

extension Foundation.Bundle {
    /// Locates the resource bundle correctly in both .app bundles and SPM dev builds.
    /// SPM's auto-generated Bundle.module uses bundleURL (the .app root), but signed
    /// .app bundles require resources inside Contents/Resources/.
    static let appResources: Bundle = {
        let bundleName = "FreeWispr_FreeWisprCore"

        // Contents/Resources/ — correct location in a signed .app bundle
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }

        // Fallback: SPM's generated Bundle.module (works in dev builds)
        return Bundle.module
    }()
}
