import Cocoa

/// Represents a single plugin action type and its execution parameters
enum PluginActionType: String, Codable {
    case url = "url"
    case shellScript = "shell-script"
    case applescript = "applescript"
    case keyCombo = "key-combo"
    case copy = "copy"
    case paste = "paste"
}

struct PluginActionConfig: Codable {
    let type: PluginActionType
    var url: String?
    var script: String?
    var inline: String?
    var key: String?
    var modifiers: [String]?
}

/// Plugin filter configuration
struct PluginFilter: Codable {
    var minLength: Int?
    var maxLength: Int?
    var regex: String?
    var apps: [String]?
    var excludeApps: [String]?
}

/// Plugin configuration decoded from Config.json
struct PluginConfig: Codable {
    let name: String
    var localizedNames: [String: String]?
    let identifier: String
    let action: PluginActionConfig
    var icon: String?
    var description: String?
    var localizedDescriptions: [String: String]?
    var filter: PluginFilter?
    var order: Int?
    var isDefaultDisabled: Bool?
}

/// Represents a loaded plugin with its configuration and resources
final class Plugin: Identifiable {
    let id: String
    let config: PluginConfig
    let directoryURL: URL
    var isEnabled: Bool = true
    
    init(config: PluginConfig, directoryURL: URL) {
        self.id = config.identifier
        self.config = config
        self.directoryURL = directoryURL
    }
    
    /// The display name of the plugin (localized if translation exists)
    var name: String {
        let preferredLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        let targetLang: String
        
        if preferredLanguage != "auto" {
            targetLang = preferredLanguage
        } else {
            let sysLang = Locale.preferredLanguages.first ?? "en"
            targetLang = sysLang.hasPrefix("zh") ? "zh-Hans" : "en"
        }
        
        if let locNames = config.localizedNames, let locName = locNames[targetLang] {
            return locName
        }
        
        return config.name.localized
    }
    
    /// The localized description of the plugin
    var localizedDescription: String? {
        let preferredLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        let targetLang: String
        
        if preferredLanguage != "auto" {
            targetLang = preferredLanguage
        } else {
            let sysLang = Locale.preferredLanguages.first ?? "en"
            targetLang = sysLang.hasPrefix("zh") ? "zh-Hans" : "en"
        }
        
        if let locDescs = config.localizedDescriptions, let locDesc = locDescs[targetLang] {
            return locDesc
        }
        
        return config.description?.localized
    }
    
    // MARK: - Lazy Icon Caching
    private var _cachedCustomIcon: NSImage?
    private var _didLoadCustomIcon = false
    
    /// Lazily load and cache the custom icon from disk to prevent main-thread IO
    var customIcon: NSImage? {
        if _didLoadCustomIcon {
            return _cachedCustomIcon
        }
        let iconPath = directoryURL.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: iconPath.path) {
            _cachedCustomIcon = NSImage(contentsOf: iconPath)
        }
        _didLoadCustomIcon = true
        return _cachedCustomIcon
    }
    
    /// The SF Symbol icon name
    var iconName: String { config.icon ?? "puzzlepiece" }
    
    /// Sort order (lower = earlier, default 100)
    var order: Int { config.order ?? 100 }
    
    /// Check if this plugin should be shown for the given context
    func shouldShow(text: String, appBundleID: String?) -> Bool {
        guard let filter = config.filter else { return true }
        
        // Check text length
        if let min = filter.minLength, text.count < min { return false }
        if let max = filter.maxLength, text.count > max { return false }
        
        // Check regex
        if let pattern = filter.regex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, options: [], range: range) == nil { return false }
        }
        
        // Check app filters
        if let allowedApps = filter.apps, !allowedApps.isEmpty {
            guard let bundleID = appBundleID, allowedApps.contains(bundleID) else { return false }
        }
        if let excludedApps = filter.excludeApps, !excludedApps.isEmpty {
            if let bundleID = appBundleID, excludedApps.contains(bundleID) { return false }
        }
        
        return true
    }
}
