import Cocoa

/// Routes the one-time OpenFire data-import result after normal app startup.
///
/// The importer itself runs before `AppDelegate` is constructed. This type only
/// owns the post-launch UI decision, which keeps alerts injectable in tests and
/// prevents an incomplete import from ever reaching the legacy cleanup path.
@MainActor
final class LegacyMigrationStartupCoordinator {
    struct Dependencies {
        let promptForLegacyCleanup: @MainActor () -> Void
        let presentIncompleteImport: @MainActor (_ title: String, _ message: String) -> Void

        @MainActor
        static var live: Dependencies {
            Dependencies(
                promptForLegacyCleanup: {
                    LegacyInstallationCleanup.promptIfNeeded()
                },
                presentIncompleteImport: { title, message in
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK".localized)
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            )
        }
    }

    private let importResult: LegacyDataImportResult
    private let dependencies: Dependencies
    private(set) var hasHandledPostLaunchResult = false

    init(
        importResult: LegacyDataImportResult,
        dependencies: Dependencies? = nil
    ) {
        self.importResult = importResult
        self.dependencies = dependencies ?? .live
    }

    func handlePostLaunchResult() {
        guard !hasHandledPostLaunchResult else { return }
        hasHandledPostLaunchResult = true

        switch importResult.state {
        case .completed, .alreadyCompleted:
            // This intentionally runs on every later launch while a verified
            // OpenFire.app remains, so choosing “Later” is not permanent.
            dependencies.promptForLegacyCleanup()
        case .incomplete:
            // Never expose cleanup after a partial import. Keeping OpenFire and
            // its source data intact gives the next launch a safe retry source.
            dependencies.presentIncompleteImport(
                "OpenFire Migration Incomplete".localized,
                Self.incompleteImportMessage(for: importResult)
            )
        }
    }

    static func incompleteImportMessage(for result: LegacyDataImportResult) -> String {
        var failures: [String] = []

        failures.append(contentsOf: result.preferenceFailures.map { failure in
            String(
                format: "Setting “%@”: %@".localized,
                failure.key,
                failure.details.localized
            )
        })
        failures.append(contentsOf: result.failedPlugins.map { failure in
            String(
                format: "Plugin “%@” (%@): %@".localized,
                failure.sourceName,
                pluginStageLabel(failure.stage),
                failure.details.localized
            )
        })
        failures.append(contentsOf: result.generalFailures.map { failure in
            String(
                format: "Migration step “%@”: %@".localized,
                generalStageLabel(failure.stage),
                failure.details.localized
            )
        })

        if failures.isEmpty {
            failures.append(
                "The migration did not complete, but no detailed error was reported.".localized
            )
        }

        let failureList = failures.map { "• \($0)" }.joined(separator: "\n")
        return String(
            format: "ActionHalo could not finish importing all compatible settings and plugins from OpenFire.\n\nFailed items:\n%@\n\nOpenFire, its settings, and its plugins will be kept. ActionHalo will retry the import the next time it starts. The old app will not be cleaned up until the import succeeds.".localized,
            failureList
        )
    }

    private static func pluginStageLabel(
        _ stage: LegacyDataImportResult.PluginFailure.Stage
    ) -> String {
        switch stage {
        case .sourceValidation:
            return "source package validation".localized
        case .destinationInspection:
            return "existing ActionHalo plugin inspection".localized
        case .configurationConversion:
            return "configuration conversion".localized
        case .copy:
            return "package copy".localized
        case .convertedValidation:
            return "converted package validation".localized
        case .install:
            return "package installation".localized
        }
    }

    private static func generalStageLabel(
        _ stage: LegacyDataImportResult.GeneralFailure.Stage
    ) -> String {
        switch stage {
        case .sourceDefaultsRead:
            return "reading OpenFire settings".localized
        case .destinationDefaultsRead:
            return "reading ActionHalo settings".localized
        case .destinationDefaultsWrite:
            return "writing ActionHalo settings".localized
        case .sourcePluginDirectory:
            return "reading the OpenFire plugin folder".localized
        case .destinationPluginDirectory:
            return "preparing the ActionHalo plugin folder".localized
        case .launchAgent:
            return "migrating the login item".localized
        case .markerWrite:
            return "recording migration completion".localized
        }
    }
}
