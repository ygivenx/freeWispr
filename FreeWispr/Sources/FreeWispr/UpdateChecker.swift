import AppKit
import Foundation
import os.log
import Security

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "UpdateChecker")

@MainActor
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String? = nil
    private var releaseURL: URL?
    @Published var isUpdating = false

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return isNewer(latest, than: currentVersion)
    }

    let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    private let apiURL = URL(string: "https://api.github.com/repos/ygivenx/freeWispr/releases/latest")!
    private var dmgAssetURL: URL?

    /// Expected Team ID for code signature verification.
    /// Extracted from the running app's own signature at init time.
    private let expectedTeamID: String? = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let staticCode = code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return teamID
    }()

    func checkForUpdate() async {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String,
              let url = URL(string: htmlURL)
        else { return }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestVersion = version
        releaseURL = url

        // Find .dmg asset URL (reset first to avoid stale values)
        dmgAssetURL = nil
        if let assets = json["assets"] as? [[String: Any]] {
            dmgAssetURL = assets
                .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap { URL(string: $0) }
        }
    }

    func downloadAndInstall() async {
        guard !isUpdating else { return }
        guard let dmgURL = dmgAssetURL else {
            // Fallback: open release page
            if let url = releaseURL { NSWorkspace.shared.open(url) }
            return
        }

        isUpdating = true

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: dmgURL, delegate: nil)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("FreeWispr-update.dmg")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)

            // Verify code signature of the .app inside the DMG before opening
            if let teamID = expectedTeamID {
                let verified = await verifyDMGSignature(at: dest, expectedTeamID: teamID)
                if !verified {
                    logger.error("Update signature verification failed — aborting")
                    try? FileManager.default.removeItem(at: dest)
                    isUpdating = false
                    if let url = releaseURL { NSWorkspace.shared.open(url) }
                    return
                }
            } else {
                logger.warning("Cannot determine own Team ID — skipping signature verification")
            }

            // Open the DMG — macOS mounts it, user sees the drag-to-install window
            NSWorkspace.shared.open(dest)
            isUpdating = false
        } catch {
            isUpdating = false
            // Fallback: open release page
            if let url = releaseURL { NSWorkspace.shared.open(url) }
        }
    }

    /// Mount a DMG, find the .app inside, verify its code signature matches the expected Team ID.
    private nonisolated func verifyDMGSignature(at dmgPath: URL, expectedTeamID: String) async -> Bool {
        // Mount the DMG
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", dmgPath.path, "-nobrowse", "-readonly", "-plist"]
        let pipe = Pipe()
        mountProcess.standardOutput = pipe

        do {
            try mountProcess.run()
            mountProcess.waitUntilExit()
        } catch {
            logger.error("Failed to mount DMG: \(error.localizedDescription)")
            return false
        }

        guard mountProcess.terminationStatus == 0 else {
            logger.error("hdiutil attach failed with exit code \(mountProcess.terminationStatus)")
            return false
        }

        // Parse mount point from plist output
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.first(where: { $0["mount-point"] != nil })?["mount-point"] as? String
        else {
            logger.error("Could not parse DMG mount point")
            return false
        }

        defer {
            // Always detach the DMG
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
        }

        // Find .app bundle inside the mount point
        let mountURL = URL(fileURLWithPath: mountPoint)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil),
              let appURL = contents.first(where: { $0.pathExtension == "app" })
        else {
            logger.error("No .app found in mounted DMG")
            return false
        }

        // Verify code signature
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            logger.error("Cannot create static code reference for \(appURL.lastPathComponent)")
            return false
        }

        // Validate the signature is valid
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let req = secRequirement else {
            logger.error("Cannot create security requirement")
            return false
        }

        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req, nil)
        if status == errSecSuccess {
            logger.info("Update signature verified: Team ID \(expectedTeamID) matches")
            return true
        } else {
            logger.error("Signature verification failed (status: \(status)) for \(appURL.lastPathComponent)")
            return false
        }
    }

    // Simple semver comparison: "1.2.3" > "1.1.0"
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
