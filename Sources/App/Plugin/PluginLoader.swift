import Foundation

/// Loads and parses ActionHalo plugin packages.
final class PluginLoader {
    static let packageExtension = "actionhaloext"
    static let legacyPackageExtension = "openfireext"
    static let supportedPackageExtensions: Set<String> = [
        packageExtension,
        legacyPackageExtension,
    ]
    static let maximumConfigBytes = 1 * 1024 * 1024

    static func isSupportedPackageExtension(_ pathExtension: String) -> Bool {
        supportedPackageExtensions.contains(pathExtension.lowercased())
    }

    static func isSupportedPackageURL(_ url: URL) -> Bool {
        isSupportedPackageExtension(url.pathExtension)
    }
    
    /// Load a plugin from a .actionhaloext directory
    static func load(
        from directoryURL: URL,
        allowReservedCoreIdentifier: Bool = false
    ) -> Plugin? {
        let rootKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let rootValues = try? directoryURL.resourceValues(forKeys: rootKeys),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              PluginManager.isInstallPackageWithinLimits(directoryURL) else {
            NSLog("[ActionHalo] Plugin package root is unsafe or exceeds limits: \(directoryURL.path)")
            return nil
        }

        let configURL = directoryURL.appendingPathComponent("Config.json")

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let values = try? configURL.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= maximumConfigBytes else {
            NSLog("[ActionHalo] Plugin config is missing, unsafe, or too large: \(configURL.path)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: configURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            let decodedConfig = try decoder.decode(PluginConfig.self, from: data)
            let config = PluginConfig(
                name: decodedConfig.name,
                localizedNames: decodedConfig.localizedNames,
                identifier: PluginManager.canonicalPluginIdentifier(decodedConfig.identifier),
                action: decodedConfig.action,
                icon: decodedConfig.icon,
                description: decodedConfig.description,
                localizedDescriptions: decodedConfig.localizedDescriptions,
                filter: decodedConfig.filter,
                order: decodedConfig.order,
                isDefaultDisabled: decodedConfig.isDefaultDisabled
            )
            
            // Validate required fields
            guard !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  PluginManager.pluginIdentifierValidationMessage(
                    config.identifier,
                    allowReservedCoreIdentifier: allowReservedCoreIdentifier
                  ) == nil else {
                NSLog("[ActionHalo] Plugin config missing required fields: \(directoryURL.lastPathComponent)")
                return nil
            }

            if config.action.type == .url {
                guard let template = config.action.url,
                      PluginManager.isAllowedPluginURLTemplate(template) else {
                    NSLog("[ActionHalo] Plugin uses an unsupported or invalid URL: \(directoryURL.lastPathComponent)")
                    return nil
                }
            }
            
            let plugin = Plugin(config: config, directoryURL: directoryURL)
            NSLog("[ActionHalo] Loaded plugin: \(config.name) (\(config.identifier))")
            return plugin
            
        } catch {
            NSLog("[ActionHalo] Failed to load plugin at \(directoryURL.path): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Scan a directory for current and legacy ActionHalo packages.
    static func scanDirectory(
        _ directoryURL: URL,
        allowReservedCoreIdentifiers: Bool = false
    ) -> [Plugin] {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            // Create directory if it doesn't exist
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return []
        }
        
        var plugins: [Plugin] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            let sortedContents = contents.sorted { lhs, rhs in
                let lhsValues = try? lhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let rhsValues = try? rhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])

                let lhsDate = lhsValues?.creationDate ?? lhsValues?.contentModificationDate ?? .distantFuture
                let rhsDate = rhsValues?.creationDate ?? rhsValues?.contentModificationDate ?? .distantFuture

                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }

                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            
            for itemURL in sortedContents {
                if isSupportedPackageURL(itemURL) {
                    if let plugin = load(
                        from: itemURL,
                        allowReservedCoreIdentifier: allowReservedCoreIdentifiers
                    ) {
                        plugins.append(plugin)
                    }
                }
            }
        } catch {
            NSLog("[ActionHalo] Failed to scan plugin directory: \(error.localizedDescription)")
        }
        
        return plugins
    }
}
