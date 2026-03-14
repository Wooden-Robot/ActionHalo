import Cocoa
import JavaScriptCore

/// Manages plugin lifecycle: loading, execution, filtering, and hot-reload
final class PluginManager {
    struct PerAppPluginOverride: Equatable {
        let appBundleID: String
        let pluginID: String
    }
    
    static let shared = PluginManager()
    
    /// Notification posted when plugins are reloaded
    static let pluginsReloadedNotification = Notification.Name("OpenFirePluginsReloaded")
    static let trustedPluginFingerprintsKey = "trustedPluginFingerprints"
    static let perAppDisabledPluginsKey = "perAppDisabledPlugins"
    
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
    private var fileWatchers: [DispatchSourceFileSystemObject] = []
    private var pendingReloadWorkItem: DispatchWorkItem?
    private let loadStateQueue = DispatchQueue(label: "com.openfire.plugin-load-state")
    private var latestScheduledLoadID: UInt64 = 0
    
    /// User plugins directory
    var userPluginsURL: URL {
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
        var merged: [String: Plugin] = [:]

        for plugin in user where merged[plugin.id] == nil {
            merged[plugin.id] = plugin
        }

        for plugin in builtIn where merged[plugin.id] == nil {
            merged[plugin.id] = plugin
        }

        return Array(merged.values)
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
            let user = PluginLoader.scanDirectory(self.userPluginsURL)
            
            // Merge deterministically: preserve existing user plugins and keep older duplicates.
            var mergedPlugins = Dictionary(
                uniqueKeysWithValues: Self.mergePluginsPreservingExisting(user: user, builtIn: builtIn).map { ($0.id, $0) }
            )
            
            // Filter out softly deleted bundled plugins
            let deletedBuiltIns = UserDefaults.standard.stringArray(forKey: "deletedBuiltInPlugins") ?? []
            for id in deletedBuiltIns {
                if !PluginManager.coreDefaultPluginIDs.contains(id) {
                    // Only remove it if it's currently a built-in one (meaning not overridden by user)
                    // If a user re-installed an override after deleting the built-in, we still load it.
                    if let p = mergedPlugins[id], p.directoryURL.path.hasPrefix(self.builtInPluginsURL.path) {
                        mergedPlugins.removeValue(forKey: id)
                    }
                }
            }
            
            // Convert back to array
            let newPlugins = Array(mergedPlugins.values)
            
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
    
    /// Get plugins that should be shown for the given text and app context
    func availablePlugins(for text: String, appBundleID: String?) -> [Plugin] {
        orderedPlugins().filter { plugin in
            plugin.isEnabled && isPluginEnabled(plugin.id, forAppBundleID: appBundleID)
        }
    }

    func visibilityDiagnostics(for text: String, appBundleID: String?) -> [PluginVisibilityDiagnostic] {
        orderedPlugins().map { plugin in
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
        guard plugin.requiresExecutionTrust, let fingerprint = plugin.executionTrustFingerprint else { return true }
        let trusted = UserDefaults.standard.dictionary(forKey: Self.trustedPluginFingerprintsKey) as? [String: String] ?? [:]
        return trusted[plugin.id] == fingerprint
    }

    func setExecutionTrusted(_ trusted: Bool, for plugin: Plugin) {
        guard plugin.requiresExecutionTrust else { return }

        var stored = UserDefaults.standard.dictionary(forKey: Self.trustedPluginFingerprintsKey) as? [String: String] ?? [:]
        if trusted, let fingerprint = plugin.executionTrustFingerprint {
            stored[plugin.id] = fingerprint
        } else {
            stored.removeValue(forKey: plugin.id)
        }
        UserDefaults.standard.set(stored, forKey: Self.trustedPluginFingerprintsKey)
    }

    @discardableResult
    func confirmExecutionTrustIfNeeded(for plugin: Plugin) -> Bool {
        guard plugin.requiresExecutionTrust else { return true }
        guard !isExecutionTrusted(for: plugin) else { return true }

        let prompt: () -> Bool = {
            let alert = NSAlert()
            alert.messageText = "Trust Plugin Before Running".localized
            alert.informativeText = String(
                format: "Plugin '%@' can execute scripts on your Mac.\n\nType: %@\nLocation: %@\n\nOnly allow this if you trust the plugin source. You will be asked again if the plugin changes.".localized,
                plugin.name,
                plugin.config.action.type.rawValue,
                plugin.directoryURL.path
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Trust and Run".localized)
            alert.addButton(withTitle: "Cancel".localized)

            NSApp.activate(ignoringOtherApps: true)
            let trusted = alert.runModal() == .alertFirstButtonReturn
            self.setExecutionTrusted(trusted, for: plugin)
            return trusted
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

    private func orderedPlugins() -> [Plugin] {
        let savedOrder = UserDefaults.standard.stringArray(forKey: "pluginOrder") ?? []
        if !savedOrder.isEmpty {
            return plugins.sorted { a, b in
                let indexA = savedOrder.firstIndex(of: a.id) ?? Int.max
                let indexB = savedOrder.firstIndex(of: b.id) ?? Int.max
                return indexA < indexB
            }
        }

        return plugins.sorted { $0.order < $1.order }
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
        for url in userPluginURLs(for: identifier) where url != preservedURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func deletePlugin(_ plugin: Plugin) throws {
        // Core defaults cannot be deleted
        if PluginManager.coreDefaultPluginIDs.contains(plugin.id) {
            return
        }
        
        let pathStr = plugin.directoryURL.path
        let isBuiltIn = pathStr.hasPrefix(Bundle.main.bundlePath) || pathStr.contains("/Resources/Plugins/")
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
        watchDirectory(userPluginsURL)
    }
    
    func stopWatchingPluginDirectories() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        for watcher in fileWatchers {
            watcher.cancel()
        }
        fileWatchers.removeAll()
    }
    
    private func watchDirectory(_ url: URL) {
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        
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
            self?.scheduleReloadPlugins()
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        fileWatchers.append(source)
        
        NSLog("[OpenFire] Watching plugin directory: \(url.path)")
    }
    
    // MARK: - Plugin Execution
    
    /// Execute a plugin action with the given text
    func executePlugin(_ plugin: Plugin, with text: String) {
        let action = plugin.config.action
        NSLog("[OpenFire-Debug] executePlugin plugin=%@ type=%@ textLength=%ld",
              plugin.id,
              action.type.rawValue,
              text.count)
        
        switch action.type {
        case .url:
            executeURLAction(action, text: text)
        case .shellScript:
            guard confirmExecutionTrustIfNeeded(for: plugin) else { return }
            executeShellScript(plugin, action: action, text: text)
        case .applescript:
            guard confirmExecutionTrustIfNeeded(for: plugin) else { return }
            executeAppleScript(plugin, action: action, text: text)
        case .keyCombo:
            executeKeyCombo(action)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .paste:
            ActionExecutor.shared.simulateKeyCombo(key: 0x09, modifiers: .maskCommand) // Cmd+V
        case .revealPath:
            ActionExecutor.revealPathInFinder(text)
        }
    }
    
    // MARK: - Action Execution
    
    private func executeURLAction(_ action: PluginActionConfig, text: String) {
        guard var urlTemplate = action.url else { return }
        
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        urlTemplate = urlTemplate.replacingOccurrences(of: "{text}", with: encoded)
        
        guard let url = URL(string: urlTemplate) else { return }
        NSWorkspace.shared.open(url)
    }
    
    private func executeShellScript(_ plugin: Plugin, action: PluginActionConfig, text: String) {
        NSLog("[OpenFire-Debug] Entering executeShellScript for plugin: \(plugin.id)")
        let scriptContent: String?
        
        if let scriptName = action.script {
            NSLog("[OpenFire-Debug] Found script file config for Shell Script: \(scriptName)")
            let scriptURL = plugin.directoryURL.appendingPathComponent(scriptName)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                var enc: String.Encoding = .utf8
                scriptContent = try? String(contentsOf: scriptURL, usedEncoding: &enc)
                NSLog("[OpenFire-Debug] Loaded shell script from file: \(scriptURL.path) (encoding: \(enc))")
            } else {
                // Support plugins that just stored the script directly in the 'script' string field in JSON
                NSLog("[OpenFire-Debug] Shell script file not found, using script field as inline text")
                scriptContent = scriptName
            }
        } else if let inline = action.inline {
            NSLog("[OpenFire-Debug] Found inline action config for Shell Script")
            scriptContent = inline
        } else {
            NSLog("[OpenFire-Debug] Neither inline nor script field found in config!")
            return
        }
        
        guard let content = scriptContent else {
            NSLog("[OpenFire-Debug] shell scriptContent is nil, ABORTING!")
            return
        }
        
        NSLog("[OpenFire-Debug] Shell script content resolved, preparing to run bash...")
        
        DispatchQueue.global(qos: .userInitiated).async {
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
    
    private func executeAppleScript(_ plugin: Plugin, action: PluginActionConfig, text: String) {
        NSLog("[OpenFire-Debug] Entering executeAppleScript for plugin: \(plugin.id)")
        var source: String?
        
        if let scriptName = action.script {
            NSLog("[OpenFire-Debug] Found script file config: \(scriptName)")
            let scriptURL = plugin.directoryURL.appendingPathComponent(scriptName)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                var enc: String.Encoding = .utf8
                let fileSource = try? String(contentsOf: scriptURL, usedEncoding: &enc)
                source = fileSource?.replacingOccurrences(of: "{text}", with: text)
                NSLog("[OpenFire-Debug] Loaded script from file: \(scriptURL.path)")
            } else {
                // Support inline script stored within 'script' field directly
                source = scriptName.replacingOccurrences(of: "{text}", with: text)
                NSLog("[OpenFire-Debug] File not found, using script field as literal inline text")
            }
        } else if let inline = action.inline {
            NSLog("[OpenFire-Debug] Found inline action config")
            source = inline.replacingOccurrences(of: "{text}", with: text)
        } else {
            NSLog("[OpenFire-Debug] Neither inline nor script field found in config!")
        }
        
        guard let appleScriptSource = source else {
            NSLog("[OpenFire-Debug] appleScriptSource is nil, ABORTING!")
            return
        }
        
        NSLog("[OpenFire-Debug] Preparing to execute AppleScript of length: \(appleScriptSource.count)")
        
        // Execute via osascript passing a temporary file path
        DispatchQueue.global(qos: .userInitiated).async {
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
    
    private func executeKeyCombo(_ action: PluginActionConfig) {
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
        ActionExecutor.shared.simulateKeyCombo(key: keyCode, modifiers: modifierFlags)
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
        // macOS hands us a security-scoped URL when double-clicked outside our sandbox
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        
        // Create plugins directory if needed
        try? fileManager.createDirectory(at: userPluginsURL, withIntermediateDirectories: true)

        let sourcePlugin = PluginLoader.load(from: sourceURL)
        let canonicalFileName: String
        if let plugin = sourcePlugin {
            canonicalFileName = "\(plugin.id).openfireext"
        } else {
            canonicalFileName = sourceURL.lastPathComponent
        }

        let destinationURL = userPluginsURL.appendingPathComponent(canonicalFileName)
        if let existingURL = sourcePlugin.flatMap({ userPluginURL(for: $0.id) }),
           existingURL != destinationURL,
           fileManager.fileExists(atPath: existingURL.path) {
            try? fileManager.removeItem(at: existingURL)
        }
        
        // Remove existing plugin with same name
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            if let plugin = sourcePlugin {
                removeDuplicateUserPlugins(for: plugin.id, keeping: destinationURL)
            }
            NSLog("[OpenFire] Plugin installed: \(sourceURL.lastPathComponent)")
            reloadPlugins()
            return true
        } catch {
            NSLog("[OpenFire] Failed to install plugin: \(error.localizedDescription)")
            return false
        }
    }

    private func runProcessWithTimeout(_ process: Process, timeout: TimeInterval, logPrefix: String) {
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            NSLog("[OpenFire] Failed to launch \(logPrefix): \(error.localizedDescription)")
            return
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            NSLog("[OpenFire] \(logPrefix) timed out after \(Int(timeout))s, terminating process.")
            if process.isRunning {
                process.terminate()
                let terminationResult = semaphore.wait(timeout: .now() + 2)
                if terminationResult == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = semaphore.wait(timeout: .now() + 2)
                }
            }
        }

        NSLog("[OpenFire-Debug] \(logPrefix) process finished with exit code: \(process.terminationStatus)")

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if !errorData.isEmpty,
           let errorStr = String(data: errorData, encoding: .utf8),
           !errorStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[OpenFire] \(logPrefix) stderr: \(errorStr)")
        }
    }
}
