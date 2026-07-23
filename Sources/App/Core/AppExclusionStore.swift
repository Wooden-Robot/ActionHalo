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
        contains(bundleID, in: excludedApps(userDefaults: userDefaults))
    }

    static func isExcluded(_ bundleID: String?, in bundleIDs: [String]) -> Bool {
        contains(bundleID, in: bundleIDs)
    }

    static func contains(_ bundleID: String?, in bundleIDs: [String]) -> Bool {
        guard let bundleID else { return false }
        let lookupKey = canonicalBundleID(bundleID)
        guard !lookupKey.isEmpty else { return false }
        return bundleIDs.contains { canonicalBundleID($0) == lookupKey }
    }

    static func toggledExcludedApps(_ bundleID: String, in bundleIDs: [String]) -> [String] {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupKey = canonicalBundleID(trimmed)
        guard !lookupKey.isEmpty else { return normalizedBundleIDs(bundleIDs) }

        if bundleIDs.contains(where: { canonicalBundleID($0) == lookupKey }) {
            return normalizedBundleIDs(bundleIDs.filter { canonicalBundleID($0) != lookupKey })
        }

        return normalizedBundleIDs(bundleIDs + [trimmed])
    }

    static func normalizedBundleIDs(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for bundleID in bundleIDs {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = canonicalBundleID(trimmed)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            normalized.append(trimmed)
            seen.insert(key)
        }

        return normalized
    }

    static func canonicalBundleID(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
