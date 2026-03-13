import Foundation

/// Loads and parses .openfireext plugin packages
final class PluginLoader {
    
    /// Load a plugin from a .openfireext directory
    static func load(from directoryURL: URL) -> Plugin? {
        let configURL = directoryURL.appendingPathComponent("Config.json")
        
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            NSLog("[OpenFire] Plugin config not found: \(configURL.path)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            let config = try decoder.decode(PluginConfig.self, from: data)
            
            // Validate required fields
            guard !config.name.isEmpty, !config.identifier.isEmpty else {
                NSLog("[OpenFire] Plugin config missing required fields: \(directoryURL.lastPathComponent)")
                return nil
            }
            
            let plugin = Plugin(config: config, directoryURL: directoryURL)
            NSLog("[OpenFire] Loaded plugin: \(config.name) (\(config.identifier))")
            return plugin
            
        } catch {
            NSLog("[OpenFire] Failed to load plugin at \(directoryURL.path): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Scan a directory for .openfireext packages
    static func scanDirectory(_ directoryURL: URL) -> [Plugin] {
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
                if itemURL.pathExtension == "openfireext" {
                    if let plugin = load(from: itemURL) {
                        plugins.append(plugin)
                    }
                }
            }
        } catch {
            NSLog("[OpenFire] Failed to scan plugin directory: \(error.localizedDescription)")
        }
        
        return plugins
    }
}
