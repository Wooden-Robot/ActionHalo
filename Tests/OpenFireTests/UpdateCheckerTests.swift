import XCTest
@testable import OpenFire

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    private final class FakeUpdateDriver: UpdateDriving {
        var automaticallyChecksForUpdates: Bool
        var canCheckForUpdates: Bool
        private(set) var checkCount = 0
        private(set) var startCount = 0
        private(set) var automaticChecksWhenStarted: Bool?

        init(automaticallyChecksForUpdates: Bool, canCheckForUpdates: Bool = true) {
            self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            self.canCheckForUpdates = canCheckForUpdates
        }

        func checkForUpdates() {
            checkCount += 1
        }

        func startUpdater() {
            startCount += 1
            automaticChecksWhenStarted = automaticallyChecksForUpdates
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OpenFire.UpdateCheckerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLegacyAutomaticCheckPreferenceMigratesIntoSparkleOnce() {
        defaults.set(false, forKey: UpdateChecker.legacyAutoCheckEnabledKey)
        let driver = FakeUpdateDriver(automaticallyChecksForUpdates: true)

        let checker = UpdateChecker(driver: driver, defaults: defaults)

        XCTAssertFalse(checker.isAutoCheckEnabled())
        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.automaticChecksWhenStarted, false)
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertNil(defaults.object(forKey: UpdateChecker.legacyAutoCheckEnabledKey))
    }

    @MainActor
    func testSparkleDefaultIsPreservedWithoutLegacyPreference() {
        let driver = FakeUpdateDriver(automaticallyChecksForUpdates: true)

        let checker = UpdateChecker(driver: driver, defaults: defaults)

        XCTAssertTrue(checker.isAutoCheckEnabled())
        XCTAssertTrue(driver.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.automaticChecksWhenStarted, true)
        XCTAssertEqual(driver.startCount, 1)
    }

    @MainActor
    func testSettingAutomaticChecksUpdatesSparkleOwnedPreference() {
        let driver = FakeUpdateDriver(automaticallyChecksForUpdates: true)
        let checker = UpdateChecker(driver: driver, defaults: defaults)

        checker.setAutoCheckEnabled(false)
        XCTAssertFalse(checker.isAutoCheckEnabled())

        checker.setAutoCheckEnabled(true)
        XCTAssertTrue(checker.isAutoCheckEnabled())
    }

    @MainActor
    func testManualCheckStartsSparkleSessionWhenAvailable() {
        let driver = FakeUpdateDriver(automaticallyChecksForUpdates: true)
        let checker = UpdateChecker(driver: driver, defaults: defaults)

        XCTAssertTrue(checker.checkForUpdates())
        XCTAssertEqual(driver.checkCount, 1)
    }

    @MainActor
    func testManualCheckIsRejectedWhileSparkleCannotStartAnotherSession() {
        let driver = FakeUpdateDriver(
            automaticallyChecksForUpdates: true,
            canCheckForUpdates: false
        )
        let checker = UpdateChecker(driver: driver, defaults: defaults)

        XCTAssertFalse(checker.checkForUpdates())
        XCTAssertEqual(driver.checkCount, 0)
    }

}
