import Cocoa
import CryptoKit

/// Represents a single plugin action type and its execution parameters
enum PluginActionType: String, Codable {
    case url = "url"
    case shellScript = "shell-script"
    case applescript = "applescript"
    case keyCombo = "key-combo"
    case copy = "copy"
    case paste = "paste"
    case revealPath = "reveal-path"
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

enum PluginVisibilityReason: Equatable {
    case disabled
    case textTooShort(min: Int, actual: Int)
    case textTooLong(max: Int, actual: Int)
    case invalidRegex(String)
    case regexNoMatch(String)
    case appNotAllowed(current: String?, allowed: [String])
    case appExcluded(String)
}

struct PluginVisibilityDiagnostic {
    let plugin: Plugin
    let reasons: [PluginVisibilityReason]

    var isVisible: Bool {
        reasons.isEmpty
    }
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

    var requiresExecutionTrust: Bool {
        switch config.action.type {
        case .shellScript, .applescript:
            return true
        default:
            return false
        }
    }

    var executionTrustFingerprint: String? {
        guard requiresExecutionTrust else { return nil }

        var hasher = SHA256()

        let configURL = directoryURL.appendingPathComponent("Config.json")
        if let data = try? Data(contentsOf: configURL) {
            hasher.update(data: data)
        } else {
            hasher.update(data: Data(id.utf8))
        }

        if let scriptRef = config.action.script {
            let scriptURL = directoryURL.appendingPathComponent(scriptRef)
            if let data = try? Data(contentsOf: scriptURL) {
                hasher.update(data: data)
            } else {
                hasher.update(data: Data(scriptRef.utf8))
            }
        }

        if let inline = config.action.inline {
            hasher.update(data: Data(inline.utf8))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Check if this plugin should be shown for the given context
    func shouldShow(text: String, appBundleID: String?) -> Bool {
        visibilityDiagnostic(text: text, appBundleID: appBundleID).isVisible
    }

    func visibilityDiagnostic(text: String, appBundleID: String?) -> PluginVisibilityDiagnostic {
        var reasons: [PluginVisibilityReason] = []

        if !isEnabled {
            reasons.append(.disabled)
        }

        if let filter = config.filter {
            if let min = filter.minLength, text.count < min {
                reasons.append(.textTooShort(min: min, actual: text.count))
            }
            if let max = filter.maxLength, text.count > max {
                reasons.append(.textTooLong(max: max, actual: text.count))
            }

            if let pattern = filter.regex {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    if regex.firstMatch(in: text, options: [], range: range) == nil {
                        reasons.append(.regexNoMatch(pattern))
                    }
                } else {
                    reasons.append(.invalidRegex(pattern))
                }
            }

            if let allowedApps = filter.apps, !allowedApps.isEmpty {
                if let bundleID = appBundleID {
                    if !allowedApps.contains(bundleID) {
                        reasons.append(.appNotAllowed(current: bundleID, allowed: allowedApps))
                    }
                } else {
                    reasons.append(.appNotAllowed(current: nil, allowed: allowedApps))
                }
            }

            if let excludedApps = filter.excludeApps,
               !excludedApps.isEmpty,
               let bundleID = appBundleID,
               excludedApps.contains(bundleID) {
                reasons.append(.appExcluded(bundleID))
            }
        }

        return PluginVisibilityDiagnostic(plugin: self, reasons: reasons)
    }
}
