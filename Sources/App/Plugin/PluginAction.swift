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

struct PluginActionConfig: Codable, Equatable {
    let type: PluginActionType
    var url: String?
    var script: String?
    var inline: String?
    var key: String?
    var modifiers: [String]?
}

/// Plugin filter configuration
struct PluginFilter: Codable, Equatable {
    var minLength: Int?
    var maxLength: Int?
    var regex: String?
    var apps: [String]?
    var excludeApps: [String]?
}

/// Plugin configuration decoded from Config.json
struct PluginConfig: Codable, Equatable {
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
    case disabledForApp(String)
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
    static let maximumTrustedPackageFileCount = 1_024
    static let maximumTrustedPackageBytes = 32 * 1024 * 1024

    private struct TrustedPackageFile {
        let url: URL
        let relativePath: String
        let size: Int
    }

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
        case .keyCombo:
            return !PluginManager.coreDefaultPluginIDs.contains(id) &&
                !PluginManager.isBuiltInPluginDirectory(directoryURL)
        default:
            return false
        }
    }

    var executionTrustFingerprint: String? {
        guard requiresExecutionTrust else { return nil }
        guard let files = trustedPackageFiles() else { return nil }

        var hasher = SHA256()
        Self.updateFingerprint(&hasher, with: Data("openfire-plugin-trust-v2".utf8))

        for file in files {
            Self.updateFingerprint(&hasher, with: Data(file.relativePath.utf8))
            Self.updateFingerprint(&hasher, with: Self.fingerprintLengthData(file.size))

            guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
            var bytesRead = 0
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    bytesRead += chunk.count
                    hasher.update(data: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                return nil
            }

            guard bytesRead == file.size else { return nil }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var canCreateProtectedExecutionSnapshot: Bool {
        requiresExecutionTrust && trustedPackageFiles() != nil
    }

    private func trustedPackageFiles() -> [TrustedPackageFile]? {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { url, error in
                enumerationFailed = true
                NSLog("[OpenFire] Failed to enumerate trusted plugin file at \(url.path): \(error.localizedDescription)")
                return false
            }
        ) else {
            return nil
        }

        let rootPath = directoryURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var files: [TrustedPackageFile] = []
        var totalBytes = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else {
                return nil
            }
            // A symlink can redirect execution to mutable content outside the trusted package.
            guard values.isSymbolicLink != true else { return nil }
            guard values.isRegularFile == true else { continue }

            let standardizedPath = fileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPrefix) else { return nil }
            let relativePath = String(standardizedPath.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty, let size = values.fileSize else { return nil }
            guard size >= 0,
                  files.count < Self.maximumTrustedPackageFileCount,
                  size <= Self.maximumTrustedPackageBytes - totalBytes else {
                return nil
            }
            totalBytes += size
            files.append(TrustedPackageFile(url: fileURL, relativePath: relativePath, size: size))
        }

        guard !enumerationFailed, !files.isEmpty else { return nil }
        return files.sorted(by: { $0.relativePath < $1.relativePath })
    }

    private static func updateFingerprint(_ hasher: inout SHA256, with data: Data) {
        hasher.update(data: fingerprintLengthData(data.count))
        hasher.update(data: data)
    }

    private static func fingerprintLengthData(_ length: Int) -> Data {
        var value = UInt64(length).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
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
                    if !AppExclusionStore.contains(bundleID, in: allowedApps) {
                        reasons.append(.appNotAllowed(current: bundleID, allowed: allowedApps))
                    }
                } else {
                    reasons.append(.appNotAllowed(current: nil, allowed: allowedApps))
                }
            }

            if let excludedApps = filter.excludeApps,
               !excludedApps.isEmpty,
               let bundleID = appBundleID,
               AppExclusionStore.contains(bundleID, in: excludedApps) {
                reasons.append(.appExcluded(bundleID))
            }
        }

        return PluginVisibilityDiagnostic(plugin: self, reasons: reasons)
    }
}
