import Foundation

enum AppExclusionStore {
    static let defaultsKey = "ExcludedApps"

    static func excludedApps(userDefaults: UserDefaults = .standard) -> [String] {
        userDefaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func setExcludedApps(_ bundleIDs: [String], userDefaults: UserDefaults = .standard) {
        userDefaults.set(normalizedBundleIDs(bundleIDs), forKey: defaultsKey)
    }

    static func isExcluded(_ bundleID: String?, userDefaults: UserDefaults = .standard) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return excludedApps(userDefaults: userDefaults).contains(bundleID)
    }

    static func normalizedBundleIDs(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for bundleID in bundleIDs {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            normalized.append(trimmed)
            seen.insert(trimmed)
        }

        return normalized
    }
}
