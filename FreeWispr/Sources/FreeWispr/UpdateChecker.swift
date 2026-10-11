import AppKit
import Foundation
import os.log
import Security

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "UpdateChecker")

/// How often to automatically check for updates in the background.
private let updateCheckInterval: TimeInterval = 4 * 60 * 60  // 4 hours

/// How long the updater script waits after the app quits before replacing the bundle.
private let updaterScriptDelay: TimeInterval = 1.5

@MainActor
class UpdateChecker: ObservableObject {
    @Published var latestVersion: String? = nil
    private var releaseURL: URL?
    @Published var isUpdating = false
    @Published var isInstalling = false

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return isNewer(latest, than: currentVersion)
    }

    let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    private let apiURL = URL(string: "https://api.github.com/repos/ygivenx/freeWispr/releases/latest")!
    private var dmgAssetURL: URL?
    private var periodicCheckTask: Task<Void, Never>?

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

    // MARK: - Periodic checks

    /// Start periodic background update checks at the given interval (default: every 4 hours).
    func startPeriodicChecks(interval: TimeInterval = updateCheckInterval) {
        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.checkForUpdate()
            }
        }
    }

    func stopPeriodicChecks() {
        periodicCheckTask?.cancel()
        periodicCheckTask = nil
    }

    // MARK: - Check

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

    // MARK: - Install

    func downloadAndInstall() async {
        guard !isUpdating else { return }
        guard let dmgURL = dmgAssetURL else {
            // Fallback: open release page
            if let url = releaseURL { NSWorkspace.shared.open(url) }
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: dmgURL, delegate: nil)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("FreeWispr-update.dmg")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)

            isInstalling = true

            // Attempt seamless in-place update; returns true if the updater script was launched
            let installed = await performSeamlessUpdate(dmgPath: dest)

            if installed {
                // Updater script is running; quit so it can replace the app
                try? FileManager.default.removeItem(at: dest)
                NSApp.terminate(nil)
            } else {
                // Fallback: open the DMG so the user can drag to /Applications
                logger.warning("Seamless update failed — falling back to manual install")
                isInstalling = false
                NSWorkspace.shared.open(dest)
            }
        } catch {
            isInstalling = false
            logger.error("Update download failed: \(error.localizedDescription)")
            if let url = releaseURL { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - Seamless install helpers

    /// Mount the DMG, verify the .app signature, copy it to a staging location, unmount,
    /// then launch a one-shot shell script that replaces the current app and relaunches it.
    /// Returns `true` when the updater script has been launched successfully.
    private nonisolated func performSeamlessUpdate(dmgPath: URL) async -> Bool {
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
            logger.error("hdiutil attach failed (exit \(mountProcess.terminationStatus))")
            return false
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.first(where: { $0["mount-point"] != nil })?["mount-point"] as? String
        else {
            logger.error("Could not parse DMG mount point")
            return false
        }

        // Find the .app bundle inside the mounted volume
        let mountURL = URL(fileURLWithPath: mountPoint)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil),
              let appURL = contents.first(where: { $0.pathExtension == "app" })
        else {
            logger.error("No .app found in mounted DMG")
            detachDMG(mountPoint: mountPoint)
            return false
        }

        // Verify code signature before installing
        if let teamID = expectedTeamID {
            guard verifyAppSignature(at: appURL, expectedTeamID: teamID) else {
                logger.error("Update signature verification failed — aborting")
                detachDMG(mountPoint: mountPoint)
                return false
            }
        } else {
            logger.warning("Cannot determine own Team ID — skipping signature verification")
        }

        // Stage the new app to the temp dir before unmounting the DMG
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeWispr-staged.app")
        do {
            try? FileManager.default.removeItem(at: stagingURL)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = [appURL.path, stagingURL.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                logger.error("ditto staging copy failed")
                detachDMG(mountPoint: mountPoint)
                return false
            }
        } catch {
            logger.error("Staging failed: \(error.localizedDescription)")
            detachDMG(mountPoint: mountPoint)
            return false
        }

        detachDMG(mountPoint: mountPoint)

        // Strip quarantine so the updated app launches without a Gatekeeper prompt
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", stagingURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // Install destination is the same .app path the running instance was launched from
        let destinationURL = Bundle.main.bundleURL

        // Validate the destination is a .app bundle to prevent accidental rm -rf on unexpected paths
        guard destinationURL.pathExtension == "app" else {
            logger.error("Unexpected bundle URL extension — aborting update for safety")
            return false
        }

        // Write a one-shot shell script: wait briefly, replace the app, reopen it.
        // A fixed name is used so stale scripts from previous failed updates are overwritten.
        let stagedPath = stagingURL.path.shellQuoted
        let destPath = destinationURL.path.shellQuoted
        let script = """
        #!/bin/sh
        sleep \(updaterScriptDelay)
        rm -rf \(destPath)
        mv \(stagedPath) \(destPath)
        open \(destPath)
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("freewispr-updater.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: scriptURL.path
            )
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = [scriptURL.path]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            try launcher.run()
            // Do not wait — the script runs after this process quits
        } catch {
            logger.error("Failed to launch updater script: \(error.localizedDescription)")
            return false
        }

        logger.info("Seamless update scheduled — app will relaunch after quit")
        return true
    }

    private nonisolated func detachDMG(mountPoint: String) {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint, "-quiet"]
        try? detach.run()
        detach.waitUntilExit()
    }

    /// Verify that the .app at `appURL` is signed by `expectedTeamID`.
    private nonisolated func verifyAppSignature(at appURL: URL, expectedTeamID: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            logger.error("Cannot create static code reference for \(appURL.lastPathComponent)")
            return false
        }

        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let req = secRequirement else {
            logger.error("Cannot create security requirement")
            return false
        }

        let status = SecStaticCodeCheckValidityWithErrors(
            code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req, nil)
        if status == errSecSuccess {
            logger.info("Update signature verified: Team ID \(expectedTeamID) matches")
            return true
        } else {
            logger.error("Signature verification failed (status: \(status)) for \(appURL.lastPathComponent)")
            return false
        }
    }

    // MARK: - Semver

    // Simple semver comparison: "1.2.3" > "1.1.0"
    func isNewer(_ candidate: String, than current: String) -> Bool {
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

// MARK: - Shell quoting helper

private extension String {
    /// Wraps the string in single quotes with proper escaping for POSIX shell.
    var shellQuoted: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
