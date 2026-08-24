import CoreFoundation
import Darwin
import Foundation

protocol LegacyDefaultsDomainStoring {
    func persistentDomain(forName name: String) throws -> [String: Any]
    func setPersistentDomain(_ domain: [String: Any], forName name: String) throws
}

struct UserDefaultsDomainStore: LegacyDefaultsDomainStoring {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func persistentDomain(forName name: String) throws -> [String: Any] {
        userDefaults.persistentDomain(forName: name) ?? [:]
    }

    func setPersistentDomain(_ domain: [String: Any], forName name: String) throws {
        userDefaults.setPersistentDomain(domain, forName: name)
    }
}

/// Detailed outcome for startup UI and cleanup gating.
///
/// Skipped plugins are intentionally incompatible or conflict with user-owned
/// ActionHalo data. Failures are operational and keep the completion marker
/// unset so a later launch can retry.
struct LegacyDataImportResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case alreadyCompleted
        case completed
        case incomplete
    }

    struct ImportedPlugin: Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            case legacyDirectory
            case existingActionHaloDirectory
        }

        let sourceName: String
        let identifier: String
        let destinationURL: URL
        let origin: Origin
    }

    struct SkippedPlugin: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case identifierConflict
            case destinationConflict
            case incompatible(String)
        }

        let sourceName: String
        let identifier: String?
        let reason: Reason
    }

    struct PluginFailure: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case sourceValidation
            case destinationInspection
            case configurationConversion
            case copy
            case convertedValidation
            case install
        }

        let sourceName: String
        let stage: Stage
        let details: String
    }

    struct PreferenceFailure: Equatable, Sendable {
        let key: String
        let details: String
    }

    struct GeneralFailure: Equatable, Sendable {
        enum Stage: Equatable, Sendable {
            case sourceDefaultsRead
            case destinationDefaultsRead
            case destinationDefaultsWrite
            case sourcePluginDirectory
            case destinationPluginDirectory
            case launchAgent
            case markerWrite
        }

        let stage: Stage
        let details: String
    }

    enum LaunchAgentMigration: Equatable, Sendable {
        case notAttempted
        case sourceNotFound
        case preservedExisting(URL)
        case imported(URL)
        case skippedInvalid(String)
        case failed(String)
    }

    var state: State = .incomplete
    var importedPreferenceKeys: [String] = []
    var preservedPreferenceKeys: [String] = []
    var preferenceFailures: [PreferenceFailure] = []
    var importedPlugins: [ImportedPlugin] = []
    var skippedPlugins: [SkippedPlugin] = []
    var failedPlugins: [PluginFailure] = []
    var ignoredPluginEntries: [String] = []
    var generalFailures: [GeneralFailure] = []
    var launchAgentMigration: LaunchAgentMigration = .notAttempted
    var markerWritten = false

    var isFullySuccessful: Bool {
        preferenceFailures.isEmpty && failedPlugins.isEmpty && generalFailures.isEmpty
    }
}

/// One-time, source-preserving import from the retired OpenFire identity.
struct LegacyDataImporter {
    static let sourceDefaultsDomain = "com.openfire.app"
    static let destinationDefaultsDomain = "com.actionhalo.app"
    static let importMarkerKey = "ActionHaloLegacyDataImportVersion"
    static let currentImportVersion = 1

    private struct PreferenceSpec {
        enum Transformation {
            case propertyList
            case pluginIdentifiers
            case perAppPluginIdentifiers
        }

        let targetKey: String
        let sourceKeys: [String]
        let transformation: Transformation
    }

    private struct ConvertedConfiguration {
        let sourceIdentifier: String
        let data: Data
        let config: PluginConfig
    }

    private struct IncompatiblePluginError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private struct ImportError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private enum DestinationPluginProbe {
        case convertible(identifier: String)
        case notLegacy
        case incompatible(String)
    }

    private static let legacyPackageExtensions: Set<String> = [
        "openfireext",
        PluginLoader.packageExtension,
    ]
    private static let sourceLaunchAgentLabel = "com.openfire.app"
    private static let destinationLaunchAgentLabel = "com.actionhalo.app"
    private static let maximumLaunchAgentBytes = 64 * 1024

    // Explicit allowlist: Sparkle/version/TCC/cleanup/trust/identity state is
    // intentionally absent and therefore cannot cross bundle-ID boundaries.
    private static let preferenceSpecs: [PreferenceSpec] = [
        PreferenceSpec(
            targetKey: "ActionHaloEnabled",
            sourceKeys: ["ActionHaloEnabled", "OpenFireEnabled"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "WheelBackdropEnabled",
            sourceKeys: ["WheelBackdropEnabled"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "ringOpacity",
            sourceKeys: ["ringOpacity"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "maxRadialMenuItems",
            sourceKeys: ["maxRadialMenuItems"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "AppLanguage",
            sourceKeys: ["AppLanguage"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "ExcludedApps",
            sourceKeys: ["ExcludedApps"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "DefaultOfficeAppsExcludedMigrationVersion",
            sourceKeys: ["DefaultOfficeAppsExcludedMigrationVersion"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "hotkeyConfigured",
            sourceKeys: ["hotkeyConfigured"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "hotkeyKeyCode",
            sourceKeys: ["hotkeyKeyCode"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "hotkeyModifiers",
            sourceKeys: ["hotkeyModifiers"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "toggleHotkeyConfigured",
            sourceKeys: ["toggleHotkeyConfigured"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "toggleHotkeyKeyCode",
            sourceKeys: ["toggleHotkeyKeyCode"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "toggleHotkeyModifiers",
            sourceKeys: ["toggleHotkeyModifiers"],
            transformation: .propertyList
        ),
        PreferenceSpec(
            targetKey: "disabledPlugins",
            sourceKeys: ["disabledPlugins"],
            transformation: .pluginIdentifiers
        ),
        PreferenceSpec(
            targetKey: "userEnabledPlugins",
            sourceKeys: ["userEnabledPlugins"],
            transformation: .pluginIdentifiers
        ),
        PreferenceSpec(
            targetKey: "deletedBuiltInPlugins",
            sourceKeys: ["deletedBuiltInPlugins"],
            transformation: .pluginIdentifiers
        ),
        PreferenceSpec(
            targetKey: "pluginOrder",
            sourceKeys: ["pluginOrder"],
            transformation: .pluginIdentifiers
        ),
        PreferenceSpec(
            targetKey: "perAppDisabledPlugins",
            sourceKeys: ["perAppDisabledPlugins"],
            transformation: .perAppPluginIdentifiers
        ),
        PreferenceSpec(
            targetKey: "VerbosePluginLoggingEnabled",
            sourceKeys: ["VerbosePluginLoggingEnabled"],
            transformation: .propertyList
        ),
    ]

    private let defaultsStore: LegacyDefaultsDomainStoring
    private let fileManager: FileManager
    private let sourceDomainName: String
    private let destinationDomainName: String
    private let sourcePluginsURL: URL
    private let destinationPluginsURL: URL
    private let sourceLaunchAgentURL: URL
    private let destinationLaunchAgentURL: URL
    private let pendingPackageMinimumAge: TimeInterval
    private let now: () -> Date

    init(
        defaultsStore: LegacyDefaultsDomainStoring = UserDefaultsDomainStore(),
        fileManager: FileManager = .default,
        sourceDomainName: String = Self.sourceDefaultsDomain,
        destinationDomainName: String = Self.destinationDefaultsDomain,
        sourcePluginsURL: URL? = nil,
        destinationPluginsURL: URL? = nil,
        sourceLaunchAgentURL: URL? = nil,
        destinationLaunchAgentURL: URL? = nil,
        pendingPackageMinimumAge: TimeInterval =
            PluginManager.pendingOperationRecoveryMinimumAge,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaultsStore = defaultsStore
        self.fileManager = fileManager
        self.sourceDomainName = sourceDomainName
        self.destinationDomainName = destinationDomainName
        self.pendingPackageMinimumAge = pendingPackageMinimumAge
        self.now = now

        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.sourcePluginsURL = sourcePluginsURL ?? applicationSupportURL
            .appendingPathComponent("OpenFire/Plugins", isDirectory: true)
        self.destinationPluginsURL = destinationPluginsURL ?? applicationSupportURL
            .appendingPathComponent("ActionHalo/Plugins", isDirectory: true)

        let launchAgentsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.sourceLaunchAgentURL = sourceLaunchAgentURL ?? launchAgentsURL
            .appendingPathComponent("\(Self.sourceLaunchAgentLabel).plist")
        self.destinationLaunchAgentURL = destinationLaunchAgentURL ?? launchAgentsURL
            .appendingPathComponent("\(Self.destinationLaunchAgentLabel).plist")
    }

    /// Imports all eligible data and writes the version marker only after every
    /// retryable operation succeeds.
    func importIfNeeded() -> LegacyDataImportResult {
        var result = LegacyDataImportResult()
        let initialDestinationDomain: [String: Any]

        do {
            initialDestinationDomain = try defaultsStore.persistentDomain(
                forName: destinationDomainName
            )
        } catch {
            result.generalFailures.append(
                .init(
                    stage: .destinationDefaultsRead,
                    details: error.localizedDescription
                )
            )
            return result
        }

        if Self.markerVersion(in: initialDestinationDomain) >= Self.currentImportVersion {
            result.state = .alreadyCompleted
            return result
        }

        let sourceDomain: [String: Any]
        do {
            sourceDomain = try defaultsStore.persistentDomain(forName: sourceDomainName)
        } catch {
            result.generalFailures.append(
                .init(stage: .sourceDefaultsRead, details: error.localizedDescription)
            )
            return result
        }

        importPreferences(
            from: sourceDomain,
            initialDestinationDomain: initialDestinationDomain,
            into: &result
        )
        importPlugins(into: &result)
        importLaunchAgent(into: &result)

        guard result.isFullySuccessful else { return result }

        do {
            var latestDestinationDomain = try defaultsStore.persistentDomain(
                forName: destinationDomainName
            )
            latestDestinationDomain[Self.importMarkerKey] = Self.currentImportVersion
            try defaultsStore.setPersistentDomain(
                latestDestinationDomain,
                forName: destinationDomainName
            )
            result.markerWritten = true
            result.state = .completed
        } catch {
            result.generalFailures.append(
                .init(stage: .markerWrite, details: error.localizedDescription)
            )
        }

        return result
    }

    private func importPreferences(
        from sourceDomain: [String: Any],
        initialDestinationDomain: [String: Any],
        into result: inout LegacyDataImportResult
    ) {
        var destinationDomain = initialDestinationDomain
        var pendingImportedKeys: [String] = []

        for spec in Self.preferenceSpecs {
            guard let sourceValue = spec.sourceKeys.lazy.compactMap({ sourceDomain[$0] }).first else {
                continue
            }

            guard destinationDomain[spec.targetKey] == nil else {
                result.preservedPreferenceKeys.append(spec.targetKey)
                continue
            }

            do {
                destinationDomain[spec.targetKey] = try Self.transformedPreferenceValue(
                    sourceValue,
                    transformation: spec.transformation
                )
                pendingImportedKeys.append(spec.targetKey)
            } catch {
                result.preferenceFailures.append(
                    .init(key: spec.targetKey, details: error.localizedDescription)
                )
            }
        }

        guard !pendingImportedKeys.isEmpty else { return }

        do {
            try defaultsStore.setPersistentDomain(
                destinationDomain,
                forName: destinationDomainName
            )
            result.importedPreferenceKeys.append(contentsOf: pendingImportedKeys)
        } catch {
            result.generalFailures.append(
                .init(stage: .destinationDefaultsWrite, details: error.localizedDescription)
            )
        }
    }

    private func importPlugins(into result: inout LegacyDataImportResult) {
        let sourceDirectoryExists = fileManager.fileExists(atPath: sourcePluginsURL.path)
        let destinationDirectoryExists = fileManager.fileExists(atPath: destinationPluginsURL.path)
        guard sourceDirectoryExists || destinationDirectoryExists else { return }

        var canImportLegacyDirectory = sourceDirectoryExists
        if sourceDirectoryExists && !Self.isSafeDirectory(sourcePluginsURL) {
            result.generalFailures.append(
                .init(
                    stage: .sourcePluginDirectory,
                    details: "The legacy plugin directory is not a safe local directory."
                )
            )
            canImportLegacyDirectory = false
        }

        do {
            if !fileManager.fileExists(atPath: destinationPluginsURL.path) {
                guard canImportLegacyDirectory else { return }
                try fileManager.createDirectory(
                    at: destinationPluginsURL,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            result.generalFailures.append(
                .init(stage: .destinationPluginDirectory, details: error.localizedDescription)
            )
            return
        }

        guard Self.isSafeDirectory(destinationPluginsURL) else {
            result.generalFailures.append(
                .init(
                    stage: .destinationPluginDirectory,
                    details: "The ActionHalo plugin directory is not a safe local directory."
                )
            )
            return
        }

        let destinationEntries: [URL]
        do {
            destinationEntries = try fileManager.contentsOfDirectory(
                at: destinationPluginsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted(by: Self.pluginEntrySort)
        } catch {
            result.generalFailures.append(
                .init(stage: .destinationPluginDirectory, details: error.localizedDescription)
            )
            return
        }

        var existingPluginIDs: Set<String> = []
        var validDestinationURLs: Set<String> = []
        for destinationURL in destinationEntries
        where PluginLoader.isSupportedPackageURL(destinationURL) {
            guard let plugin = PluginLoader.load(from: destinationURL) else { continue }
            existingPluginIDs.insert(Self.normalizedPluginIdentifier(plugin.id))
            validDestinationURLs.insert(destinationURL.standardizedFileURL.path)
        }

        var convertibleDestinationPackages: [(url: URL, identifier: String)] = []
        for destinationURL in destinationEntries {
            if Self.isUnconfirmedPendingPackage(destinationURL) {
                result.ignoredPluginEntries.append(destinationURL.lastPathComponent)
                continue
            }
            guard Self.isDestinationConversionCandidate(destinationURL),
                  !validDestinationURLs.contains(destinationURL.standardizedFileURL.path) else {
                continue
            }
            if Self.isBackupPendingPackage(destinationURL),
               !isPendingBackupReadyForRecovery(destinationURL) {
                result.failedPlugins.append(
                    .init(
                        sourceName: destinationURL.lastPathComponent,
                        stage: .destinationInspection,
                        details: "The compatibility backup is too recent or its age cannot be verified; ActionHalo will retry later."
                    )
                )
                continue
            }
            do {
                switch try probeDestinationPlugin(at: destinationURL) {
                case .convertible(let identifier):
                    convertibleDestinationPackages.append((destinationURL, identifier))
                case .notLegacy:
                    result.ignoredPluginEntries.append(destinationURL.lastPathComponent)
                case .incompatible(let details):
                    result.skippedPlugins.append(
                        .init(
                            sourceName: destinationURL.lastPathComponent,
                            identifier: nil,
                            reason: .incompatible(details)
                        )
                    )
                }
            } catch {
                result.failedPlugins.append(
                    .init(
                        sourceName: destinationURL.lastPathComponent,
                        stage: .destinationInspection,
                        details: error.localizedDescription
                    )
                )
            }
        }

        for candidate in convertibleDestinationPackages {
            convertExistingDestinationPlugin(
                at: candidate.url,
                expectedLegacyIdentifier: candidate.identifier,
                existingPluginIDs: &existingPluginIDs,
                into: &result
            )
        }

        guard canImportLegacyDirectory else { return }

        let sourceEntries: [URL]
        do {
            sourceEntries = try fileManager.contentsOfDirectory(
                at: sourcePluginsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).sorted(by: Self.pluginEntrySort)
        } catch {
            result.generalFailures.append(
                .init(stage: .sourcePluginDirectory, details: error.localizedDescription)
            )
            return
        }

        for sourceURL in sourceEntries {
            guard Self.legacyPackageExtensions.contains(sourceURL.pathExtension.lowercased()) else {
                result.ignoredPluginEntries.append(sourceURL.lastPathComponent)
                continue
            }
            importPluginFromLegacyDirectory(
                from: sourceURL,
                existingPluginIDs: &existingPluginIDs,
                into: &result
            )
        }
    }

    private func probeDestinationPlugin(at packageURL: URL) throws -> DestinationPluginProbe {
        guard PluginManager.isInstallPackageWithinLimits(
            packageURL,
            fileManager: fileManager
        ) else {
            return .incompatible(
                "The installed compatibility package is unsafe, oversized, empty, or contains symbolic links."
            )
        }

        let configURL = packageURL.appendingPathComponent("Config.json")
        let values = try configURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= PluginLoader.maximumConfigBytes else {
            return .incompatible("Config.json is missing, unsafe, or too large.")
        }

        let data = try Data(contentsOf: configURL, options: .mappedIfSafe)
        guard data.count <= PluginLoader.maximumConfigBytes else {
            return .incompatible("Config.json exceeds the size limit.")
        }
        let root: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .incompatible("Config.json is not a JSON object.")
            }
            root = decoded
        } catch {
            return .incompatible("Config.json is not valid JSON.")
        }

        guard let identifier = root["identifier"] as? String else {
            return .incompatible("Config.json does not contain a string identifier.")
        }
        let needsContainerConversion =
            packageURL.pathExtension.lowercased() == "openfireext" ||
            Self.isBackupPendingPackage(packageURL)
        return needsContainerConversion || Self.isLegacyPluginIdentifier(identifier)
            ? .convertible(identifier: identifier)
            : .notLegacy
    }

    private func importPluginFromLegacyDirectory(
        from sourceURL: URL,
        existingPluginIDs: inout Set<String>,
        into result: inout LegacyDataImportResult
    ) {
        let sourceName = sourceURL.lastPathComponent
        guard PluginManager.isInstallPackageWithinLimits(
            sourceURL,
            fileManager: fileManager
        ) else {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: nil,
                    reason: .incompatible(
                        "The source package is unsafe, oversized, empty, or contains symbolic links."
                    )
                )
            )
            return
        }

        let convertedPackage: ConvertedConfiguration
        do {
            convertedPackage = try convertedConfiguration(from: sourceURL)
        } catch let error as IncompatiblePluginError {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: nil,
                    reason: .incompatible(error.localizedDescription)
                )
            )
            return
        } catch {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .configurationConversion,
                    details: error.localizedDescription
                )
            )
            return
        }

        let identifier = convertedPackage.config.identifier
        let normalizedIdentifier = Self.normalizedPluginIdentifier(identifier)
        if existingPluginIDs.contains(normalizedIdentifier) {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .identifierConflict
                )
            )
            return
        }
        guard let sourceFingerprint = packageFingerprint(
            at: sourceURL,
            configuration: convertedPackage.config
        ) else {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .sourceValidation,
                    details: "The source package could not be fingerprinted safely."
                )
            )
            return
        }

        let destinationURL = destinationPluginsURL.appendingPathComponent(
            PluginManager.visibleUserPluginFileName(for: identifier),
            isDirectory: true
        )
        guard PluginManager.isPluginDirectory(destinationURL, inside: destinationPluginsURL) else {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .configurationConversion,
                    details: "The converted identifier did not produce a safe destination path."
                )
            )
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .destinationConflict
                )
            )
            return
        }

        guard let stagingURL = prepareConvertedPlugin(
            from: sourceURL,
            convertedConfiguration: convertedPackage,
            expectedSourceFingerprint: sourceFingerprint,
            sourceName: sourceName,
            into: &result
        ) else {
            return
        }
        defer { try? fileManager.removeItem(at: stagingURL) }

        if existingPluginIDs.contains(normalizedIdentifier) {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .identifierConflict
                )
            )
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .destinationConflict
                )
            )
            return
        }
        guard packageFingerprint(
            at: sourceURL,
            configuration: convertedPackage.config
        ) == sourceFingerprint else {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .copy,
                    details: "The source package changed during import; ActionHalo will retry."
                )
            )
            return
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            existingPluginIDs.insert(normalizedIdentifier)
            result.importedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    destinationURL: destinationURL,
                    origin: .legacyDirectory
                )
            )
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                result.skippedPlugins.append(
                    .init(
                        sourceName: sourceName,
                        identifier: identifier,
                        reason: .destinationConflict
                    )
                )
            } else {
                result.failedPlugins.append(
                    .init(sourceName: sourceName, stage: .install, details: error.localizedDescription)
                )
            }
        }
    }

    private func convertExistingDestinationPlugin(
        at sourceURL: URL,
        expectedLegacyIdentifier: String,
        existingPluginIDs: inout Set<String>,
        into result: inout LegacyDataImportResult
    ) {
        let sourceName = sourceURL.lastPathComponent
        let convertedPackage: ConvertedConfiguration
        do {
            convertedPackage = try convertedConfiguration(from: sourceURL)
        } catch let error as IncompatiblePluginError {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: expectedLegacyIdentifier,
                    reason: .incompatible(error.localizedDescription)
                )
            )
            return
        } catch {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .configurationConversion,
                    details: error.localizedDescription
                )
            )
            return
        }

        let stillNeedsConversion =
            sourceURL.pathExtension.lowercased() == "openfireext" ||
            Self.isBackupPendingPackage(sourceURL) ||
            Self.isLegacyPluginIdentifier(convertedPackage.sourceIdentifier)
        guard stillNeedsConversion else {
            if let plugin = PluginLoader.load(from: sourceURL) {
                existingPluginIDs.insert(Self.normalizedPluginIdentifier(plugin.id))
            }
            result.ignoredPluginEntries.append(sourceName)
            return
        }

        let identifier = convertedPackage.config.identifier
        let normalizedIdentifier = Self.normalizedPluginIdentifier(identifier)
        if existingPluginIDs.contains(normalizedIdentifier) {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .identifierConflict
                )
            )
            return
        }
        guard let sourceFingerprint = packageFingerprint(
            at: sourceURL,
            configuration: convertedPackage.config
        ) else {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .sourceValidation,
                    details: "The compatibility package could not be fingerprinted safely."
                )
            )
            return
        }

        let destinationURL = destinationPluginsURL.appendingPathComponent(
            PluginManager.visibleUserPluginFileName(for: identifier),
            isDirectory: true
        )
        guard PluginManager.isPluginDirectory(destinationURL, inside: destinationPluginsURL) else {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .incompatible(
                        "The converted identifier did not produce a safe destination path."
                    )
                )
            )
            return
        }

        let destinationIsSource = PluginManager.sameFileURL(sourceURL, destinationURL)
        if !destinationIsSource && fileManager.fileExists(atPath: destinationURL.path) {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .destinationInspection,
                    details: "The canonical ActionHalo path is occupied by a package that did not validate for this identifier; no package was overwritten."
                )
            )
            return
        }

        guard let stagingURL = prepareConvertedPlugin(
            from: sourceURL,
            convertedConfiguration: convertedPackage,
            expectedSourceFingerprint: sourceFingerprint,
            sourceName: sourceName,
            into: &result
        ) else {
            return
        }
        let backupURL = PluginManager.pendingPluginPackageURL(
            in: destinationPluginsURL,
            prefix: "backup-legacy-import"
        )
        var preserveBackup = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if !preserveBackup {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        if existingPluginIDs.contains(normalizedIdentifier) {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: identifier,
                    reason: .identifierConflict
                )
            )
            return
        }
        if !destinationIsSource && fileManager.fileExists(atPath: destinationURL.path) {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .destinationInspection,
                    details: "The canonical ActionHalo path became occupied during conversion; no package was overwritten."
                )
            )
            return
        }
        guard packageFingerprint(
            at: sourceURL,
            configuration: convertedPackage.config
        ) == sourceFingerprint else {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .install,
                    details: "The compatibility package changed during conversion; the original was left in place."
                )
            )
            return
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: backupURL)
        } catch {
            result.failedPlugins.append(
                .init(sourceName: sourceName, stage: .install, details: error.localizedDescription)
            )
            return
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            let restored = PluginManager.restoreBackedUpPackageIfNeeded(
                backupURL: backupURL,
                destinationURL: sourceURL,
                didMoveDestinationToBackup: true,
                fileManager: fileManager,
                logPrefix: "Legacy plugin conversion"
            )
            preserveBackup = !restored
            if restored && fileManager.fileExists(atPath: destinationURL.path) {
                result.failedPlugins.append(
                    .init(
                        sourceName: sourceName,
                        stage: .install,
                        details: "The canonical ActionHalo path became occupied during conversion; the original compatibility package was restored."
                    )
                )
            } else {
                let rollbackDetails = restored
                    ? ""
                    : " The original package is preserved at \(backupURL.path)."
                result.failedPlugins.append(
                    .init(
                        sourceName: sourceName,
                        stage: .install,
                        details: error.localizedDescription + rollbackDetails
                    )
                )
            }
            return
        }

        existingPluginIDs.insert(normalizedIdentifier)
        result.importedPlugins.append(
            .init(
                sourceName: sourceName,
                identifier: identifier,
                destinationURL: destinationURL,
                origin: .existingActionHaloDirectory
            )
        )
    }

    private func prepareConvertedPlugin(
        from sourceURL: URL,
        convertedConfiguration: ConvertedConfiguration,
        expectedSourceFingerprint: String,
        sourceName: String,
        into result: inout LegacyDataImportResult
    ) -> URL? {
        let stagingURL = PluginManager.pendingPluginPackageURL(
            in: destinationPluginsURL,
            prefix: "install-legacy-import"
        )
        var shouldKeepStaging = false
        defer {
            if !shouldKeepStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
        } catch {
            result.failedPlugins.append(
                .init(sourceName: sourceName, stage: .copy, details: error.localizedDescription)
            )
            return nil
        }
        guard packageFingerprint(
            at: stagingURL,
            configuration: convertedConfiguration.config
        ) == expectedSourceFingerprint,
        packageFingerprint(
            at: sourceURL,
            configuration: convertedConfiguration.config
        ) == expectedSourceFingerprint else {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .copy,
                    details: "The package changed while its migration snapshot was being created."
                )
            )
            return nil
        }

        do {
            try writePreservingPermissions(
                convertedConfiguration.data,
                to: stagingURL.appendingPathComponent("Config.json")
            )
            try convertBundledScriptIfNeeded(
                configuration: convertedConfiguration.config,
                packageURL: stagingURL
            )
        } catch let error as IncompatiblePluginError {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: convertedConfiguration.config.identifier,
                    reason: .incompatible(error.localizedDescription)
                )
            )
            return nil
        } catch {
            result.failedPlugins.append(
                .init(
                    sourceName: sourceName,
                    stage: .configurationConversion,
                    details: error.localizedDescription
                )
            )
            return nil
        }

        guard PluginManager.isInstallPackageWithinLimits(
            stagingURL,
            fileManager: fileManager
        ),
        let convertedPlugin = PluginLoader.load(from: stagingURL),
        convertedPlugin.id == convertedConfiguration.config.identifier else {
            result.skippedPlugins.append(
                .init(
                    sourceName: sourceName,
                    identifier: convertedConfiguration.config.identifier,
                    reason: .incompatible(
                        "The converted package failed ActionHalo validation."
                    )
                )
            )
            return nil
        }

        shouldKeepStaging = true
        return stagingURL
    }

    private func packageFingerprint(
        at url: URL,
        configuration: PluginConfig
    ) -> String? {
        Plugin(config: configuration, directoryURL: url).packageFingerprint
    }

    private func importLaunchAgent(into result: inout LegacyDataImportResult) {
        if Self.filesystemEntryExists(at: destinationLaunchAgentURL) {
            result.launchAgentMigration = .preservedExisting(destinationLaunchAgentURL)
            return
        }
        guard Self.filesystemEntryExists(at: sourceLaunchAgentURL) else {
            result.launchAgentMigration = .sourceNotFound
            return
        }

        let sourceValues: URLResourceValues
        do {
            sourceValues = try sourceLaunchAgentURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            recordLaunchAgentFailure(error.localizedDescription, into: &result)
            return
        }
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let fileSize = sourceValues.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumLaunchAgentBytes else {
            result.launchAgentMigration = .skippedInvalid(
                "The legacy launch agent is not a safe bounded regular file."
            )
            return
        }

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceLaunchAgentURL, options: .mappedIfSafe)
        } catch {
            recordLaunchAgentFailure(error.localizedDescription, into: &result)
            return
        }
        guard sourceData.count <= Self.maximumLaunchAgentBytes else {
            result.launchAgentMigration = .skippedInvalid(
                "The legacy launch agent exceeds the size limit."
            )
            return
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: sourceData,
                options: [],
                format: nil
            )
        } catch {
            result.launchAgentMigration = .skippedInvalid(
                "The legacy launch agent is not a valid property list."
            )
            return
        }

        let requiredKeys: Set<String> = ["Label", "ProgramArguments", "RunAtLoad"]
        guard let dictionary = propertyList as? [String: Any],
              Set(dictionary.keys) == requiredKeys,
              dictionary["Label"] as? String == Self.sourceLaunchAgentLabel,
              dictionary["ProgramArguments"] as? [String] == [
                "/usr/bin/open",
                "-b",
                Self.sourceLaunchAgentLabel,
              ],
              let runAtLoad = dictionary["RunAtLoad"] as? NSNumber,
              CFGetTypeID(runAtLoad) == CFBooleanGetTypeID(),
              runAtLoad.boolValue else {
            result.launchAgentMigration = .skippedInvalid(
                "The legacy launch agent does not exactly match the expected OpenFire definition."
            )
            return
        }

        let destinationDirectoryURL = destinationLaunchAgentURL.deletingLastPathComponent()
        do {
            if !Self.filesystemEntryExists(at: destinationDirectoryURL) {
                try fileManager.createDirectory(
                    at: destinationDirectoryURL,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            recordLaunchAgentFailure(error.localizedDescription, into: &result)
            return
        }
        guard Self.isSafeDirectory(destinationDirectoryURL) else {
            recordLaunchAgentFailure(
                "The ActionHalo LaunchAgents directory is not a safe local directory.",
                into: &result
            )
            return
        }

        let destinationPropertyList: [String: Any] = [
            "Label": Self.destinationLaunchAgentLabel,
            "ProgramArguments": [
                "/usr/bin/open",
                "-b",
                Self.destinationLaunchAgentLabel,
            ],
            "RunAtLoad": true,
        ]
        let destinationData: Data
        do {
            destinationData = try PropertyListSerialization.data(
                fromPropertyList: destinationPropertyList,
                format: .xml,
                options: 0
            )
        } catch {
            recordLaunchAgentFailure(error.localizedDescription, into: &result)
            return
        }

        let stagingURL = destinationDirectoryURL.appendingPathComponent(
            ".legacy-import-\(UUID().uuidString).plist"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        do {
            try destinationData.write(to: stagingURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: stagingURL.path
            )

            if Self.filesystemEntryExists(at: destinationLaunchAgentURL) {
                result.launchAgentMigration = .preservedExisting(destinationLaunchAgentURL)
                return
            }

            try fileManager.moveItem(at: stagingURL, to: destinationLaunchAgentURL)
            result.launchAgentMigration = .imported(destinationLaunchAgentURL)
        } catch {
            if Self.filesystemEntryExists(at: destinationLaunchAgentURL) {
                result.launchAgentMigration = .preservedExisting(destinationLaunchAgentURL)
            } else {
                recordLaunchAgentFailure(error.localizedDescription, into: &result)
            }
        }
    }

    private func recordLaunchAgentFailure(
        _ details: String,
        into result: inout LegacyDataImportResult
    ) {
        result.launchAgentMigration = .failed(details)
        result.generalFailures.append(.init(stage: .launchAgent, details: details))
    }

    private func isPendingBackupReadyForRecovery(_ url: URL) -> Bool {
        guard pendingPackageMinimumAge > 0 else { return true }

        let name = url.lastPathComponent
        if let timestamp = name
            .split(separator: "-")
            .first(where: { $0.hasPrefix("t") })
            .flatMap({ TimeInterval($0.dropFirst()) }) {
            return now().timeIntervalSince1970 - timestamp >= pendingPackageMinimumAge
        }

        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        ) else {
            return false
        }
        let timestamps = [
            values.contentModificationDate,
            values.creationDate,
        ].compactMap { $0 }
        guard let newestTimestamp = timestamps.max() else { return false }
        return now().timeIntervalSince(newestTimestamp) >= pendingPackageMinimumAge
    }

    private func convertedConfiguration(from packageURL: URL) throws -> ConvertedConfiguration {
        let configURL = packageURL.appendingPathComponent("Config.json")
        let values = try configURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= PluginLoader.maximumConfigBytes else {
            throw IncompatiblePluginError(
                message: "Config.json is missing, unsafe, or too large."
            )
        }

        let sourceData = try Data(contentsOf: configURL, options: .mappedIfSafe)
        guard sourceData.count <= PluginLoader.maximumConfigBytes else {
            throw IncompatiblePluginError(
                message: "Config.json exceeds the size limit."
            )
        }
        let decodedRoot: Any
        do {
            decodedRoot = try JSONSerialization.jsonObject(with: sourceData)
        } catch {
            throw IncompatiblePluginError(message: "Config.json is not valid JSON.")
        }
        guard var root = decodedRoot as? [String: Any],
              let sourceIdentifier = root["identifier"] as? String else {
            throw IncompatiblePluginError(
                message: "Config.json does not contain a valid identifier."
            )
        }

        root = Self.replacingLegacyEnvironmentReferences(in: root) as? [String: Any] ?? root
        let convertedIdentifier = Self.convertedPluginIdentifier(sourceIdentifier)
        root["identifier"] = convertedIdentifier

        if let validationMessage = PluginManager.pluginIdentifierValidationMessage(convertedIdentifier) {
            throw IncompatiblePluginError(message: validationMessage)
        }
        guard JSONSerialization.isValidJSONObject(root) else {
            throw IncompatiblePluginError(
                message: "The converted Config.json is not valid JSON."
            )
        }

        let convertedData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard convertedData.count <= PluginLoader.maximumConfigBytes else {
            throw IncompatiblePluginError(
                message: "The converted Config.json exceeds the size limit."
            )
        }

        let config: PluginConfig
        do {
            config = try JSONDecoder().decode(PluginConfig.self, from: convertedData)
        } catch {
            throw IncompatiblePluginError(
                message: "Config.json does not match the ActionHalo plugin schema."
            )
        }
        return ConvertedConfiguration(
            sourceIdentifier: sourceIdentifier,
            data: convertedData,
            config: config
        )
    }

    private func convertBundledScriptIfNeeded(
        configuration: PluginConfig,
        packageURL: URL
    ) throws {
        guard configuration.action.type == .shellScript ||
                configuration.action.type == .applescript,
              let scriptValue = configuration.action.script else {
            return
        }

        switch PluginManager.resolvedPluginScriptSource(
            scriptValue,
            pluginDirectoryURL: packageURL,
            fileManager: fileManager
        ) {
        case .bundledFile(let scriptURL):
            let scriptData = try Data(contentsOf: scriptURL, options: .mappedIfSafe)
            guard let script = String(data: scriptData, encoding: .utf8) else {
                throw IncompatiblePluginError(
                    message: "The bundled script is not UTF-8 and cannot be converted safely."
                )
            }
            let convertedScript = Self.replacingLegacyEnvironmentReferences(in: script)
            if convertedScript != script {
                try writePreservingPermissions(Data(convertedScript.utf8), to: scriptURL)
            }
        case .inline:
            break
        case nil:
            throw IncompatiblePluginError(
                message: "The configured script is missing or outside the package."
            )
        }
    }

    private func writePreservingPermissions(_ data: Data, to url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions]
        try data.write(to: url, options: [])
        if let permissions {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }
    }

    private static func transformedPreferenceValue(
        _ value: Any,
        transformation: PreferenceSpec.Transformation
    ) throws -> Any {
        switch transformation {
        case .propertyList:
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
                throw ImportError(message: "The stored value is not a valid property-list value.")
            }
            return value
        case .pluginIdentifiers:
            guard let identifiers = value as? [String] else {
                throw ImportError(message: "Expected an array of plugin identifiers.")
            }
            return convertedPluginIdentifiers(identifiers)
        case .perAppPluginIdentifiers:
            guard let overrides = value as? [String: Any] else {
                throw ImportError(message: "Expected a dictionary of per-app plugin identifiers.")
            }
            var converted: [String: [String]] = [:]
            for (appIdentifier, rawIdentifiers) in overrides {
                guard let identifiers = rawIdentifiers as? [String] else {
                    throw ImportError(
                        message: "Expected an array of plugin identifiers for \(appIdentifier)."
                    )
                }
                converted[appIdentifier] = convertedPluginIdentifiers(identifiers)
            }
            return converted
        }
    }

    private static func convertedPluginIdentifiers(_ identifiers: [String]) -> [String] {
        var seen: Set<String> = []
        return identifiers.compactMap { identifier in
            let converted = convertedPluginIdentifier(identifier)
            return seen.insert(converted).inserted ? converted : nil
        }
    }

    private static func convertedPluginIdentifier(_ identifier: String) -> String {
        let sourceNamespace = "com.openfire"
        let normalized = identifier.lowercased()
        if normalized == sourceNamespace {
            return "com.actionhalo"
        }
        let sourcePrefix = sourceNamespace + "."
        guard normalized.hasPrefix(sourcePrefix) else { return identifier }
        return "com.actionhalo." + String(identifier.dropFirst(sourcePrefix.count))
    }

    private static func isLegacyPluginIdentifier(_ identifier: String) -> Bool {
        let normalized = normalizedPluginIdentifier(identifier)
        return normalized == "com.openfire" || normalized.hasPrefix("com.openfire.")
    }

    private static func normalizedPluginIdentifier(_ identifier: String) -> String {
        identifier.lowercased()
    }

    private static func pluginEntrySort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private static func isDestinationConversionCandidate(_ url: URL) -> Bool {
        legacyPackageExtensions.contains(url.pathExtension.lowercased()) ||
            isBackupPendingPackage(url)
    }

    private static func isBackupPendingPackage(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard name.hasPrefix(".backup-") else { return false }
        return legacyPackageExtensions.contains {
            name.hasSuffix(".\($0).pending")
        }
    }

    private static func isUnconfirmedPendingPackage(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let isUnconfirmed = name.hasPrefix(".install-") || name.hasPrefix(".save-")
        guard isUnconfirmed else { return false }
        return legacyPackageExtensions.contains {
            name.hasSuffix(".\($0).pending")
        }
    }

    private static func replacingLegacyEnvironmentReferences(in value: Any) -> Any {
        switch value {
        case let string as String:
            return replacingLegacyEnvironmentReferences(in: string)
        case let array as [Any]:
            return array.map(replacingLegacyEnvironmentReferences(in:))
        case let dictionary as [String: Any]:
            return dictionary.mapValues(replacingLegacyEnvironmentReferences(in:))
        default:
            return value
        }
    }

    private static func replacingLegacyEnvironmentReferences(in string: String) -> String {
        string
            .replacingOccurrences(of: "OPENFIRE_TEXT_FILE", with: "ACTIONHALO_TEXT_FILE")
            .replacingOccurrences(of: "OPENFIRE_TEXT", with: "ACTIONHALO_TEXT")
    }

    private static func markerVersion(in domain: [String: Any]) -> Int {
        (domain[importMarkerKey] as? NSNumber)?.intValue ??
            (domain[importMarkerKey] as? Int) ?? 0
    }

    private static func filesystemEntryExists(at url: URL) -> Bool {
        var fileStatus = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &fileStatus) == 0
        }
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
