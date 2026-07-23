import Cocoa
import JavaScriptCore

/// Manages plugin lifecycle: loading, execution, filtering, and hot-reload
final class PluginManager {
    struct PerAppPluginOverride: Equatable {
        let appBundleID: String
        let pluginID: String
    }

    struct TrustedExecutionSnapshot {
        let plugin: Plugin
        let containerURL: URL
        let fingerprint: String
    }

    enum PluginScriptSource: Equatable {
        case bundledFile(URL)
        case inline(String)
    }

    enum ExecutionPolicy: Equatable {
        case standard
        case directKeyCombo
        case protected
    }

    enum PluginInstallFailure: Equatable {
        case invalidPackage
        case invalidIdentifier(String)
        case destinationIdentifierConflict(existingIdentifier: String)
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

    enum PluginInstallResult: Equatable {
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
    static let maximumInstallPackageFileCount = 2_048
    static let maximumInstallPackageBytes = 128 * 1024 * 1024
    
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
    
    var plugins: [Plugin] = []
    private var directoryWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingReloadWorkItem: DispatchWorkItem?
    private let loadStateQueue = DispatchQueue(label: "com.openfire.plugin-load-state")
    private let trustStateQueue = DispatchQueue(label: "com.openfire.plugin-trust-state")
    private var latestScheduledLoadID: UInt64 = 0
    var userPluginsDirectoryOverride: URL?
    
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
        let parentPath = parentURL.standardizedFileURL.path
        let pluginPath = pluginURL.standardizedFileURL.path
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { url in
                guard url.pathExtension == "openfireext" else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
    
    // MARK: - Loading

    func beginPluginLoad() -> UInt64 {
        loadStateQueue.sync {
            latestScheduledLoadID += 1
            return latestScheduledLoadID
        }
    }

    func shouldApplyPluginLoadResult(_ loadID: UInt64) -> Bool {
        loadStateQueue.sync {
            loadID == latestScheduledLoadID
        }
    }
    
    func loadAllPlugins() {
        let loadID = beginPluginLoad()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Load built-in plugins
            let builtIn = PluginLoader.scanDirectory(self.builtInPluginsURL)
            
            // Load user plugins
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
                
                NSLog("[OpenFire] Loaded \(self.plugins.count) plugins total (\(builtIn.count) built-in, \(user.count) user)")
                
                NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: self)
            }
        }
    }
    
    /// Reload plugins (e.g., after directory change)
    func reloadPlugins() {
        loadAllPlugins()
    }

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

        let prompt: () -> Bool = {
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
            return prompt()
        }

        var result = false
        DispatchQueue.main.sync {
            result = prompt()
        }
        return result
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
        let directMatch = userPluginsURL.appendingPathComponent("\(identifier).openfireext")
        if FileManager.default.fileExists(atPath: directMatch.path) {
            return directMatch
        }

        return userPluginURLs(for: identifier).first
    }

    func userPluginURLs(for identifier: String) -> [URL] {
        let fileManager = FileManager.default

        let contents = (try? fileManager.contentsOfDirectory(
            at: userPluginsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var matches: [URL] = []
        for itemURL in contents where itemURL.pathExtension == "openfireext" {
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
        let userOverrideURL = userPluginURL(for: plugin.id)
        
        if let userOverrideURL {
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
            // It's a completely loose user plugin
            try FileManager.default.removeItem(at: plugin.directoryURL)
        }
        
        reloadPlugins()
    }
    
    // MARK: - Hot Reload (File System Watching)
    
    func startWatchingPluginDirectories() {
        for directoryURL in Self.watchablePluginDirectories(userPluginsURL: userPluginsURL) {
            watchDirectory(
                directoryURL,
                refreshPackageWatchersOnEvent: Self.watchPath(for: directoryURL) == Self.watchPath(for: userPluginsURL)
            )
        }
    }
    
    func stopWatchingPluginDirectories() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        for watcher in directoryWatchers.values {
            watcher.cancel()
        }
        directoryWatchers.removeAll()
    }
    
    private static func watchPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func refreshUserPluginPackageWatchers() {
        let userPluginsPath = Self.watchPath(for: userPluginsURL)
        let packageURLs = Self.pluginPackageDirectories(in: userPluginsURL)
        let packagePaths = Set(packageURLs.map { Self.watchPath(for: $0) })

        let stalePackagePaths = directoryWatchers.keys.filter { path in
            path != userPluginsPath && !packagePaths.contains(path)
        }
        for path in stalePackagePaths {
            directoryWatchers[path]?.cancel()
            directoryWatchers.removeValue(forKey: path)
        }

        for packageURL in packageURLs {
            watchDirectory(packageURL, refreshPackageWatchersOnEvent: false)
        }
    }

    private func watchDirectory(_ url: URL, refreshPackageWatchersOnEvent: Bool) {
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let watchPath = Self.watchPath(for: url)
        guard directoryWatchers[watchPath] == nil else { return }
        
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
        
        source.setEventHandler { [weak self] in
            NSLog("[OpenFire] Plugin directory changed, reloading...")
            if refreshPackageWatchersOnEvent {
                self?.refreshUserPluginPackageWatchers()
            }
            self?.scheduleReloadPlugins()
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        directoryWatchers[watchPath] = source
        
        NSLog("[OpenFire] Watching plugin directory: \(url.path)")
    }
    
    // MARK: - Plugin Execution
    
    /// Execute a plugin action with the given text
    func executePlugin(
        _ plugin: Plugin,
        with text: String,
        targetProcessIdentifier: pid_t? = nil
    ) {
        let action = plugin.config.action
        let resolvedTargetProcessIdentifier =
            targetProcessIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSLog("[OpenFire-Debug] executePlugin plugin=%@ type=%@ textLength=%ld",
              plugin.id,
              action.type.rawValue,
              text.count)

        switch Self.executionPolicy(for: plugin) {
        case .protected:
            executeProtectedPlugin(
                plugin,
                with: text,
                targetProcessIdentifier: resolvedTargetProcessIdentifier
            )
        case .directKeyCombo:
            guard let resolvedTargetProcessIdentifier else {
                NSLog("[OpenFire] Refusing key combo '%@': target application is unavailable.", plugin.id)
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
        targetProcessIdentifier: pid_t?
    ) {
        let displayDirectoryURL = plugin.directoryURL
        let pluginID = plugin.id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let snapshot = self.makeProtectedExecutionSnapshot(for: plugin) else {
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
                    cleanupSnapshot: snapshot
                )
            default:
                self.removeTrustedExecutionSnapshot(snapshot)
            }
        }
    }

    private func executeTrustedKeyCombo(
        _ action: PluginActionConfig,
        targetProcessIdentifier: pid_t?,
        cleanupSnapshot: TrustedExecutionSnapshot
    ) {
        DispatchQueue.main.async {
            guard let targetProcessIdentifier,
                  let targetApplication = NSRunningApplication(
                    processIdentifier: targetProcessIdentifier
                  ) else {
                self.removeTrustedExecutionSnapshot(cleanupSnapshot)
                return
            }

            let executeIfStillTargeted = {
                defer { self.removeTrustedExecutionSnapshot(cleanupSnapshot) }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                        targetProcessIdentifier else {
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
        
        urlTemplate = Self.renderedURLString(template: urlTemplate, text: text)
        
        guard let url = URL(string: urlTemplate) else { return }
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
        NSLog("[OpenFire-Debug] Entering executeShellScript for plugin: \(plugin.id)")
        let scriptContent: String?
        
        if let scriptName = action.script {
            switch Self.resolvedPluginScriptSource(
                scriptName,
                pluginDirectoryURL: plugin.directoryURL
            ) {
            case .bundledFile(let scriptURL):
                var enc: String.Encoding = .utf8
                scriptContent = try? String(contentsOf: scriptURL, usedEncoding: &enc)
                NSLog("[OpenFire-Debug] Loaded shell script from file: \(scriptURL.path) (encoding: \(enc))")
            case .inline(let inline):
                scriptContent = inline
                NSLog("[OpenFire-Debug] Using legacy inline shell script from the script field")
            case nil:
                NSLog("[OpenFire] Refusing shell script outside the verified plugin package: \(scriptName)")
                scriptContent = nil
            }
        } else if let inline = action.inline {
            NSLog("[OpenFire-Debug] Found inline action config for Shell Script")
            scriptContent = inline
        } else {
            NSLog("[OpenFire-Debug] Neither inline nor script field found in config!")
            removeTrustedExecutionSnapshot(cleanupSnapshot)
            return
        }
        
        guard let content = scriptContent else {
            NSLog("[OpenFire-Debug] shell scriptContent is nil, ABORTING!")
            removeTrustedExecutionSnapshot(cleanupSnapshot)
            return
        }
        
        NSLog("[OpenFire-Debug] Shell script content resolved, preparing to run bash...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.removeTrustedExecutionSnapshot(cleanupSnapshot) }
            // Write selected text to a temp file for reliable Unicode/CJK support
            let textFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            try? text.write(to: textFile, atomically: true, encoding: .utf8)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", content]
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["OPENFIRE_TEXT"] = text
            process.environment?["OPENFIRE_TEXT_FILE"] = textFile.path
            process.currentDirectoryURL = plugin.directoryURL
            
            NSLog("[OpenFire-Debug] Launching bash process...")
            self.runProcessWithTimeout(
                process,
                timeout: 30,
                logPrefix: "Shell script"
            )
            
            try? FileManager.default.removeItem(at: textFile)
        }
    }
    
    private func executeAppleScript(
        _ plugin: Plugin,
        action: PluginActionConfig,
        text: String,
        cleanupSnapshot: TrustedExecutionSnapshot
    ) {
        NSLog("[OpenFire-Debug] Entering executeAppleScript for plugin: \(plugin.id)")
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
                NSLog("[OpenFire-Debug] Loaded script from file: \(scriptURL.path)")
            case .inline(let inline):
                source = Self.renderedAppleScriptSource(inline, text: text)
                NSLog("[OpenFire-Debug] Using legacy inline AppleScript from the script field")
            case nil:
                NSLog("[OpenFire] Refusing AppleScript outside the verified plugin package: \(scriptName)")
                source = nil
            }
        } else if let inline = action.inline {
            NSLog("[OpenFire-Debug] Found inline action config")
            source = Self.renderedAppleScriptSource(inline, text: text)
        } else {
            NSLog("[OpenFire-Debug] Neither inline nor script field found in config!")
        }
        
        guard let appleScriptSource = source else {
            NSLog("[OpenFire-Debug] appleScriptSource is nil, ABORTING!")
            removeTrustedExecutionSnapshot(cleanupSnapshot)
            return
        }
        
        NSLog("[OpenFire-Debug] Preparing to execute AppleScript of length: \(appleScriptSource.count)")
        
        // Execute via osascript passing a temporary file path
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.removeTrustedExecutionSnapshot(cleanupSnapshot) }
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".applescript")
            // Write selected text to a temp file so AppleScript can read it with proper UTF-8 encoding
            // This avoids encoding issues with CJK characters via environment variables
            let textFile = tempDir.appendingPathComponent(UUID().uuidString + ".txt")
            
            do {
                try text.write(to: textFile, atomically: true, encoding: .utf8)
                
                // Transparently replace `system attribute "OPENFIRE_TEXT"` with file-based UTF-8 read
                // so that CJK characters are handled correctly without users needing to know about the file
                let fileReadExpr = "read (POSIX file \"\(textFile.path)\") as \u{00AB}class utf8\u{00BB}"
                let finalSource = appleScriptSource
                    .replacingOccurrences(of: "(system attribute \"OPENFIRE_TEXT\")", with: "(\(fileReadExpr))")
                    .replacingOccurrences(of: "system attribute \"OPENFIRE_TEXT\"", with: fileReadExpr)
                
                try finalSource.write(to: tempFile, atomically: true, encoding: .utf8)
                NSLog("[OpenFire-Debug] Wrote temp AppleScript file to \(tempFile.path)")
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [tempFile.path]
                process.environment = ProcessInfo.processInfo.environment
                process.environment?["OPENFIRE_TEXT"] = text
                process.environment?["OPENFIRE_TEXT_FILE"] = textFile.path
                process.currentDirectoryURL = plugin.directoryURL

                NSLog("[OpenFire-Debug] Launching osascript process...")
                self.runProcessWithTimeout(
                    process,
                    timeout: 30,
                    logPrefix: "AppleScript"
                )
                
                try? FileManager.default.removeItem(at: tempFile)
                try? FileManager.default.removeItem(at: textFile)
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

    /// Install a plugin and return the reason when validation or copying fails.
    func installPluginDetailed(from sourceURL: URL) -> PluginInstallResult {
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

        guard let sourcePlugin = PluginLoader.load(from: sourceURL) else {
            NSLog("[OpenFire] Refusing to install invalid plugin package: \(sourceURL.path)")
            return .failed(.invalidPackage)
        }

        if let validationMessage = Self.pluginIdentifierValidationMessage(sourcePlugin.id) {
            NSLog("[OpenFire] Refusing to install plugin with invalid identifier '\(sourcePlugin.id)': \(validationMessage)")
            return .failed(.invalidIdentifier(validationMessage))
        }

        let canonicalFileName = Self.visibleUserPluginFileName(for: sourcePlugin.id)
        let destinationURL = userPluginsURL.appendingPathComponent(canonicalFileName)

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

        let stagingURL = userPluginsURL.appendingPathComponent(".install-\(UUID().uuidString).openfireext.pending")
        let backupURL = userPluginsURL.appendingPathComponent(".backup-\(UUID().uuidString).openfireext.pending")
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
                  stagedPlugin.config == sourcePlugin.config else {
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

        var fileCount = 0
        var totalBytes = 0

        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isSymbolicLink != true else {
                return false
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileCount < maxFileCount,
                  fileSize <= maxTotalBytes - totalBytes else {
                return false
            }
            fileCount += 1
            totalBytes += fileSize
        }

        return !enumerationFailed && fileCount > 0
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

    static func processList(from psOutput: String) -> [(pid: pid_t, parentPID: pid_t)] {
        psOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2,
                      let pid = pid_t(parts[0]),
                      let parentPID = pid_t(parts[1]) else {
                    return nil
                }
                return (pid: pid, parentPID: parentPID)
            }
    }

    static func processTreeTerminationOrder(
        rootPID: pid_t,
        processList: [(pid: pid_t, parentPID: pid_t)]
    ) -> [pid_t] {
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for process in processList {
            childrenByParent[process.parentPID, default: []].append(process.pid)
        }

        for parent in childrenByParent.keys {
            childrenByParent[parent]?.sort()
        }

        var order: [pid_t] = []
        func appendSubtree(_ pid: pid_t) {
            for childPID in childrenByParent[pid] ?? [] {
                appendSubtree(childPID)
            }
            order.append(pid)
        }
        appendSubtree(rootPID)
        return order
    }

    private func runProcessWithTimeout(_ process: Process, timeout: TimeInterval, logPrefix: String) {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        if process.standardOutput == nil, let nullDevice = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullDevice
        }
        let stderrQueue = DispatchQueue(label: "com.openfire.plugin-stderr")
        var stderrData = Data()
        var stderrTruncated = false
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else { return }
            stderrQueue.sync {
                let didTruncate = Self.appendPluginProcessStderrChunk(availableData, to: &stderrData)
                stderrTruncated = stderrTruncated || didTruncate
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            NSLog("[OpenFire] Failed to launch \(logPrefix): \(error.localizedDescription)")
            return
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            NSLog("[OpenFire] \(logPrefix) timed out after \(Int(timeout))s, terminating process.")
            if process.isRunning {
                Self.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
                let terminationResult = semaphore.wait(timeout: .now() + 2)
                if terminationResult == .timedOut, process.isRunning {
                    // Re-scan before escalation. Never signal PIDs retained from an older snapshot,
                    // because an exited child's PID may already belong to an unrelated process.
                    Self.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGKILL)
                    _ = semaphore.wait(timeout: .now() + 2)
                }
            }
        }

        guard !process.isRunning else {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? errorPipe.fileHandleForReading.close()
            NSLog("[OpenFire] \(logPrefix) did not exit after termination escalation.")
            return
        }

        if Self.isVerbosePluginLoggingEnabled() {
            NSLog("[OpenFire-Debug] \(logPrefix) process finished with exit code: \(process.terminationStatus)")
        }

        errorPipe.fileHandleForReading.readabilityHandler = nil
        let remainingErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        stderrQueue.sync {
            let didTruncate = Self.appendPluginProcessStderrChunk(remainingErrorData, to: &stderrData)
            stderrTruncated = stderrTruncated || didTruncate
        }
        let (errorData, wasStderrTruncated) = stderrQueue.sync {
            (stderrData, stderrTruncated)
        }
        if !errorData.isEmpty,
           var errorStr = String(data: errorData, encoding: .utf8),
           let message = Self.pluginProcessStderrLogMessage(
            logPrefix: logPrefix,
            stderr: {
                if wasStderrTruncated {
                    errorStr += "\n[OpenFire] stderr truncated after \(Self.maxPluginProcessStderrBytes) bytes."
                }
                return errorStr
            }(),
            terminationStatus: process.terminationStatus,
            verboseLoggingEnabled: Self.isVerbosePluginLoggingEnabled()
           ) {
            NSLog("[OpenFire] %@", message)
        }
    }

    private static func currentProcessList() -> [(pid: pid_t, parentPID: pid_t)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[OpenFire] Failed to inspect child processes: \(error.localizedDescription)")
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return processList(from: output)
    }

    @discardableResult
    private static func terminateProcessTree(rootPID: pid_t, signal: Int32) -> [pid_t] {
        let order = processTreeTerminationOrder(rootPID: rootPID, processList: currentProcessList())
        terminateProcessIDs(order, signal: signal)
        return order
    }

    private static func terminateProcessIDs(_ pids: [pid_t], signal: Int32) {
        for pid in pids {
            kill(pid, signal)
        }
    }
}
