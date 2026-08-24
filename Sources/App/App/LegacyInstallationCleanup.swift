import Cocoa
import Foundation

/// Removes a separately installed, verified legacy app after the one-time data
/// import and only with explicit user approval. Application Support and
/// Preferences are intentionally left untouched by this cleanup step.
enum LegacyInstallationCleanup {
    static let currentBundleIdentifier = "com.actionhalo.app"
    static let currentApplicationFileName = "ActionHalo.app"
    static let legacyBundleIdentifier = "com.openfire.app"
    static let legacyApplicationFileName = "OpenFire.app"
    static let legacyLaunchAgentFileName = "com.openfire.app.plist"
    private static let maximumLaunchAgentBytes = 64 * 1024

    struct ApplicationBundleMetadata: Equatable, Sendable {
        let bundleIdentifier: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let volumeIsLocal: Bool
        let volumeIsReadOnly: Bool
    }

    struct Dependencies {
        let homeDirectory: URL
        let currentApplicationURL: URL
        let fileExists: (URL) -> Bool
        /// Reads filesystem and Info.plist metadata afresh for each check.
        let applicationBundleMetadata: (URL) -> ApplicationBundleMetadata?
        /// Validates the bounded, non-symlink property list and all three
        /// official OpenFire launch-agent keys afresh for each check.
        let isOfficialLegacyLaunchAgent: (URL) -> Bool
        let terminateApplications: (String) -> Bool
        let moveToTrash: (URL) throws -> Void
        let resetAccessibilityPermission: (String) throws -> Void
    }

    enum CleanupFailure: Equatable, Sendable {
        case currentInstallationNotEligible
        case identityValidationFailed(URL)
        case applicationTerminationFailed
        case trashFailed(URL, String)
        case accessibilityResetFailed(String)

        var summary: String {
            switch self {
            case .currentInstallationNotEligible:
                return "ActionHalo is not running from a verified writable local Applications folder."
            case .identityValidationFailed(let url):
                return "The item at \(url.path) changed identity and was not removed."
            case .applicationTerminationFailed:
                return "The legacy app is still running and could not be terminated."
            case .trashFailed(let url, let reason):
                return "Could not move \(url.path) to the Trash: \(reason)"
            case .accessibilityResetFailed(let reason):
                return "The old Accessibility permission could not be reset: \(reason)"
            }
        }
    }

    enum CleanupOutcome: Equatable, Sendable {
        case success(trashedItems: [URL])
        case failure(CleanupFailure)
    }

    private enum LiveOperationError: LocalizedError {
        case accessibilityResetExitStatus(Int32)

        var errorDescription: String? {
            switch self {
            case .accessibilityResetExitStatus(let status):
                return "tccutil exited with status \(status)"
            }
        }
    }

    static func candidateApplicationURLs(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(legacyApplicationFileName, isDirectory: true),
            homeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(legacyApplicationFileName, isDirectory: true)
        ]
    }

    static func installedCurrentApplicationURLs(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(currentApplicationFileName, isDirectory: true),
            homeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(currentApplicationFileName, isDirectory: true)
        ]
    }

    static func isEligibleCurrentInstallation(
        dependencies: Dependencies
    ) -> Bool {
        let currentURL = dependencies.currentApplicationURL.standardizedFileURL
        let allowedURLs = Set(
            installedCurrentApplicationURLs(homeDirectory: dependencies.homeDirectory)
                .map { $0.standardizedFileURL.path }
        )
        guard allowedURLs.contains(currentURL.path),
              dependencies.fileExists(currentURL),
              let metadata = dependencies.applicationBundleMetadata(currentURL) else {
            return false
        }
        return metadata.bundleIdentifier == currentBundleIdentifier &&
            metadata.isDirectory &&
            !metadata.isSymbolicLink &&
            metadata.volumeIsLocal &&
            !metadata.volumeIsReadOnly
    }

    static func launchAgentURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(legacyLaunchAgentFileName)
    }

    static func isOfficialLegacyLaunchAgentPropertyList(
        _ propertyList: Any
    ) -> Bool {
        let requiredKeys: Set<String> = ["Label", "ProgramArguments", "RunAtLoad"]
        guard let dictionary = propertyList as? [String: Any],
              Set(dictionary.keys) == requiredKeys,
              dictionary["Label"] as? String == legacyBundleIdentifier,
              dictionary["ProgramArguments"] as? [String] == [
                  "/usr/bin/open",
                  "-b",
                  legacyBundleIdentifier,
              ],
              let runAtLoad = dictionary["RunAtLoad"] as? NSNumber,
              CFGetTypeID(runAtLoad) == CFBooleanGetTypeID(),
              runAtLoad.boolValue else {
            return false
        }
        return true
    }

    static func detectedLegacyApplications(
        candidateURLs: [URL],
        dependencies: Dependencies
    ) -> [URL] {
        let currentApplicationPath = dependencies.currentApplicationURL
            .standardizedFileURL.path
        var seenPaths = Set<String>()
        return candidateURLs.compactMap { candidateURL in
            let standardizedURL = candidateURL.standardizedFileURL
            guard standardizedURL.path != currentApplicationPath,
                  seenPaths.insert(standardizedURL.path).inserted,
                  dependencies.fileExists(standardizedURL),
                  let metadata = dependencies.applicationBundleMetadata(standardizedURL),
                  metadata.bundleIdentifier == legacyBundleIdentifier,
                  metadata.isDirectory,
                  !metadata.isSymbolicLink else {
                return nil
            }
            return standardizedURL
        }
    }

    static func performCleanup(
        applications: [URL],
        launchAgentURL: URL,
        dependencies: Dependencies
    ) -> CleanupOutcome {
        guard isEligibleCurrentInstallation(dependencies: dependencies) else {
            return .failure(.currentInstallationNotEligible)
        }

        var seenPaths = Set<String>()
        let allowedApplicationPaths = Set(
            candidateApplicationURLs(homeDirectory: dependencies.homeDirectory)
                .map { $0.standardizedFileURL.path }
        )
        let candidates = applications
            .map(\.standardizedFileURL)
            .filter { allowedApplicationPaths.contains($0.path) }
            .filter { seenPaths.insert($0.path).inserted }

        // A verified OpenFire.app is the authorization boundary for every
        // cleanup side effect. A leftover filename or defaults domain is not.
        guard !candidates.isEmpty else {
            return .success(trashedItems: [])
        }

        if let invalidURL = firstIdentityMismatch(
            in: candidates,
            dependencies: dependencies
        ) {
            return .failure(.identityValidationFailed(invalidURL))
        }

        // Revalidate after the initial authorization check. A replacement is
        // an error; a bundle that disappeared before side effects is a no-op.
        if let invalidURL = firstIdentityMismatch(
            in: candidates,
            dependencies: dependencies
        ) {
            return .failure(.identityValidationFailed(invalidURL))
        }
        let verifiedApplications = candidates.filter(dependencies.fileExists)
        guard !verifiedApplications.isEmpty else {
            return .success(trashedItems: [])
        }

        let standardizedLaunchAgentURL = launchAgentURL.standardizedFileURL
        let expectedLaunchAgentURL = self.launchAgentURL(
            homeDirectory: dependencies.homeDirectory
        ).standardizedFileURL
        let hasOfficialLaunchAgent = standardizedLaunchAgentURL == expectedLaunchAgentURL &&
            dependencies.fileExists(standardizedLaunchAgentURL) &&
            dependencies.isOfficialLegacyLaunchAgent(standardizedLaunchAgentURL)

        // Termination is deliberately ordered before every filesystem mutation.
        guard dependencies.terminateApplications(legacyBundleIdentifier) else {
            return .failure(.applicationTerminationFailed)
        }

        var trashedItems: [URL] = []
        for applicationURL in verifiedApplications
            where dependencies.fileExists(applicationURL) {
            // Revalidate immediately before trashing to avoid trusting the
            // identity observed when the prompt was first displayed.
            guard let metadata = dependencies.applicationBundleMetadata(applicationURL),
                  metadata.bundleIdentifier == legacyBundleIdentifier,
                  metadata.isDirectory,
                  !metadata.isSymbolicLink else {
                return .failure(.identityValidationFailed(applicationURL))
            }
            do {
                try dependencies.moveToTrash(applicationURL)
                trashedItems.append(applicationURL)
            } catch {
                return .failure(.trashFailed(applicationURL, error.localizedDescription))
            }
        }

        if hasOfficialLaunchAgent && dependencies.fileExists(standardizedLaunchAgentURL) {
            guard dependencies.isOfficialLegacyLaunchAgent(standardizedLaunchAgentURL) else {
                return .failure(.identityValidationFailed(standardizedLaunchAgentURL))
            }
            do {
                try dependencies.moveToTrash(standardizedLaunchAgentURL)
                trashedItems.append(standardizedLaunchAgentURL)
            } catch {
                return .failure(
                    .trashFailed(standardizedLaunchAgentURL, error.localizedDescription)
                )
            }
        }

        do {
            try dependencies.resetAccessibilityPermission(legacyBundleIdentifier)
        } catch {
            return .failure(.accessibilityResetFailed(error.localizedDescription))
        }

        return .success(trashedItems: trashedItems)
    }

    static func manualCleanupInstructions(
        applicationURLs: [URL],
        launchAgentURL: URL
    ) -> String {
        let applicationList = applicationURLs
            .map { "• \($0.standardizedFileURL.path)" }
            .joined(separator: "\n")
        return """
        1. Quit the old app in Activity Monitor.
        2. In Finder, verify and move these old app bundles to the Trash:
        \(applicationList)
        3. Move this old login item to the Trash if it exists:
        • \(launchAgentURL.standardizedFileURL.path)
        4. Run this command in Terminal:
        tccutil reset Accessibility \(legacyBundleIdentifier)

        ActionHalo does not remove the old Application Support or Preferences data.
        """
    }

    @MainActor
    static func promptIfNeeded(
        dependencies: Dependencies = liveDependencies()
    ) {
        guard isEligibleCurrentInstallation(dependencies: dependencies) else {
            return
        }
        let homeDirectory = dependencies.homeDirectory
        let applicationURLs = detectedLegacyApplications(
            candidateURLs: candidateApplicationURLs(homeDirectory: homeDirectory),
            dependencies: dependencies
        )
        guard !applicationURLs.isEmpty else { return }

        let paths = applicationURLs.map(\.path).joined(separator: "\n")
        let prompt = NSAlert()
        prompt.messageText = "ActionHalo Is Installed".localized
        prompt.informativeText = String(
            format: "A verified OpenFire.app was found at:\n%@\n\nCompatible settings and plugins have been imported into ActionHalo. Incompatible or skipped items remain in the old Application Support data. Move OpenFire.app to the Trash? Its official login item will also be removed if present. The original Application Support and Preferences data will be preserved.".localized,
            paths
        )
        prompt.alertStyle = .informational
        prompt.addButton(withTitle: "Move Legacy App to Trash".localized)
        prompt.addButton(withTitle: "Later".localized)

        NSApp.activate(ignoringOtherApps: true)
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        let legacyLaunchAgentURL = launchAgentURL(homeDirectory: homeDirectory)
        switch performCleanup(
            applications: applicationURLs,
            launchAgentURL: legacyLaunchAgentURL,
            dependencies: dependencies
        ) {
        case .success:
            let successAlert = NSAlert()
            successAlert.messageText = "Legacy App Moved to Trash".localized
            successAlert.informativeText = "The verified OpenFire.app was moved to the Trash. Its official login item was also removed if present. The original Application Support and Preferences data were preserved.".localized
            successAlert.alertStyle = .informational
            successAlert.addButton(withTitle: "OK".localized)
            successAlert.runModal()
        case .failure(let failure):
            let failureAlert = NSAlert()
            failureAlert.messageText = "Legacy Cleanup Incomplete".localized
            failureAlert.informativeText = """
            \(failure.summary)

            \(manualCleanupInstructions(
                applicationURLs: candidateApplicationURLs(homeDirectory: homeDirectory),
                launchAgentURL: legacyLaunchAgentURL
            ))
            """
            failureAlert.alertStyle = .warning
            failureAlert.addButton(withTitle: "OK".localized)
            failureAlert.runModal()
        }
    }

    static func liveDependencies(
        fileManager: FileManager = .default,
        currentApplicationURL: URL = Bundle.main.bundleURL
    ) -> Dependencies {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let expectedLegacyLaunchAgentURL = launchAgentURL(
            homeDirectory: homeDirectory
        ).standardizedFileURL
        return Dependencies(
            homeDirectory: homeDirectory,
            currentApplicationURL: currentApplicationURL,
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            applicationBundleMetadata: { url in
                guard let values = try? url.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .volumeIsLocalKey,
                        .volumeIsReadOnlyKey,
                    ]
                ),
                let isDirectory = values.isDirectory,
                let isSymbolicLink = values.isSymbolicLink,
                let volumeIsLocal = values.volumeIsLocal,
                let volumeIsReadOnly = values.volumeIsReadOnly else {
                    return nil
                }
                let infoPlistURL = url
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Info.plist")
                guard let infoValues = try? infoPlistURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ),
                infoValues.isRegularFile == true,
                infoValues.isSymbolicLink != true,
                let data = try? Data(contentsOf: infoPlistURL, options: .mappedIfSafe),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any] else {
                    return nil
                }
                guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String else {
                    return nil
                }
                return ApplicationBundleMetadata(
                    bundleIdentifier: bundleIdentifier,
                    isDirectory: isDirectory,
                    isSymbolicLink: isSymbolicLink,
                    volumeIsLocal: volumeIsLocal,
                    volumeIsReadOnly: volumeIsReadOnly
                )
            },
            isOfficialLegacyLaunchAgent: { url in
                let standardizedURL = url.standardizedFileURL
                guard standardizedURL == expectedLegacyLaunchAgentURL,
                      let values = try? standardizedURL.resourceValues(
                          forKeys: [
                              .fileSizeKey,
                              .isRegularFileKey,
                              .isSymbolicLinkKey,
                          ]
                      ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let fileSize = values.fileSize,
                      fileSize >= 0,
                      fileSize <= maximumLaunchAgentBytes,
                      let data = try? Data(
                          contentsOf: standardizedURL,
                          options: .mappedIfSafe
                      ),
                      data.count <= maximumLaunchAgentBytes,
                      let propertyList = try? PropertyListSerialization.propertyList(
                          from: data,
                          options: [],
                          format: nil
                      ) else {
                    return false
                }
                return isOfficialLegacyLaunchAgentPropertyList(propertyList)
            },
            terminateApplications: terminateRunningApplications,
            moveToTrash: { url in
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            },
            resetAccessibilityPermission: { bundleIdentifier in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", "Accessibility", bundleIdentifier]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw LiveOperationError.accessibilityResetExitStatus(
                        process.terminationStatus
                    )
                }
            }
        )
    }

    private static func firstIdentityMismatch(
        in candidateURLs: [URL],
        dependencies: Dependencies
    ) -> URL? {
        candidateURLs.first { url in
            dependencies.fileExists(url) &&
                {
                    guard let metadata = dependencies.applicationBundleMetadata(url) else {
                        return true
                    }
                    return metadata.bundleIdentifier != legacyBundleIdentifier ||
                        !metadata.isDirectory ||
                        metadata.isSymbolicLink
                }()
        }
    }

    private static func terminateRunningApplications(
        bundleIdentifier: String
    ) -> Bool {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard !applications.isEmpty else { return true }

        for application in applications where !application.isTerminated {
            if !application.terminate() {
                _ = application.forceTerminate()
            }
        }
        if waitUntilTerminated(applications, timeout: 2) {
            return true
        }

        for application in applications where !application.isTerminated {
            _ = application.forceTerminate()
        }
        return waitUntilTerminated(applications, timeout: 1)
    }

    private static func waitUntilTerminated(
        _ applications: [NSRunningApplication],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if applications.allSatisfy(\.isTerminated) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return applications.allSatisfy(\.isTerminated)
    }
}
