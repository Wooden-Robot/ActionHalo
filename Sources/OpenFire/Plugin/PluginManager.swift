import Cocoa
import JavaScriptCore

/// Manages plugin lifecycle: loading, execution, filtering, and hot-reload
final class PluginManager {
    
    static let shared = PluginManager()
    
    /// Notification posted when plugins are reloaded
    static let pluginsReloadedNotification = Notification.Name("OpenFirePluginsReloaded")
    
    /// The 7 core default plugins that can never be deleted
    static let coreDefaultPluginIDs: Set<String> = [
        "com.openfire.copy",
        "com.openfire.builtin.paste",
        "com.openfire.cut",
        "com.openfire.translate",
        "com.openfire.search", 
        "com.openfire.dictionary",
        "com.openfire.open-url"
    ]
    
    var plugins: [Plugin] = []
    private var fileWatchers: [DispatchSourceFileSystemObject] = []
    
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
    
    // MARK: - Loading
    
    func loadAllPlugins() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Load built-in plugins
            let builtIn = PluginLoader.scanDirectory(self.builtInPluginsURL)
            
            // Load user plugins
            let user = PluginLoader.scanDirectory(self.userPluginsURL)
            
            // Merge: User plugins override built-in plugins with the same ID
            var mergedPlugins: [String: Plugin] = [:]
            
            for p in builtIn {
                mergedPlugins[p.id] = p
            }
            for p in user {
                mergedPlugins[p.id] = p
            }
            
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
    
    // MARK: - Filtering
    
    /// Get plugins that should be shown for the given text and app context
    func availablePlugins(for text: String, appBundleID: String?) -> [Plugin] {
        let filtered = plugins.filter { plugin in
            plugin.isEnabled
        }
        
        // Use UserDefaults custom order if available
        let savedOrder = UserDefaults.standard.stringArray(forKey: "pluginOrder") ?? []
        if !savedOrder.isEmpty {
            let sorted = filtered.sorted { a, b in
                let indexA = savedOrder.firstIndex(of: a.id) ?? Int.max
                let indexB = savedOrder.firstIndex(of: b.id) ?? Int.max
                return indexA < indexB
            }
            let maxItems = UserDefaults.standard.integer(forKey: "maxRadialMenuItems")
            let limit = maxItems == 0 ? 12 : maxItems
            return Array(sorted.prefix(limit))
        }
        
        // Fallback to config order
        let finalPlugins = filtered.sorted { $0.order < $1.order }
        
        let maxItems = UserDefaults.standard.integer(forKey: "maxRadialMenuItems")
        let limit = maxItems == 0 ? 12 : maxItems
        return Array(finalPlugins.prefix(limit))
    }
    
    // MARK: - Plugin State
    
    func setPluginEnabled(_ identifier: String, enabled: Bool) {
        if let plugin = plugins.first(where: { $0.id == identifier }) {
            plugin.isEnabled = enabled
            savePluginStates()
            NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: self)
        }
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
    
    func deletePlugin(_ plugin: Plugin) throws {
        // Core defaults cannot be deleted
        if PluginManager.coreDefaultPluginIDs.contains(plugin.id) {
            return
        }
        
        let pathStr = plugin.directoryURL.path
        let isBuiltIn = pathStr.hasPrefix(Bundle.main.bundlePath) || pathStr.contains("/Resources/Plugins/")
        let userOverrideURL = userPluginsURL.appendingPathComponent("\(plugin.id).openfireext")
        let hasUserOverride = FileManager.default.fileExists(atPath: userOverrideURL.path)
        
        if hasUserOverride {
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
            self?.reloadPlugins()
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
        
        switch action.type {
        case .url:
            executeURLAction(action, text: text)
        case .shellScript:
            executeShellScript(plugin, action: action, text: text)
        case .applescript:
            executeAppleScript(plugin, action: action, text: text)
        case .keyCombo:
            executeKeyCombo(action)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .paste:
            ActionExecutor.shared.simulateKeyCombo(key: 0x09, modifiers: .maskCommand) // Cmd+V
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
        guard let scriptName = action.script else { return }
        let scriptURL = plugin.directoryURL.appendingPathComponent(scriptName)
        
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            NSLog("[OpenFire] Script not found: \(scriptURL.path)")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["OPENFIRE_TEXT"] = text
            process.currentDirectoryURL = plugin.directoryURL
            
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("[OpenFire] Failed to execute script: \(error.localizedDescription)")
            }
        }
    }
    
    private func executeAppleScript(_ plugin: Plugin, action: PluginActionConfig, text: String) {
        var source: String?
        
        if let inline = action.inline {
            source = inline.replacingOccurrences(of: "{text}", with: text)
        } else if let scriptName = action.script {
            let scriptURL = plugin.directoryURL.appendingPathComponent(scriptName)
            source = try? String(contentsOf: scriptURL, encoding: .utf8)
            source = source?.replacingOccurrences(of: "{text}", with: text)
        }
        
        guard let appleScriptSource = source else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: appleScriptSource)
            script?.executeAndReturnError(&error)
            if let error = error {
                NSLog("[OpenFire] AppleScript error: \(error)")
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
        let keyCode = keyCodeForString(keyString)
        ActionExecutor.shared.simulateKeyCombo(key: keyCode, modifiers: modifierFlags)
    }
    
    private func keyCodeForString(_ key: String) -> CGKeyCode {
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
        return 0x00 // Default fallback to 'A'
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
        
        let destinationURL = userPluginsURL.appendingPathComponent(sourceURL.lastPathComponent)
        let fileManager = FileManager.default
        
        // Create plugins directory if needed
        try? fileManager.createDirectory(at: userPluginsURL, withIntermediateDirectories: true)
        
        // Remove existing plugin with same name
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            NSLog("[OpenFire] Plugin installed: \(sourceURL.lastPathComponent)")
            reloadPlugins()
            return true
        } catch {
            NSLog("[OpenFire] Failed to install plugin: \(error.localizedDescription)")
            return false
        }
    }
}
