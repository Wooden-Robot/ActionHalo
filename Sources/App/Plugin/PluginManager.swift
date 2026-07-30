import Cocoa
import Darwin
import JavaScriptCore
import os

/// Bounded stderr storage shared by `FileHandle`'s callback and the process
/// waiter. The callback can run on an arbitrary queue, so both fields are
/// guarded by one lock and are never captured as unsynchronized local vars.
private final class PluginProcessStderrAccumulator: Sendable {
    private struct State: Sendable {
        var data = Data()
        var isTruncated = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ chunk: Data) {
        state.withLock {
            $0.isTruncated =
                PluginManager.appendPluginProcessStderrChunk(chunk, to: &$0.data) ||
                $0.isTruncated
        }
    }

    func snapshot() -> (data: Data, isTruncated: Bool) {
        state.withLock { ($0.data, $0.isTruncated) }
    }
}

/// Manages plugin lifecycle: loading, execution, filtering, and hot-reload
///
/// Mutable manager state is protected by `state`, `trustStateQueue`, or the
/// main actor. Plugins provide a lock-protected enabled flag and main-actor
/// icon cache, so worker queues only exchange safe snapshots.
final class PluginManager: Sendable {
    struct PerAppPluginOverride: Equatable, Sendable {
        let appBundleID: String
        let pluginID: String
    }

    struct TrustedExecutionSnapshot: Sendable {
        let plugin: Plugin
        let containerURL: URL
        let fingerprint: String
    }

    struct PluginInstallPreview: Equatable, Sendable {
        let name: String
        let description: String?
        let actionType: PluginActionType
        let requiresExecutionTrust: Bool
        let fingerprint: String
    }

    struct PendingOperationRecoveryResult: Equatable, Sendable {
        var removedStagingPackages = 0
        var restoredBackupPackages = 0
        var removedRedundantBackups = 0

        var didRecoverAnything: Bool {
            removedStagingPackages > 0 ||
                restoredBackupPackages > 0 ||
                removedRedundantBackups > 0
        }
    }

    enum PluginScriptSource: Equatable, Sendable {
        case bundledFile(URL)
        case inline(String)
    }

    enum ExecutionPolicy: Equatable, Sendable {
        case standard
        case directKeyCombo
        case protected
    }

    enum PluginInstallFailure: Equatable, Sendable {
        case invalidPackage
        case invalidIdentifier(String)
        case destinationIdentifierConflict(existingIdentifier: String)
        case sourceChangedSinceConfirmation
        case stagedValidationFailed
        case fileOperationFailed(String)

        func localizedMessage(sourcePath: String) -> String {
            switch self {
            case .invalidPackage:
                return "Invalid plugin package. Make sure the .openfireext folder contains a valid Config.json.".localized
            case .invalidIdentifier(let message):
                return String(format: "Plugin identifier is invalid: %@".localized, message)
            case .destinationIdentifierConflict(let existingIdentifier):
                return String(
                    format: "Installing this plugin would replace a different plugin (%@). Rename one of the plugins and try again.".localized,
                    existingIdentifier
                )
            case .sourceChangedSinceConfirmation:
                return "The plugin changed after the install confirmation was shown. Review it and try again.".localized
            case .stagedValidationFailed:
                return "Plugin validation failed after copying. The package may have changed during installation.".localized
            case .fileOperationFailed(let message):
                return String(
                    format: "Failed to copy plugin to installation directory. Check permissions.\n(%@)\n%@".localized,
                    sourcePath,
                    message
                )
            }
        }
    }

    enum PluginInstallResult: Equatable, Sendable {
        case installed
        case failed(PluginInstallFailure)

        var isSuccess: Bool {
            if case .installed = self {
                return true
            }
            return false
        }
    }
    
    static let shared = PluginManager()
    
    /// Notification posted when plugins are reloaded
    static let pluginsReloadedNotification = Notification.Name("OpenFirePluginsReloaded")
    static let trustedPluginFingerprintsKey = "trustedPluginFingerprints"
    static let perAppDisabledPluginsKey = "perAppDisabledPlugins"
    static let verbosePluginLoggingKey = "VerbosePluginLoggingEnabled"
    static let maxPluginProcessStderrBytes = 64 * 1024
    static let maximumInstallPackageFileCount = Plugin.maximumTrustedPackageFileCount
    static let maximumInstallPackageBytes = Plugin.maximumTrustedPackageBytes
    static let maximumPluginEnvironmentTextBytes = 32 * 1024
    static let pendingOperationRecoveryMinimumAge: TimeInterval = 30
    static let allowedPluginURLSchemes: Set<String> = [
        "http",
        "https",
        "mailto",
        "dict",
    ]
    
    /// Core default plugins that can never be deleted
    static let coreDefaultPluginIDs: Set<String> = [
        "com.openfire.copy",
        "com.openfire.builtin.paste",
        "com.openfire.cut",
        "com.openfire.delete",
        "com.openfire.translate",
        "com.openfire.search", 
        "com.openfire.dictionary",
        "com.openfire.open-url",
        "com.openfire.reveal-path"
    ]
    
    private struct State: Sendable {
        var plugins: [Plugin] = []
        var userPluginsDirectoryOverride: URL?
        var latestScheduledLoadID: UInt64 = 0
        var recoveredPluginDirectoryPaths: Set<String> = []
    }

    private struct PluginPathWatcher {
        let id: UUID
        let source: DispatchSourceFileSystemObject
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    @MainActor private var pathWatchers: [String: PluginPathWatcher] = [:]
    @MainActor private var pendingReloadWorkItem: DispatchWorkItem?
    @MainActor private var pendingKeyComboTargets: [UUID: AXUIElement] = [:]

    var plugins: [Plugin] {
        get { state.withLock { $0.plugins } }
        set { state.withLock { $0.plugins = newValue } }
    }

    private let trustStateQueue = DispatchQueue(label: "com.openfire.plugin-trust-state")
    var userPluginsDirectoryOverride: URL? {
        get { state.withLock { $0.userPluginsDirectoryOverride } }
        set { state.withLock { $0.userPluginsDirectoryOverride = newValue } }
    }
    
    /// User plugins directory
    var userPluginsURL: URL {
        if let userPluginsDirectoryOverride {
            return userPluginsDirectoryOverride
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenFire/Plugins")
    }
    
    /// Built-in plugins directory
    var builtInPluginsURL: URL {
        // When packaged as a .app bundle, look in Contents/Resources/Plugins
        if let resourceURL = Bundle.main.resourceURL {
            let pluginsDir = resourceURL.appendingPathComponent("Plugins")
            if FileManager.default.fileExists(atPath: pluginsDir.path) {
                return pluginsDir
            }
        }
        // Fallback or dev: next to executable
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        return executableURL.deletingLastPathComponent().appendingPathComponent("Plugins")
    }
    
    private init() {}

    static func mergePluginsPreservingExisting(user: [Plugin], builtIn: [Plugin]) -> [Plugin] {
        var merged: [Plugin] = []
        var seenIDs: Set<String> = []

        for plugin in builtIn where coreDefaultPluginIDs.contains(plugin.id) && !seenIDs.contains(plugin.id) {
            merged.append(plugin)
            seenIDs.insert(plugin.id)
        }

        for plugin in user where !coreDefaultPluginIDs.contains(plugin.id) && !seenIDs.contains(plugin.id) {
            merged.append(plugin)
            seenIDs.insert(plugin.id)
        }

        for plugin in builtIn where !seenIDs.contains(plugin.id) {
            merged.append(plugin)
            seenIDs.insert(plugin.id)
        }

        return merged
    }

    static func isVerbosePluginLoggingEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: verbosePluginLoggingKey)
    }

    private static func verboseLog(_ message: @autoclosure () -> String) {
        guard isVerbosePluginLoggingEnabled() else { return }
        NSLog("[OpenFire-Debug] %@", message())
    }

    static func pluginProcessEnvironment(
        text: String,
        textFilePath: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        environment.removeValue(forKey: "OPENFIRE_TEXT")
        environment["OPENFIRE_TEXT_FILE"] = textFilePath

        if !text.contains("\0"),
           text.utf8.count <= maximumPluginEnvironmentTextBytes {
            environment["OPENFIRE_TEXT"] = text
        }

        return environment
    }

    static func isAllowedPluginURLTemplate(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let sample = renderedURLString(template: trimmed, text: "openfire")
        guard let components = URLComponents(string: sample),
              let scheme = components.scheme?.lowercased(),
              allowedPluginURLSchemes.contains(scheme) else {
            return false
        }

        return true
    }

    static func executionPolicy(for plugin: Plugin) -> ExecutionPolicy {
        switch plugin.config.action.type {
        case .shellScript, .applescript:
            return .protected
        case .keyCombo:
            return plugin.requiresExecutionTrust ? .protected : .directKeyCombo
        default:
            return .standard
        }
    }

    static func pluginProcessStderrLogMessage(
        logPrefix: String,
        stderr: String,
        terminationStatus: Int32,
        verboseLoggingEnabled: Bool
    ) -> String? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if verboseLoggingEnabled {
            return "\(logPrefix) stderr: \(stderr)"
        }

        guard terminationStatus != 0 else { return nil }
        return "\(logPrefix) produced stderr (\(stderr.utf8.count) bytes). Enable verbose plugin logging to inspect output."
    }

    static func filterSoftDeletedBuiltIns(
        _ plugins: [Plugin],
        deletedBuiltInPluginIDs: [String],
        builtInPluginsURL: URL
    ) -> [Plugin] {
        let deletedIDs = Set(deletedBuiltInPluginIDs).subtracting(coreDefaultPluginIDs)
        guard !deletedIDs.isEmpty else { return plugins }

        return plugins.filter { plugin in
            guard deletedIDs.contains(plugin.id),
                  isBuiltInPluginDirectory(plugin.directoryURL, builtInPluginsURL: builtInPluginsURL) else {
                return true
            }
            return false
        }
    }

    static func isPluginDirectory(_ pluginURL: URL, inside parentURL: URL) -> Bool {
        let parentPath = parentURL.standardizedFileURL.resolvingSymlinksInPath().path
        let pluginPath = pluginURL.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"

        return pluginPath.hasPrefix(parentPrefix)
    }

    static func isBuiltInPluginDirectory(
        _ pluginURL: URL,
        builtInPluginsURL: URL = PluginManager.shared.builtInPluginsURL
    ) -> Bool {
        isPluginDirectory(pluginURL, inside: builtInPluginsURL)
    }

    static func pluginPackageDirectories(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { url in
                guard url.pathExtension == "openfireext" else { return false }
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ) else {
                    return false
                }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    static func watchablePluginDirectories(
        userPluginsURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        [userPluginsURL] + pluginPackageDirectories(in: userPluginsURL, fileManager: fileManager)
    }

    static func watchablePluginPaths(
        userPluginsURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let packageURLs = pluginPackageDirectories(
            in: userPluginsURL,
            fileManager: fileManager
        )
        var paths = [userPluginsURL]

        for packageURL in packageURLs {
            paths.append(packageURL)
            for fileName in ["Config.json", "icon.png"] {
                let fileURL = packageURL.appendingPathComponent(fileName)
                if let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ),
                   values.isRegularFile == true,
                   values.isSymbolicLink != true {
                    paths.append(fileURL)
                }
            }

            if let plugin = PluginLoader.load(from: packageURL),
               let scriptValue = plugin.config.action.script,
               case .bundledFile(let scriptURL) = resolvedPluginScriptSource(
                   scriptValue,
                   pluginDirectoryURL: packageURL,
                   fileManager: fileManager
               ) {
                paths.append(scriptURL)
            }
        }

        var seenPaths: Set<String> = []
        return paths.filter {
            seenPaths.insert(watchPath(for: $0)).inserted
        }
    }

    static func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path ==
            rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isReservedCorePluginIdentifier(_ identifier: String) -> Bool {
        coreDefaultPluginIDs.contains(identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func pluginIdentifierValidationMessage(
        _ identifier: String,
        allowReservedCoreIdentifier: Bool = false,
        allowLegacyBoundaryCharacters: Bool = false
    ) -> String? {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !id.isEmpty else {
            return "Name and Identifier cannot be empty.".localized
        }

        if id != identifier || id.count > 128 {
            return "Identifier must use only letters, numbers, dots, and hyphens.".localized
        }

        let identifierPattern = #"^[A-Za-z0-9.-]+$"#
        if id.range(of: identifierPattern, options: .regularExpression) == nil {
            return "Identifier must use only letters, numbers, dots, and hyphens.".localized
        }

        if !allowLegacyBoundaryCharacters,
           (id.hasPrefix(".") || id.hasPrefix("-") || id.hasSuffix(".") || id.hasSuffix("-") || id.contains("..")) {
            return "Identifier cannot start or end with dots or hyphens.".localized
        }

        if !allowReservedCoreIdentifier, isReservedCorePluginIdentifier(id) {
            return "Identifier is reserved for a built-in plugin.".localized
        }

        return nil
    }

    static func visibleUserPluginFileName(for identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let sanitizedScalars = identifier.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        let sanitized = sanitizedScalars.joined()
        let visibleBase = sanitized
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            .isEmpty ? "custom-plugin" : sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))

        return "\(visibleBase).openfireext"
    }

    static func pendingPluginPackageURL(
        in directoryURL: URL,
        prefix: String
    ) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        return directoryURL.appendingPathComponent(
            ".\(prefix)-t\(timestamp)-\(UUID().uuidString).openfireext.pending"
        )
    }

    static func repairHiddenUserPluginPackages(in userPluginsURL: URL, fileManager: FileManager = .default) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: userPluginsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []

        for packageURL in contents where packageURL.lastPathComponent.hasPrefix(".") && packageURL.pathExtension == "openfireext" {
            guard (try? packageURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let plugin = PluginLoader.load(from: packageURL) else {
                continue
            }

            let visibleURL = userPluginsURL.appendingPathComponent(visibleUserPluginFileName(for: plugin.id))
            guard !Self.sameFileURL(visibleURL, packageURL),
                  !fileManager.fileExists(atPath: visibleURL.path) else {
                continue
            }

            do {
                try fileManager.moveItem(at: packageURL, to: visibleURL)
                NSLog("[OpenFire] Repaired hidden plugin package: \(packageURL.lastPathComponent) -> \(visibleURL.lastPathComponent)")
            } catch {
                NSLog("[OpenFire] Failed to repair hidden plugin package \(packageURL.path): \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    static func recoverInterruptedPluginOperations(
        in userPluginsURL: URL,
        fileManager: FileManager = .default,
        minimumAge: TimeInterval = pendingOperationRecoveryMinimumAge,
        now: Date = Date()
    ) -> PendingOperationRecoveryResult {
        var result = PendingOperationRecoveryResult()
        let contents = (try? fileManager.contentsOfDirectory(
            at: userPluginsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        )) ?? []

        for pendingURL in contents {
            let name = pendingURL.lastPathComponent
            let isStaging = name.hasPrefix(".install-") || name.hasPrefix(".save-")
            let isBackup = name.hasPrefix(".backup-")
            guard (isStaging || isBackup),
                  name.hasSuffix(".openfireext.pending") else {
                continue
            }

            guard minimumAge <= 0 || {
                let encodedTimestamp = name
                    .split(separator: "-")
                    .first(where: { $0.hasPrefix("t") })
                    .flatMap { TimeInterval($0.dropFirst()) }
                    .map(Date.init(timeIntervalSince1970:))
                if let encodedTimestamp {
                    return now.timeIntervalSince(encodedTimestamp) >= minimumAge
                }

                guard let values = try? pendingURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .creationDateKey]
                ) else {
                    return false
                }
                let timestamps = [
                    values.contentModificationDate,
                    values.creationDate,
                ].compactMap { $0 }
                guard let newestTimestamp = timestamps.max() else { return false }
                return now.timeIntervalSince(newestTimestamp) >= minimumAge
            }() else {
                continue
            }

            if isStaging {
                if (try? fileManager.removeItem(at: pendingURL)) != nil {
                    result.removedStagingPackages += 1
                }
                continue
            }

            // A backup is only moved after the original destination was removed.
            // Its validated identifier gives us a safe, canonical recovery target.
            guard let backupPlugin = PluginLoader.load(from: pendingURL) else {
                continue
            }
            let destinationURL = userPluginsURL.appendingPathComponent(
                visibleUserPluginFileName(for: backupPlugin.id)
            )
            guard isPluginDirectory(destinationURL, inside: userPluginsURL) else {
                continue
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                if (try? fileManager.removeItem(at: pendingURL)) != nil {
                    result.removedRedundantBackups += 1
                }
            } else if (try? fileManager.moveItem(at: pendingURL, to: destinationURL)) != nil {
                result.restoredBackupPackages += 1
            }
        }

        return result
    }
    
    // MARK: - Loading

    func beginPluginLoad() -> UInt64 {
        state.withLock {
            $0.latestScheduledLoadID += 1
            return $0.latestScheduledLoadID
        }
    }

    func shouldApplyPluginLoadResult(_ loadID: UInt64) -> Bool {
        state.withLock {
            loadID == $0.latestScheduledLoadID
        }
    }

    private func shouldRecoverInterruptedOperations(in directoryURL: URL) -> Bool {
        let path = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        return state.withLock {
            $0.recoveredPluginDirectoryPaths.insert(path).inserted
        }
    }
    
    func loadAllPlugins() {
        let loadID = beginPluginLoad()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Load built-in plugins
            let builtIn = PluginLoader.scanDirectory(
                self.builtInPluginsURL,
                allowReservedCoreIdentifiers: true
            )
            
            // Load user plugins
            if self.shouldRecoverInterruptedOperations(in: self.userPluginsURL) {
                let recoveryDirectoryURL = self.userPluginsURL
                Self.recoverInterruptedPluginOperations(in: recoveryDirectoryURL)

                // A crash may have happened less than the safety age ago. Retry
                // once after the age expires, while avoiding active staging dirs.
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + Self.pendingOperationRecoveryMinimumAge
                ) { [weak self] in
                    let result = Self.recoverInterruptedPluginOperations(
                        in: recoveryDirectoryURL
                    )
                    guard result.didRecoverAnything else { return }
                    self?.reloadPlugins()
                }
            }
            Self.repairHiddenUserPluginPackages(in: self.userPluginsURL)
            let user = PluginLoader.scanDirectory(self.userPluginsURL)
            
            let mergedPlugins = Self.mergePluginsPreservingExisting(user: user, builtIn: builtIn)
            let deletedBuiltIns = UserDefaults.standard.stringArray(forKey: "deletedBuiltInPlugins") ?? []
            let newPlugins = Self.filterSoftDeletedBuiltIns(
                mergedPlugins,
                deletedBuiltInPluginIDs: deletedBuiltIns,
                builtInPluginsURL: self.builtInPluginsURL
            )
            
            DispatchQueue.main.async {
                guard self.shouldApplyPluginLoadResult(loadID) else {
                    NSLog("[OpenFire] Discarding stale plugin load result #\(loadID)")
                    return
                }

                self.plugins = newPlugins
                
                // Prewarm assets to eliminate first-launch stutter
                RadialMenuView.prewarm(plugins: newPlugins)
                
                // Restore enabled/disabled state from UserDefaults
                self.restorePluginStates()

                // A Config.json write can briefly expose an incomplete file.
                // Rebuild file watchers from the final applied configuration so
                // a newly selected action script is never left unwatched.
                if !self.pathWatchers.isEmpty {
                    self.refreshUserPluginPackageWatchers()
                }
                
                NSLog("[OpenFire] Loaded \(self.plugins.count) plugins total (\(builtIn.count) built-in, \(user.count) user)")
                
                NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: self)
            }
        }
    }
    
    /// Reload plugins (e.g., after directory change)
    func reloadPlugins() {
        loadAllPlugins()
    }

    @MainActor
    private func scheduleReloadPlugins(after delay: TimeInterval = 0.2) {
        pendingReloadWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.loadAllPlugins()
        }
        pendingReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    
    // MARK: - Filtering
    
    /// Get enabled plugins that should be shown in the menu for the app context.
    /// Text-specific filters are evaluated later so mismatched plugins can remain visible but disabled.
    func presentationPlugins(appBundleID: String?) -> [Plugin] {
        orderedPluginsForDisplay().filter { plugin in
            plugin.isEnabled && isPluginEnabled(plugin.id, forAppBundleID: appBundleID)
        }
    }

    func visibilityDiagnostics(for text: String, appBundleID: String?) -> [PluginVisibilityDiagnostic] {
        orderedPluginsForDisplay().map { plugin in
            var diagnostic = plugin.visibilityDiagnostic(text: text, appBundleID: appBundleID)
            if let appBundleID, plugin.isEnabled, !isPluginEnabled(plugin.id, forAppBundleID: appBundleID) {
                diagnostic = PluginVisibilityDiagnostic(
                    plugin: plugin,
                    reasons: [.disabledForApp(appBundleID)] + diagnostic.reasons
                )
            }
            return diagnostic
        }
    }
    
    // MARK: - Plugin State
    
    func setPluginEnabled(_ identifier: String, enabled: Bool) {
        if let plugin = plugins.first(where: { $0.id == identifier }) {
            plugin.isEnabled = enabled
            savePluginStates()
            NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: self)
        }
    }

    func isPluginEnabled(_ identifier: String, forAppBundleID appBundleID: String?) -> Bool {
        guard let appBundleID else { return true }
        let disabledByApp = perAppDisabledPlugins()[appBundleID] ?? []
        return !disabledByApp.contains(identifier)
    }

    func setPluginEnabled(_ identifier: String, enabled: Bool, forAppBundleID appBundleID: String) {
        var allOverrides = perAppDisabledPlugins()
        var disabledByApp = allOverrides[appBundleID] ?? []

        if enabled {
            disabledByApp.removeAll { $0 == identifier }
        } else if !disabledByApp.contains(identifier) {
            disabledByApp.append(identifier)
        }

        if disabledByApp.isEmpty {
            allOverrides.removeValue(forKey: appBundleID)
        } else {
            allOverrides[appBundleID] = disabledByApp.sorted()
        }

        UserDefaults.standard.set(allOverrides, forKey: Self.perAppDisabledPluginsKey)
        NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: self)
    }

    func disabledPluginIDs(forAppBundleID appBundleID: String) -> [String] {
        perAppDisabledPlugins()[appBundleID] ?? []
    }

    func allPerAppDisabledPluginOverrides() -> [PerAppPluginOverride] {
        perAppDisabledPlugins()
            .flatMap { appBundleID, pluginIDs in
                pluginIDs.map { PerAppPluginOverride(appBundleID: appBundleID, pluginID: $0) }
            }
            .sorted {
                if $0.pluginID == $1.pluginID {
                    return $0.appBundleID.localizedCaseInsensitiveCompare($1.appBundleID) == .orderedAscending
                }
                return $0.pluginID.localizedCaseInsensitiveCompare($1.pluginID) == .orderedAscending
            }
    }

    func clearPerAppOverride(pluginID: String, forAppBundleID appBundleID: String) {
        setPluginEnabled(pluginID, enabled: true, forAppBundleID: appBundleID)
    }

    func isExecutionTrusted(for plugin: Plugin) -> Bool {
        guard plugin.requiresExecutionTrust else { return true }
        guard let fingerprint = plugin.executionTrustFingerprint else { return false }
        return isStoredExecutionTrustValid(pluginID: plugin.id, fingerprint: fingerprint)
    }

    func setExecutionTrusted(_ trusted: Bool, for plugin: Plugin) {
        guard plugin.requiresExecutionTrust else { return }
        let fingerprint = trusted ? plugin.executionTrustFingerprint : nil
        storeExecutionTrust(trusted, pluginID: plugin.id, fingerprint: fingerprint)
    }

    private func isStoredExecutionTrustValid(pluginID: String, fingerprint: String) -> Bool {
        trustStateQueue.sync {
            let stored = UserDefaults.standard.dictionary(
                forKey: Self.trustedPluginFingerprintsKey
            ) as? [String: String] ?? [:]
            return stored[pluginID] == fingerprint
        }
    }

    private func storeExecutionTrust(
        _ trusted: Bool,
        pluginID: String,
        fingerprint: String?
    ) {
        trustStateQueue.sync {
            var stored = UserDefaults.standard.dictionary(
                forKey: Self.trustedPluginFingerprintsKey
            ) as? [String: String] ?? [:]
            if trusted, let fingerprint {
                stored[pluginID] = fingerprint
            } else {
                stored.removeValue(forKey: pluginID)
            }
            UserDefaults.standard.set(stored, forKey: Self.trustedPluginFingerprintsKey)
        }
    }

    func makeTrustedExecutionSnapshot(for plugin: Plugin) -> TrustedExecutionSnapshot? {
        guard let snapshot = makeProtectedExecutionSnapshot(for: plugin) else { return nil }
        guard isStoredExecutionTrustValid(
            pluginID: snapshot.plugin.id,
            fingerprint: snapshot.fingerprint
        ) else {
            removeTrustedExecutionSnapshot(snapshot)
            return nil
        }
        return snapshot
    }

    func removeTrustedExecutionSnapshot(_ snapshot: TrustedExecutionSnapshot) {
        do {
            try FileManager.default.removeItem(at: snapshot.containerURL)
        } catch {
            NSLog("[OpenFire] Failed to remove trusted plugin execution snapshot: \(error.localizedDescription)")
        }
    }

    private func makeProtectedExecutionSnapshot(for plugin: Plugin) -> TrustedExecutionSnapshot? {
        guard plugin.canCreateProtectedExecutionSnapshot else { return nil }

        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let sourceValues = try? plugin.directoryURL.resourceValues(forKeys: resourceKeys),
              sourceValues.isDirectory == true,
              sourceValues.isSymbolicLink != true else {
            return nil
        }

        let containerURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenFire-Trusted-Execution-\(UUID().uuidString)", isDirectory: true)
        let packageURL = containerURL.appendingPathComponent(
            plugin.directoryURL.lastPathComponent,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: containerURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: plugin.directoryURL, to: packageURL)

            guard let snapshotPlugin = PluginLoader.load(from: packageURL),
                  snapshotPlugin.id == plugin.id,
                  snapshotPlugin.config.action.type == plugin.config.action.type,
                  snapshotPlugin.requiresExecutionTrust,
                  let fingerprint = snapshotPlugin.executionTrustFingerprint else {
                try? fileManager.removeItem(at: containerURL)
                return nil
            }

            return TrustedExecutionSnapshot(
                plugin: snapshotPlugin,
                containerURL: containerURL,
                fingerprint: fingerprint
            )
        } catch {
            try? fileManager.removeItem(at: containerURL)
            NSLog("[OpenFire] Failed to create trusted plugin execution snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func confirmExecutionTrustIfNeeded(
        for plugin: Plugin,
        displayDirectoryURL: URL? = nil,
        fingerprint suppliedFingerprint: String? = nil
    ) -> Bool {
        guard plugin.requiresExecutionTrust else { return true }
        guard let fingerprint = suppliedFingerprint ?? plugin.executionTrustFingerprint else {
            return false
        }
        guard !isStoredExecutionTrustValid(
            pluginID: plugin.id,
            fingerprint: fingerprint
        ) else {
            return true
        }

        let prompt: @MainActor @Sendable () -> Bool = {
            let alert = NSAlert()
            alert.messageText = "Trust Plugin Before Running".localized
            alert.informativeText = String(
                format: "Plugin '%@' can perform protected actions on your Mac.\n\nType: %@\nLocation: %@\n\nOnly allow this if you trust the plugin source. You will be asked again if the plugin changes.".localized,
                plugin.name,
                plugin.config.action.type.rawValue,
                (displayDirectoryURL ?? plugin.directoryURL).path
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Trust and Run".localized)
            alert.addButton(withTitle: "Cancel".localized)

            NSApp.activate(ignoringOtherApps: true)
            let trusted = alert.runModal() == .alertFirstButtonReturn
            self.storeExecutionTrust(
                trusted,
                pluginID: plugin.id,
                fingerprint: trusted ? fingerprint : nil
            )
            return trusted && self.isStoredExecutionTrustValid(
                pluginID: plugin.id,
                fingerprint: fingerprint
            )
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                prompt()
            }
        }

        return DispatchQueue.main.sync(execute: prompt)
    }
    
    private func savePluginStates() {
        var disabledPlugins: [String] = []
        var userEnabledPlugins: [String] = []
        
        for plugin in plugins {
            if plugin.config.isDefaultDisabled == true {
                if plugin.isEnabled {
                    userEnabledPlugins.append(plugin.id)
                }
            } else {
                if !plugin.isEnabled {
                    disabledPlugins.append(plugin.id)
                }
            }
        }
        UserDefaults.standard.set(disabledPlugins, forKey: "disabledPlugins")
        UserDefaults.standard.set(userEnabledPlugins, forKey: "userEnabledPlugins")
    }
    
    private func restorePluginStates() {
        let disabledPlugins = UserDefaults.standard.stringArray(forKey: "disabledPlugins") ?? []
        // We also need a way to track explicitly enabled plugins to override `isDefaultDisabled`
        let userEnabledPlugins = UserDefaults.standard.stringArray(forKey: "userEnabledPlugins") ?? []
        
        for plugin in plugins {
            if plugin.config.isDefaultDisabled == true {
                // It's disabled by default, only enable if explicitly enabled by user
                plugin.isEnabled = userEnabledPlugins.contains(plugin.id)
            } else {
                // Enabled by default, only disable if explicitly disabled by user
                plugin.isEnabled = !disabledPlugins.contains(plugin.id)
            }
        }
    }

    static func orderedPlugins(_ plugins: [Plugin], savedOrder: [String]) -> [Plugin] {
        guard !savedOrder.isEmpty else {
            return plugins.sorted { $0.order < $1.order }
        }

        var orderMap: [String: Int] = [:]
        for (index, pluginID) in savedOrder.enumerated() where orderMap[pluginID] == nil {
            orderMap[pluginID] = index
        }

        return plugins.sorted { lhs, rhs in
            switch (orderMap[lhs.id], orderMap[rhs.id]) {
            case let (lhsIndex?, rhsIndex?):
                return lhsIndex < rhsIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if lhs.order != rhs.order {
                    return lhs.order < rhs.order
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        }
    }

    func orderedPluginsForDisplay() -> [Plugin] {
        let savedOrder = UserDefaults.standard.stringArray(forKey: "pluginOrder") ?? []
        return Self.orderedPlugins(plugins, savedOrder: savedOrder)
    }

    private func perAppDisabledPlugins() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: Self.perAppDisabledPluginsKey) as? [String: [String]] ?? [:]
    }

    func userPluginURL(for identifier: String) -> URL? {
        guard Self.pluginIdentifierValidationMessage(
            identifier,
            allowReservedCoreIdentifier: true
        ) == nil else {
            return nil
        }
        return userPluginURLs(for: identifier).first
    }

    func userPluginURLs(for identifier: String) -> [URL] {
        guard Self.pluginIdentifierValidationMessage(
            identifier,
            allowReservedCoreIdentifier: true
        ) == nil else {
            return []
        }

        let fileManager = FileManager.default

        let contents = (try? fileManager.contentsOfDirectory(
            at: userPluginsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var matches: [URL] = []
        for itemURL in contents where itemURL.pathExtension == "openfireext" {
            guard Self.isPluginDirectory(itemURL, inside: userPluginsURL),
                  let values = try? itemURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            guard let plugin = PluginLoader.load(from: itemURL) else { continue }
            if plugin.id == identifier {
                matches.append(itemURL)
            }
        }

        return matches.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func removeDuplicateUserPlugins(for identifier: String, keeping preservedURL: URL? = nil) {
        for url in userPluginURLs(for: identifier) where !Self.shouldPreservePluginURL(url, preservedURL: preservedURL) {
            guard Self.isPluginDirectory(url, inside: userPluginsURL) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func shouldPreservePluginURL(_ url: URL, preservedURL: URL?) -> Bool {
        guard let preservedURL else { return false }
        return sameFileURL(url, preservedURL)
    }
    
    func deletePlugin(_ plugin: Plugin) throws {
        // Core defaults cannot be deleted
        if PluginManager.coreDefaultPluginIDs.contains(plugin.id) {
            return
        }
        
        let isBuiltIn = Self.isBuiltInPluginDirectory(plugin.directoryURL, builtInPluginsURL: builtInPluginsURL)
        let actualUserPluginURL = Self.isPluginDirectory(
            plugin.directoryURL,
            inside: userPluginsURL
        ) ? plugin.directoryURL : nil
        let userOverrideURL = actualUserPluginURL ?? userPluginURL(for: plugin.id)

        if let userOverrideURL,
           Self.isPluginDirectory(userOverrideURL, inside: userPluginsURL) {
            // Delete the user override file physically
            try FileManager.default.removeItem(at: userOverrideURL)
        } else if isBuiltIn {
            // Soft delete the built-in plugin by marking it in UserDefaults
            // This avoids breaking the app's code signature by deleting files inside the .app bundle
            var deletedBuiltIns = UserDefaults.standard.stringArray(forKey: "deletedBuiltInPlugins") ?? []
            if !deletedBuiltIns.contains(plugin.id) {
                deletedBuiltIns.append(plugin.id)
                UserDefaults.standard.set(deletedBuiltIns, forKey: "deletedBuiltInPlugins")
            }
        } else {
            // Refuse to remove arbitrary paths that are not one of our plugin roots.
            throw CocoaError(.fileWriteNoPermission)
        }
        
        reloadPlugins()
    }
    
    // MARK: - Hot Reload (File System Watching)
    
    @MainActor
    func startWatchingPluginDirectories() {
        try? FileManager.default.createDirectory(
            at: userPluginsURL,
            withIntermediateDirectories: true
        )
        refreshUserPluginPackageWatchers()
    }
    
    @MainActor
    func stopWatchingPluginDirectories() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        for watcher in pathWatchers.values {
            watcher.source.cancel()
        }
        pathWatchers.removeAll()
    }
    
    private static func watchPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    @MainActor
    private func refreshUserPluginPackageWatchers() {
        let watchableURLs = Self.watchablePluginPaths(
            userPluginsURL: userPluginsURL
        )
        let watchablePaths = Set(watchableURLs.map { Self.watchPath(for: $0) })

        let stalePaths = pathWatchers.keys.filter {
            !watchablePaths.contains($0)
        }
        for path in stalePaths {
            pathWatchers[path]?.source.cancel()
            pathWatchers.removeValue(forKey: path)
        }

        for url in watchableURLs {
            watchFileSystemObject(at: url)
        }
    }

    @MainActor
    private func watchFileSystemObject(at url: URL) {
        let watchPath = Self.watchPath(for: url)
        guard pathWatchers[watchPath] == nil else { return }
        
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[OpenFire] Failed to watch directory: \(url.path)")
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        let watcherID = UUID()
        
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.pathWatchers[watchPath]?.id == watcherID else {
                    return
                }
                NSLog("[OpenFire] Plugin package changed, reloading...")
                self.pathWatchers[watchPath]?.source.cancel()
                self.pathWatchers.removeValue(forKey: watchPath)
                self.refreshUserPluginPackageWatchers()
                self.scheduleReloadPlugins()
            }
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        pathWatchers[watchPath] = PluginPathWatcher(
            id: watcherID,
            source: source
        )
        
        NSLog("[OpenFire] Watching plugin path: \(url.path)")
    }
    
    // MARK: - Plugin Execution

    nonisolated static func isExpectedKeyComboTarget(
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        expectedFocusedElement: AXUIElement?,
        currentFocusedElement: AXUIElement?
    ) -> Bool {
        AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ) && AccessibilityManager.areSameAccessibilityElement(
            expectedFocusedElement,
            currentFocusedElement
        )
    }
    
    /// Execute a plugin action with the given text
    @MainActor
    func executePlugin(
        _ plugin: Plugin,
        with text: String,
        targetProcessIdentifier: pid_t?,
        targetFocusedElement: AXUIElement?
    ) {
        let action = plugin.config.action
        let resolvedTargetProcessIdentifier =
            targetProcessIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        Self.verboseLog(
            "executePlugin plugin=\(plugin.id) type=\(action.type.rawValue) textLength=\(text.count)"
        )

        switch Self.executionPolicy(for: plugin) {
        case .protected:
            let keyComboTargetID: UUID?
            if action.type == .keyCombo, let targetFocusedElement {
                let targetID = UUID()
                pendingKeyComboTargets[targetID] = targetFocusedElement
                keyComboTargetID = targetID
            } else {
                keyComboTargetID = nil
            }
            executeProtectedPlugin(
                plugin,
                with: text,
                targetProcessIdentifier: resolvedTargetProcessIdentifier,
                keyComboTargetID: keyComboTargetID
            )
        case .directKeyCombo:
            guard let resolvedTargetProcessIdentifier,
                  Self.isExpectedKeyComboTarget(
                    expectedProcessIdentifier: resolvedTargetProcessIdentifier,
                    currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    expectedFocusedElement: targetFocusedElement,
                    currentFocusedElement: AccessibilityManager.shared.getFocusedElement()
                  ) else {
                NSLog("[OpenFire] Refusing key combo '%@': the original focused target changed.", plugin.id)
                return
            }
            executeKeyCombo(
                action,
                targetProcessIdentifier: resolvedTargetProcessIdentifier
            )
        case .standard:
            executeStandardPlugin(
                action,
                text: text,
                targetProcessIdentifier: resolvedTargetProcessIdentifier
            )
        }
    }

    private func executeStandardPlugin(
        _ action: PluginActionConfig,
        text: String,
        targetProcessIdentifier: pid_t?
    ) {
        switch action.type {
        case .url:
            executeURLAction(action, text: text)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .paste:
            guard let targetProcessIdentifier,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier else {
                return
            }
            ActionExecutor.shared.simulateKeyCombo(
                key: 0x09,
                modifiers: .maskCommand,
                targetProcessIdentifier: targetProcessIdentifier
            )
        case .revealPath:
            ActionExecutor.revealPathInFinder(text)
        case .shellScript, .applescript, .keyCombo:
            assertionFailure("Protected and direct key-combo actions must be routed before standard execution.")
        }
    }

    private func executeProtectedPlugin(
        _ plugin: Plugin,
        with text: String,
        targetProcessIdentifier: pid_t?,
        keyComboTargetID: UUID?
    ) {
        let displayDirectoryURL = plugin.directoryURL
        let pluginID = plugin.id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let snapshot = self.makeProtectedExecutionSnapshot(for: plugin) else {
                self.discardPendingKeyComboTarget(keyComboTargetID)
                NSLog("[OpenFire] Refusing to execute plugin '%@': could not create a verified snapshot.", pluginID)
                return
            }

            guard self.confirmExecutionTrustIfNeeded(
                for: snapshot.plugin,
                displayDirectoryURL: displayDirectoryURL,
                fingerprint: snapshot.fingerprint
            ), self.isStoredExecutionTrustValid(
                pluginID: snapshot.plugin.id,
                fingerprint: snapshot.fingerprint
            ) else {
                self.removeTrustedExecutionSnapshot(snapshot)
                self.discardPendingKeyComboTarget(keyComboTargetID)
                return
            }

            let action = snapshot.plugin.config.action
            switch action.type {
            case .shellScript:
                self.executeShellScript(
                    snapshot.plugin,
                    action: action,
                    text: text,
                    cleanupSnapshot: snapshot
                )
            case .applescript:
                self.executeAppleScript(
                    snapshot.plugin,
                    action: action,
                    text: text,
                    cleanupSnapshot: snapshot
                )
            case .keyCombo:
                self.executeTrustedKeyCombo(
                    action,
                    targetProcessIdentifier: targetProcessIdentifier,
                    keyComboTargetID: keyComboTargetID,
                    cleanupSnapshot: snapshot
                )
            default:
                self.removeTrustedExecutionSnapshot(snapshot)
                self.discardPendingKeyComboTarget(keyComboTargetID)
            }
        }
    }

    private func discardPendingKeyComboTarget(_ targetID: UUID?) {
        guard let targetID else { return }
        Task { @MainActor [weak self] in
            _ = self?.pendingKeyComboTargets.removeValue(forKey: targetID)
        }
    }

    private func executeTrustedKeyCombo(
        _ action: PluginActionConfig,
        targetProcessIdentifier: pid_t?,
        keyComboTargetID: UUID?,
        cleanupSnapshot: TrustedExecutionSnapshot
    ) {
        DispatchQueue.main.async {
            guard let keyComboTargetID,
                  let targetFocusedElement = self.pendingKeyComboTargets.removeValue(
                    forKey: keyComboTargetID
                  ),
                  let targetProcessIdentifier,
                  let targetApplication = NSRunningApplication(
                    processIdentifier: targetProcessIdentifier
                  ) else {
                self.removeTrustedExecutionSnapshot(cleanupSnapshot)
                return
            }

            let executeIfStillTargeted: @MainActor @Sendable () -> Void = {
                defer { self.removeTrustedExecutionSnapshot(cleanupSnapshot) }
                guard Self.isExpectedKeyComboTarget(
                    expectedProcessIdentifier: targetProcessIdentifier,
                    currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    expectedFocusedElement: targetFocusedElement,
                    currentFocusedElement: AccessibilityManager.shared.getFocusedElement()
                ) else {
                    return
                }
                self.executeKeyCombo(
                    action,
                    targetProcessIdentifier: targetProcessIdentifier
                )
            }

            let frontmostProcessIdentifier =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostProcessIdentifier == targetProcessIdentifier {
                executeIfStillTargeted()
            } else if frontmostProcessIdentifier == ProcessInfo.processInfo.processIdentifier,
                      targetApplication.activate(options: [.activateIgnoringOtherApps]) {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.05,
                    execute: executeIfStillTargeted
                )
            } else {
                self.removeTrustedExecutionSnapshot(cleanupSnapshot)
            }
        }
    }
    
    // MARK: - Action Execution
    
    private func executeURLAction(_ action: PluginActionConfig, text: String) {
        guard var urlTemplate = action.url else { return }
        guard Self.isAllowedPluginURLTemplate(urlTemplate) else {
            NSLog("[OpenFire] Refusing URL action with unsupported scheme.")
            return
        }

        urlTemplate = Self.renderedURLString(template: urlTemplate, text: text)
        
        guard let url = URL(string: urlTemplate),
              let scheme = url.scheme?.lowercased(),
              Self.allowedPluginURLSchemes.contains(scheme) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func renderedURLString(template: String, text: String) -> String {
        if template.trimmingCharacters(in: .whitespacesAndNewlines) == "{text}" {
            return normalizedDirectURLString(from: text)
        }

        return template.replacingOccurrences(
            of: "{text}",
            with: encodedURLPlaceholderText(text)
        )
    }

    static func encodedURLPlaceholderText(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func normalizedDirectURLString(from text: String) -> String {
        var urlString = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.contains("://") {
            urlString = "https://\(urlString)"
        }
        return urlString
    }
    
    private func executeShellScript(
        _ plugin: Plugin,
        action: PluginActionConfig,
        text: String,
        cleanupSnapshot: TrustedExecutionSnapshot
    ) {
        Self.verboseLog("Entering executeShellScript for plugin: \(plugin.id)")
        let scriptContent: String?
        
        if let scriptName = action.script {
            switch Self.resolvedPluginScriptSource(
                scriptName,
                pluginDirectoryURL: plugin.directoryURL
            ) {
            case .bundledFile(let scriptURL):
                var enc: String.Encoding = .utf8
                scriptContent = try? String(contentsOf: scriptURL, usedEncoding: &enc)
                Self.verboseLog("Loaded shell script from file: \(scriptURL.path) (encoding: \(enc))")
            case .inline(let inline):
                scriptContent = inline
                Self.verboseLog("Using legacy inline shell script from the script field")
            case nil:
                NSLog("[OpenFire] Refusing shell script outside the verified plugin package: \(scriptName)")
                scriptContent = nil
            }
        } else if let inline = action.inline {
            Self.verboseLog("Found inline action config for Shell Script")
            scriptContent = inline
        } else {
            Self.verboseLog("Neither inline nor script field found in config!")
            removeTrustedExecutionSnapshot(cleanupSnapshot)
            return
        }
        
        guard let content = scriptContent else {
            Self.verboseLog("shell scriptContent is nil, aborting")
            removeTrustedExecutionSnapshot(cleanupSnapshot)
            return
        }
        
        Self.verboseLog("Shell script content resolved, preparing to run bash")
        
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.removeTrustedExecutionSnapshot(cleanupSnapshot) }
            // Write selected text to a temp file for reliable Unicode/CJK support
            let textFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            do {
                try text.write(to: textFile, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[OpenFire] Failed to prepare selected text for shell script: \(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(at: textFile) }
            let scriptFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".sh")
            do {
                try content.write(to: scriptFile, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[OpenFire] Failed to prepare shell script: \(error.localizedDescription)")
                return
            }
            defer { try? FileManager.default.removeItem(at: scriptFile) }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Keep untrusted script content out of argv. Embedded NUL and very
            // large scripts are valid file content but unsafe Process arguments.
            process.arguments = [scriptFile.path]
            process.environment = Self.pluginProcessEnvironment(
                text: text,
                textFilePath: textFile.path
            )
            process.currentDirectoryURL = plugin.directoryURL
            
            Self.verboseLog("Launching bash process")
            self.runProcessWithTimeout(
                process,
                timeout: 30,
                logPrefix: "Shell script"
            )
        }
    }
    
    private func executeAppleScript(
        _ plugin: Plugin,
        action: PluginActionConfig,
        text: String,
        cleanupSnapshot: TrustedExecutionSnapshot
    ) {
        Self.verboseLog("Entering executeAppleScript for plugin: \(plugin.id)")
        var source: String?
        
        if let scriptName = action.script {
            switch Self.resolvedPluginScriptSource(
                scriptName,
                pluginDirectoryURL: plugin.directoryURL
            ) {
            case .bundledFile(let scriptURL):
                var enc: String.Encoding = .utf8
                let fileSource = try? String(contentsOf: scriptURL, usedEncoding: &enc)
                source = fileSource.map { Self.renderedAppleScriptSource($0, text: text) }
                Self.verboseLog("Loaded script from file: \(scriptURL.path)")
            case .inline(let inline):
                source = Self.renderedAppleScriptSource(inline, text: text)
                Self.verboseLog("Using legacy inline AppleScript from the script field")
            case nil:
                NSLog("[OpenFire] Refusing AppleScript outside the verified plugin package: \(scriptName)")
                source = nil
            }
        } else if let inline = action.inline {
            Self.verboseLog("Found inline action config")
            source = Self.renderedAppleScriptSource(inline, text: text)
        } else {
            Self.verboseLog("Neither inline nor script field found in config!")
        }
        
        guard let appleScriptSource = source else {
            Self.verboseLog("appleScriptSource is nil, aborting")
            removeTrustedExecutionSnapshot(cleanupSnapshot)
            return
        }
        
        Self.verboseLog("Preparing to execute AppleScript of length: \(appleScriptSource.count)")
        
        // Execute via osascript passing a temporary file path
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.removeTrustedExecutionSnapshot(cleanupSnapshot) }
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".applescript")
            // Write selected text to a temp file so AppleScript can read it with proper UTF-8 encoding
            // This avoids encoding issues with CJK characters via environment variables
            let textFile = tempDir.appendingPathComponent(UUID().uuidString + ".txt")
            defer {
                try? FileManager.default.removeItem(at: tempFile)
                try? FileManager.default.removeItem(at: textFile)
            }
            
            do {
                try text.write(to: textFile, atomically: true, encoding: .utf8)
                
                // Transparently replace `system attribute "OPENFIRE_TEXT"` with file-based UTF-8 read
                // so that CJK characters are handled correctly without users needing to know about the file
                let fileReadExpr = "read (POSIX file \"\(textFile.path)\") as \u{00AB}class utf8\u{00BB}"
                let finalSource = appleScriptSource
                    .replacingOccurrences(of: "(system attribute \"OPENFIRE_TEXT\")", with: "(\(fileReadExpr))")
                    .replacingOccurrences(of: "system attribute \"OPENFIRE_TEXT\"", with: fileReadExpr)
                
                try finalSource.write(to: tempFile, atomically: true, encoding: .utf8)
                Self.verboseLog("Wrote temp AppleScript file to \(tempFile.path)")
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [tempFile.path]
                process.environment = Self.pluginProcessEnvironment(
                    text: text,
                    textFilePath: textFile.path
                )
                process.currentDirectoryURL = plugin.directoryURL

                Self.verboseLog("Launching osascript process")
                self.runProcessWithTimeout(
                    process,
                    timeout: 30,
                    logPrefix: "AppleScript"
                )
            } catch {
                NSLog("[OpenFire] Failed to execute AppleScript via osascript: \(error.localizedDescription)")
            }
        }
    }

    static func renderedAppleScriptSource(_ source: String, text: String) -> String {
        guard source.contains("{text}") else { return source }

        let literal = appleScriptStringLiteralExpression(for: text)
        let token = "{text}"
        var result = ""
        var index = source.startIndex
        var insideString = false
        var escaping = false

        while index < source.endIndex {
            if source[index...].hasPrefix(token) {
                result += insideString ? "\" & \(literal) & \"" : literal
                index = source.index(index, offsetBy: token.count)
                escaping = false
                continue
            }

            let character = source[index]
            result.append(character)

            if character == "\"" && !escaping {
                insideString.toggle()
            }
            escaping = character == "\\" && !escaping
            if character != "\\" {
                escaping = false
            }

            index = source.index(after: index)
        }

        return result
    }

    static func appleScriptStringLiteralExpression(for text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return normalized
            .components(separatedBy: "\n")
            .map { "\"\(appleScriptStringLiteralContent(for: $0))\"" }
            .joined(separator: " & linefeed & ")
    }

    static func resolvedPluginScriptSource(
        _ scriptValue: String,
        pluginDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> PluginScriptSource? {
        let trimmed = scriptValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let explicitlyExternalPrefixes = ["/", "~/", "../"]
        guard !explicitlyExternalPrefixes.contains(where: { trimmed.hasPrefix($0) }) else {
            return nil
        }

        let rootURL = pluginDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = pluginDirectoryURL
            .appendingPathComponent(trimmed)
            .standardizedFileURL
        let resolvedCandidateURL = candidateURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard resolvedCandidateURL.path.hasPrefix(rootPrefix) else { return nil }

        if fileManager.fileExists(atPath: candidateURL.path),
           let values = try? candidateURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
           ),
           values.isRegularFile == true,
           values.isSymbolicLink != true {
            return .bundledFile(candidateURL)
        }

        let isSingleToken = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        let looksLikeMissingFile = isSingleToken && (
            trimmed.contains("/") ||
            trimmed.hasSuffix(".sh") ||
            trimmed.hasSuffix(".applescript") ||
            trimmed.hasSuffix(".scpt")
        )
        return looksLikeMissingFile ? nil : .inline(scriptValue)
    }

    static func resolvedPluginScriptContent(
        _ scriptValue: String,
        pluginDirectoryURL: URL,
        maximumFileBytes: Int,
        fileManager: FileManager = .default
    ) -> String? {
        guard maximumFileBytes >= 0, maximumFileBytes < Int.max else { return nil }

        switch resolvedPluginScriptSource(
            scriptValue,
            pluginDirectoryURL: pluginDirectoryURL,
            fileManager: fileManager
        ) {
        case .inline(let source):
            return source.utf8.count <= maximumFileBytes ? source : nil
        case .bundledFile(let scriptURL):
            var pathStatus = stat()
            guard lstat(scriptURL.path, &pathStatus) == 0,
                  pathStatus.st_mode & S_IFMT == S_IFREG,
                  isPluginDirectory(
                    scriptURL.standardizedFileURL.resolvingSymlinksInPath(),
                    inside: pluginDirectoryURL
                  ) else {
                return nil
            }

            guard let handle = try? FileHandle(forReadingFrom: scriptURL) else {
                return nil
            }
            defer { try? handle.close() }

            let descriptor = handle.fileDescriptor
            var fileStatus = stat()
            guard fstat(descriptor, &fileStatus) == 0,
                  fileStatus.st_mode & S_IFMT == S_IFREG,
                  fileStatus.st_dev == pathStatus.st_dev,
                  fileStatus.st_ino == pathStatus.st_ino,
                  fileStatus.st_size >= 0,
                  fileStatus.st_size <= off_t(maximumFileBytes) else {
                return nil
            }

            let data: Data
            do {
                data = try handle.read(
                    upToCount: maximumFileBytes + 1
                ) ?? Data()
            } catch {
                return nil
            }
            guard data.count <= maximumFileBytes else { return nil }
            return String(data: data, encoding: .utf8)
        case nil:
            return nil
        }
    }

    private static func appleScriptStringLiteralContent(for text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func executeKeyCombo(
        _ action: PluginActionConfig,
        targetProcessIdentifier: pid_t
    ) {
        guard let keyString = action.key else { return }
        
        var modifierFlags: CGEventFlags = []
        if let modifiers = action.modifiers {
            for mod in modifiers {
                switch mod.lowercased() {
                case "command", "cmd": modifierFlags.insert(.maskCommand)
                case "shift": modifierFlags.insert(.maskShift)
                case "option", "alt": modifierFlags.insert(.maskAlternate)
                case "control", "ctrl": modifierFlags.insert(.maskControl)
                default: break
                }
            }
        }
        
        // Map key string to virtual key code
        guard let keyCode = keyCodeForString(keyString) else { return }
        ActionExecutor.shared.simulateKeyCombo(
            key: keyCode,
            modifiers: modifierFlags,
            targetProcessIdentifier: targetProcessIdentifier
        )
    }
    
    private func keyCodeForString(_ key: String) -> CGKeyCode? {
        let mapping: [String: CGKeyCode] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
            "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
            "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
            "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
            "z": 0x06,
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
            "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
            "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A,
            ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32,
            "return": 0x24, "tab": 0x30, "space": 0x31,
            "delete": 0x33, "esc": 0x35, "escape": 0x35, "left": 0x7B, "right": 0x7C,
            "up": 0x7E, "down": 0x7D,
        ]
        
        let lower = key.lowercased()
        if let code = mapping[lower] {
            return code
        }
        
        NSLog("[OpenFire] Warning: Could not find virtual key code mapping for string '\(key)'")
        return nil
    }
    
    // MARK: - Plugin Installation
    
    /// Install a plugin from a given URL (e.g., when user double-clicks a .openfireext file)
    func installPlugin(from sourceURL: URL) -> Bool {
        installPluginDetailed(from: sourceURL).isSuccess
    }

    /// Create an immutable description of the exact package shown in an install
    /// confirmation. Pass its fingerprint back to `installPluginDetailed` after
    /// the user accepts the prompt.
    func makeInstallPreview(
        from sourceURL: URL,
        snapshotCopy: (URL, URL) throws -> Void = {
            try FileManager.default.copyItem(at: $0, to: $1)
        }
    ) -> PluginInstallPreview? {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard Self.isInstallPackageWithinLimits(sourceURL),
              let sourcePluginBeforeCopy = PluginLoader.load(from: sourceURL),
              Self.pluginIdentifierValidationMessage(sourcePluginBeforeCopy.id) == nil,
              let sourceFingerprintBeforeCopy = sourcePluginBeforeCopy.packageFingerprint else {
            return nil
        }

        let fileManager = FileManager.default
        let snapshotContainerURL = fileManager.temporaryDirectory.appendingPathComponent(
            "openfire-install-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        let snapshotPackageURL = snapshotContainerURL.appendingPathComponent(
            "Package.openfireext",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: snapshotContainerURL)
        }

        do {
            try fileManager.createDirectory(
                at: snapshotContainerURL,
                withIntermediateDirectories: false
            )
            try snapshotCopy(sourceURL, snapshotPackageURL)
        } catch {
            NSLog("[OpenFire] Failed to prepare plugin install snapshot: \(error.localizedDescription)")
            return nil
        }

        guard Self.isInstallPackageWithinLimits(snapshotPackageURL),
              let snapshotPlugin = PluginLoader.load(from: snapshotPackageURL),
              Self.pluginIdentifierValidationMessage(snapshotPlugin.id) == nil,
              let snapshotFingerprint = snapshotPlugin.packageFingerprint,
              Self.isInstallPackageWithinLimits(sourceURL),
              let sourcePluginAfterCopy = PluginLoader.load(from: sourceURL),
              let sourceFingerprintAfterCopy = sourcePluginAfterCopy.packageFingerprint,
              sourceFingerprintBeforeCopy == snapshotFingerprint,
              sourceFingerprintAfterCopy == snapshotFingerprint else {
            NSLog("[OpenFire] Plugin changed while preparing the install confirmation: \(sourceURL.path)")
            return nil
        }

        return PluginInstallPreview(
            name: snapshotPlugin.config.name,
            description: snapshotPlugin.config.description,
            actionType: snapshotPlugin.config.action.type,
            requiresExecutionTrust: snapshotPlugin.requiresExecutionTrust,
            fingerprint: snapshotFingerprint
        )
    }

    /// Install a plugin and return the reason when validation or copying fails.
    func installPluginDetailed(
        from sourceURL: URL,
        expectedPreviewFingerprint: String? = nil
    ) -> PluginInstallResult {
        // macOS hands us a security-scoped URL when double-clicked outside our sandbox
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default

        guard Self.isInstallPackageWithinLimits(sourceURL, fileManager: fileManager) else {
            NSLog("[OpenFire] Refusing to install unsafe or oversized plugin package: \(sourceURL.path)")
            return .failed(.invalidPackage)
        }
        
        do {
            try fileManager.createDirectory(at: userPluginsURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[OpenFire] Failed to create plugin directory: \(error.localizedDescription)")
            return .failed(.fileOperationFailed(error.localizedDescription))
        }

        guard let sourcePlugin = PluginLoader.load(from: sourceURL),
              let sourceFingerprint = sourcePlugin.packageFingerprint else {
            NSLog("[OpenFire] Refusing to install invalid plugin package: \(sourceURL.path)")
            return .failed(.invalidPackage)
        }

        if let expectedPreviewFingerprint,
           expectedPreviewFingerprint != sourceFingerprint {
            NSLog("[OpenFire] Refusing plugin that changed after install confirmation: \(sourceURL.path)")
            return .failed(.sourceChangedSinceConfirmation)
        }

        if let validationMessage = Self.pluginIdentifierValidationMessage(sourcePlugin.id) {
            NSLog("[OpenFire] Refusing to install plugin with invalid identifier '\(sourcePlugin.id)': \(validationMessage)")
            return .failed(.invalidIdentifier(validationMessage))
        }

        let canonicalFileName = Self.visibleUserPluginFileName(for: sourcePlugin.id)
        let destinationURL = userPluginsURL.appendingPathComponent(canonicalFileName)
        guard Self.isPluginDirectory(destinationURL, inside: userPluginsURL) else {
            return .failed(.invalidIdentifier(
                "Identifier must use only letters, numbers, dots, and hyphens.".localized
            ))
        }

        if fileManager.fileExists(atPath: destinationURL.path),
           let existingPlugin = PluginLoader.load(from: destinationURL),
           existingPlugin.id != sourcePlugin.id {
            NSLog("[OpenFire] Refusing to install plugin '\(sourcePlugin.id)' because it would replace plugin '\(existingPlugin.id)'")
            return .failed(.destinationIdentifierConflict(existingIdentifier: existingPlugin.id))
        }

        if Self.sameFileURL(sourceURL, destinationURL) {
            removeDuplicateUserPlugins(for: sourcePlugin.id, keeping: destinationURL)
            reloadPlugins()
            return .installed
        }

        let stagingURL = Self.pendingPluginPackageURL(
            in: userPluginsURL,
            prefix: "install"
        )
        let backupURL = Self.pendingPluginPackageURL(
            in: userPluginsURL,
            prefix: "backup"
        )
        var didMoveDestinationToBackup = false
        var shouldRemoveBackup = true
        
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if shouldRemoveBackup {
                try? fileManager.removeItem(at: backupURL)
            }
        }
        
        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            guard Self.isInstallPackageWithinLimits(stagingURL, fileManager: fileManager),
                  let stagedPlugin = PluginLoader.load(from: stagingURL),
                  stagedPlugin.config == sourcePlugin.config,
                  stagedPlugin.packageFingerprint == sourceFingerprint,
                  expectedPreviewFingerprint == nil ||
                    stagedPlugin.packageFingerprint == expectedPreviewFingerprint else {
                NSLog("[OpenFire] Refusing staged plugin because validation failed after copy: \(sourceURL.path)")
                return .failed(.stagedValidationFailed)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                didMoveDestinationToBackup = true
            }

            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            } catch {
                shouldRemoveBackup = Self.restoreBackedUpPackageIfNeeded(
                    backupURL: backupURL,
                    destinationURL: destinationURL,
                    didMoveDestinationToBackup: didMoveDestinationToBackup,
                    fileManager: fileManager,
                    logPrefix: "Plugin install"
                )
                throw error
            }

            removeDuplicateUserPlugins(for: sourcePlugin.id, keeping: destinationURL)
            NSLog("[OpenFire] Plugin installed: \(sourceURL.lastPathComponent)")
            reloadPlugins()
            return .installed
        } catch {
            NSLog("[OpenFire] Failed to install plugin: \(error.localizedDescription)")
            return .failed(.fileOperationFailed(error.localizedDescription))
        }
    }

    static func isInstallPackageWithinLimits(
        _ packageURL: URL,
        fileManager: FileManager = .default,
        maxFileCount: Int = maximumInstallPackageFileCount,
        maxTotalBytes: Int = maximumInstallPackageBytes
    ) -> Bool {
        guard maxFileCount > 0, maxTotalBytes >= 0 else { return false }

        let rootKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let rootValues = try? packageURL.resourceValues(forKeys: rootKeys),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            return false
        }

        let resourceKeys: [URLResourceKey] = [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                enumerationFailed = true
                NSLog("[OpenFire] Failed to inspect plugin package at \(url.path): \(error.localizedDescription)")
                return false
            }
        ) else {
            return false
        }

        let rootPath = packageURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var entryCount = 0
        var totalBytes = 0

        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isSymbolicLink != true else {
                return false
            }

            let itemPath = itemURL.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPrefix) else { return false }
            let relativePath = String(itemPath.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty,
                  relativePath.split(separator: "/").count <= Plugin.maximumPackageTreeDepth,
                  entryCount < maxFileCount else {
                return false
            }
            entryCount += 1

            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= maxTotalBytes - totalBytes else {
                return false
            }
            totalBytes += fileSize
        }

        return !enumerationFailed && entryCount > 0
    }

    static func restoreBackedUpPackageIfNeeded(
        backupURL: URL,
        destinationURL: URL,
        didMoveDestinationToBackup: Bool,
        fileManager: FileManager = .default,
        logPrefix: String
    ) -> Bool {
        guard didMoveDestinationToBackup else { return true }

        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            NSLog("[OpenFire] \(logPrefix) failed after destination was recreated. Preserving backup at \(backupURL.path).")
            return false
        }

        do {
            try fileManager.moveItem(at: backupURL, to: destinationURL)
            return true
        } catch {
            NSLog("[OpenFire] \(logPrefix) could not restore backup at \(backupURL.path): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func appendPluginProcessStderrChunk(
        _ chunk: Data,
        to stderrData: inout Data,
        maxBytes: Int = maxPluginProcessStderrBytes
    ) -> Bool {
        guard maxBytes > 0 else { return !chunk.isEmpty }
        let remainingBytes = maxBytes - stderrData.count
        guard remainingBytes > 0 else { return !chunk.isEmpty }

        if chunk.count <= remainingBytes {
            stderrData.append(chunk)
            return false
        }

        stderrData.append(chunk.prefix(remainingBytes))
        return true
    }

    @discardableResult
    func runProcessWithTimeout(
        _ process: Process,
        timeout: TimeInterval,
        logPrefix: String
    ) -> Int32? {
        let errorPipe = Pipe()
        let stderrAccumulator = PluginProcessStderrAccumulator()
        let stderrReachedEOF = DispatchSemaphore(value: 0)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else {
                stderrReachedEOF.signal()
                return
            }
            stderrAccumulator.append(availableData)
        }

        let rootPID: pid_t
        let stderrReadFileDescriptor =
            errorPipe.fileHandleForReading.fileDescriptor
        let stderrWriteFileDescriptor =
            errorPipe.fileHandleForWriting.fileDescriptor
        do {
            rootPID = try Self.spawnPluginProcess(
                process,
                standardErrorReadFileDescriptor: stderrReadFileDescriptor,
                standardErrorFileDescriptor: stderrWriteFileDescriptor
            )
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? errorPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close()
            NSLog("[OpenFire] Failed to launch \(logPrefix): \(error.localizedDescription)")
            return nil
        }
        try? errorPipe.fileHandleForWriting.close()

        let initialWait = Self.waitForChildProcess(
            rootPID,
            timeout: max(0, timeout)
        )
        let rawWaitStatus: Int32?
        switch initialWait {
        case .exited(let status):
            rawWaitStatus = status
            Self.terminateRemainingProcessGroup(rootPID)
        case .timedOut:
            NSLog("[OpenFire] \(logPrefix) timed out after \(Int(timeout))s, terminating process.")
            Self.signalProcessGroup(rootPID, signal: SIGTERM)
            switch Self.waitForChildProcess(rootPID, timeout: 2) {
            case .exited(let status):
                rawWaitStatus = status
            case .timedOut:
                Self.signalProcessGroup(rootPID, signal: SIGKILL)
                if case .exited(let status) = Self.waitForChildProcess(rootPID, timeout: 2) {
                    rawWaitStatus = status
                } else {
                    rawWaitStatus = nil
                }
            case .unavailable:
                rawWaitStatus = nil
            }
            Self.terminateRemainingProcessGroup(rootPID)
        case .unavailable:
            rawWaitStatus = nil
            Self.signalProcessGroup(rootPID, signal: SIGKILL)
        }

        let terminationStatus = rawWaitStatus.map(Self.terminationStatus(fromWaitStatus:))
        if let terminationStatus, Self.isVerbosePluginLoggingEnabled() {
            Self.verboseLog("\(logPrefix) process finished with exit code: \(terminationStatus)")
        } else if terminationStatus == nil {
            NSLog("[OpenFire] \(logPrefix) did not exit after termination escalation.")
        }

        // A descendant can deliberately detach and keep stderr open. Never use
        // readDataToEndOfFile here: cleanup must remain bounded even when EOF
        // never arrives.
        _ = stderrReachedEOF.wait(timeout: .now() + 0.2)
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? errorPipe.fileHandleForReading.close()
        let (errorData, wasStderrTruncated) = stderrAccumulator.snapshot()
        if !errorData.isEmpty,
           var errorStr = String(data: errorData, encoding: .utf8),
           let terminationStatus,
           let message = Self.pluginProcessStderrLogMessage(
            logPrefix: logPrefix,
            stderr: {
                if wasStderrTruncated {
                    errorStr += "\n[OpenFire] stderr truncated after \(Self.maxPluginProcessStderrBytes) bytes."
                }
                return errorStr
            }(),
            terminationStatus: terminationStatus,
            verboseLoggingEnabled: Self.isVerbosePluginLoggingEnabled()
           ) {
            NSLog("[OpenFire] %@", message)
        }
        return terminationStatus
    }

    private enum ChildProcessWaitResult {
        case exited(Int32)
        case timedOut
        case unavailable
    }

    private static func spawnPluginProcess(
        _ process: Process,
        standardErrorReadFileDescriptor: Int32,
        standardErrorFileDescriptor: Int32
    ) throws -> pid_t {
        guard let executableURL = process.executableURL else {
            throw CocoaError(.executableNotLoadable)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CocoaError(.executableNotLoadable)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CocoaError(.executableNotLoadable)
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_addclose(
            &fileActions,
            standardErrorReadFileDescriptor
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            standardErrorFileDescriptor,
            STDERR_FILENO
        ) == 0,
        posix_spawn_file_actions_addclose(
            &fileActions,
            standardErrorFileDescriptor
        ) == 0 else {
            throw CocoaError(.executableNotLoadable)
        }

        let addNullOutputResult = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDOUT_FILENO,
                $0,
                O_WRONLY,
                0
            )
        }
        guard addNullOutputResult == 0 else {
            throw CocoaError(.executableNotLoadable)
        }

        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw CocoaError(.executableNotLoadable)
        }

        let targetExecutable = executableURL.path
        let targetArguments = process.arguments ?? []
        let spawnExecutable: String
        let spawnArguments: [String]
        if let currentDirectory = process.currentDirectoryURL?.path {
            spawnExecutable = "/bin/sh"
            spawnArguments = [
                "sh",
                "-c",
                "cd \"$1\" || exit 126\nshift\nexec \"$@\"",
                "openfire-plugin-runner",
                currentDirectory,
                targetExecutable
            ] + targetArguments
        } else {
            spawnExecutable = targetExecutable
            spawnArguments = [targetExecutable] + targetArguments
        }

        let environment = (process.environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var childPID: pid_t = 0
        let spawnResult = try withMutableCStringArray(spawnArguments) { arguments in
            try withMutableCStringArray(environment) { environment in
                spawnExecutable.withCString {
                    posix_spawn(
                        &childPID,
                        $0,
                        &fileActions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }
        guard spawnResult == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(spawnResult),
                userInfo: nil
            )
        }
        return childPID
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        guard strings.allSatisfy({ !$0.contains("\0") }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer {
            pointers.forEach { free($0) }
        }
        guard pointers.allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer {
            try body($0.baseAddress!)
        }
    }

    private static func waitForChildProcess(
        _ pid: pid_t,
        timeout: TimeInterval
    ) -> ChildProcessWaitResult {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var waitStatus: Int32 = 0

        while true {
            let waitResult = waitpid(pid, &waitStatus, WNOHANG)
            if waitResult == pid {
                return .exited(waitStatus)
            }
            if waitResult == -1 {
                if errno == EINTR {
                    continue
                }
                return .unavailable
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return .timedOut
            }
            usleep(10_000)
        }
    }

    private static func signalProcessGroup(_ groupID: pid_t, signal: Int32) {
        guard groupID > 1 else { return }
        _ = kill(-groupID, signal)
    }

    private static func processGroupExists(_ groupID: pid_t) -> Bool {
        guard groupID > 1 else { return false }
        if kill(-groupID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func terminateRemainingProcessGroup(_ groupID: pid_t) {
        guard processGroupExists(groupID) else { return }
        signalProcessGroup(groupID, signal: SIGTERM)

        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while processGroupExists(groupID),
              ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        if processGroupExists(groupID) {
            signalProcessGroup(groupID, signal: SIGKILL)
        }
    }

    nonisolated static func terminationStatus(fromWaitStatus waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + terminatingSignal
    }
}
