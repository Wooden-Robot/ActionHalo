import Cocoa
import Sparkle

@MainActor
protocol UpdateDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }

    func startUpdater()
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateDriver: UpdateDriving {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func startUpdater() {
        controller.startUpdater()
    }
}

/// Owns the application's update policy while Sparkle owns the update state
/// machine, archive verification, atomic installation, and post-install relaunch.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let legacyAutoCheckEnabledKey = "AutoCheckUpdates"

    private let driver: UpdateDriving

    private convenience init() {
        self.init(driver: SparkleUpdateDriver(), defaults: .standard)
    }

    init(driver: UpdateDriving, defaults: UserDefaults) {
        self.driver = driver

        // Versions before Sparkle stored this preference under an OpenFire key.
        // Move an explicit user choice into Sparkle's own preference once, then
        // let Sparkle remain the single source of truth from this point forward.
        if let legacyPreference = defaults.object(
            forKey: Self.legacyAutoCheckEnabledKey
        ) as? Bool {
            driver.automaticallyChecksForUpdates = legacyPreference
            defaults.removeObject(forKey: Self.legacyAutoCheckEnabledKey)
        }

        driver.startUpdater()
    }

    var canCheckForUpdates: Bool {
        driver.canCheckForUpdates
    }

    func isAutoCheckEnabled() -> Bool {
        driver.automaticallyChecksForUpdates
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        driver.automaticallyChecksForUpdates = enabled
    }

    @discardableResult
    func checkForUpdates() -> Bool {
        guard driver.canCheckForUpdates else {
            NSLog("[OpenFire] Skipping update check because Sparkle already has a session in progress.")
            return false
        }

        driver.checkForUpdates()
        return true
    }
}
