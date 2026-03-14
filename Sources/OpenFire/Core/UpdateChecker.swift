import Cocoa

final class UpdateChecker {
    static let shared = UpdateChecker()
    static let autoCheckEnabledKey = "AutoCheckUpdates"

    private let owner = "woodenrobot"
    private let repo = "OpenFire"
    private let lastNotifiedVersionKey = "LastNotifiedVersion"
    private let stateQueue = DispatchQueue(label: "com.openfire.update-checker-state")
    private var isCheckingUpdates = false

    private init() {}

    func beginUpdateCheck() -> Bool {
        stateQueue.sync {
            guard !isCheckingUpdates else { return false }
            isCheckingUpdates = true
            return true
        }
    }

    func finishUpdateCheck() {
        stateQueue.sync {
            isCheckingUpdates = false
        }
    }

    func lastNotifiedVersion() -> String? {
        UserDefaults.standard.string(forKey: lastNotifiedVersionKey)
    }

    func setLastNotifiedVersion(_ version: String?) {
        if let version {
            UserDefaults.standard.set(version, forKey: lastNotifiedVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastNotifiedVersionKey)
        }
    }

    func isAutoCheckEnabled() -> Bool {
        return UserDefaults.standard.object(forKey: Self.autoCheckEnabledKey) as? Bool ?? true
    }

    func checkForUpdates(showUpToDate: Bool = false, showErrors: Bool = false) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        guard let url = latestReleaseAPIURL() else {
            return
        }
        guard beginUpdateCheck() else {
            NSLog("[OpenFire] Skipping update check because another check is already in flight.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("OpenFire", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            defer { self.finishUpdateCheck() }
            if let error = error {
                if showErrors {
                    DispatchQueue.main.async {
                        self.presentUpdateErrorAlert(message: self.userFriendlyErrorMessage(for: error))
                    }
                }
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if showErrors {
                    let message = String(
                        format: "Unexpected server response (%@).".localized,
                        "\(httpResponse.statusCode)"
                    )
                    DispatchQueue.main.async {
                        self.presentUpdateErrorAlert(message: message)
                    }
                }
                return
            }
            guard let data = data else {
                if showErrors {
                    DispatchQueue.main.async {
                        self.presentUpdateErrorAlert(message: "No data received.".localized)
                    }
                }
                return
            }

            let release: Release
            do {
                release = try JSONDecoder().decode(Release.self, from: data)
            } catch {
                if showErrors {
                    DispatchQueue.main.async {
                        self.presentUpdateErrorAlert(message: "Failed to parse update information.".localized)
                    }
                }
                return
            }

            let latestRaw = release.tag_name ?? release.name ?? ""
            let latestVersion = self.normalizeVersion(latestRaw)
            let normalizedCurrent = self.normalizeVersion(currentVersion)
            guard !latestVersion.isEmpty else { return }

            if normalizedCurrent.compare(latestVersion, options: .numeric) != .orderedAscending {
                self.setLastNotifiedVersion(nil)
                if showUpToDate {
                    DispatchQueue.main.async {
                        self.presentUpToDateAlert(currentVersion: normalizedCurrent)
                    }
                }
                return
            }

            if !showUpToDate,
               self.lastNotifiedVersion() == latestVersion {
                return
            }

            let downloadURL = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browser_download_url
            let targetURL = downloadURL ?? release.html_url
            guard let urlString = targetURL, let url = URL(string: urlString) else { return }

            DispatchQueue.main.async {
                self.presentUpdateAlert(latestVersion: latestVersion, currentVersion: normalizedCurrent, url: url)
                self.setLastNotifiedVersion(latestVersion)
            }
        }.resume()
    }

    private func presentUpdateAlert(latestVersion: String, currentVersion: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "New Version Available".localized
        alert.informativeText = String(
            format: "A newer version (%@) is available. You are using %@.".localized,
            latestVersion,
            currentVersion
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update".localized)
        alert.addButton(withTitle: "Later".localized)

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentUpToDateAlert(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Up to Date".localized
        alert.informativeText = String(
            format: "You're running the latest version (%@).".localized,
            currentVersion
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK".localized)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentUpdateErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed".localized
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry".localized)
        alert.addButton(withTitle: "OK".localized)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            checkForUpdates(showUpToDate: true, showErrors: true)
        }
    }

    func userFriendlyErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No Internet Connection".localized
            case NSURLErrorTimedOut:
                return "Request Timed Out".localized
            case NSURLErrorCannotFindHost:
                return "Server Not Found".localized
            case NSURLErrorCannotConnectToHost:
                return "Unable to Connect to Server".localized
            case NSURLErrorNetworkConnectionLost:
                return "Network Connection Lost".localized
            case NSURLErrorDNSLookupFailed:
                return "DNS Lookup Failed".localized
            default:
                break
            }
        }
        return error.localizedDescription
    }

    func normalizeVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        return withoutPrefix.split(separator: "-").first.map(String.init) ?? ""
    }

    func latestReleaseAPIURL() -> URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
    }
}

private struct Release: Decodable {
    let tag_name: String?
    let name: String?
    let html_url: String?
    let assets: [ReleaseAsset]
}

private struct ReleaseAsset: Decodable {
    let name: String
    let browser_download_url: String
}
