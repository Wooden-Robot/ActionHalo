import XCTest
@testable import OpenFire

final class AppExclusionStoreTests: XCTestCase {
    private let suiteName = "OpenFire.AppExclusionStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testStoresAndReadsExcludedApps() {
        AppExclusionStore.setExcludedApps([" com.apple.Pages ", "", "COM.APPLE.PAGES"], userDefaults: defaults)

        XCTAssertEqual(AppExclusionStore.excludedApps(userDefaults: defaults), ["com.apple.Pages"])
        XCTAssertTrue(AppExclusionStore.isExcluded("com.apple.Pages", userDefaults: defaults))
        XCTAssertTrue(AppExclusionStore.isExcluded(" COM.APPLE.PAGES ", userDefaults: defaults))
        XCTAssertFalse(AppExclusionStore.isExcluded("com.apple.TextEdit", userDefaults: defaults))
        XCTAssertFalse(AppExclusionStore.isExcluded("", userDefaults: defaults))
        XCTAssertFalse(AppExclusionStore.isExcluded(nil, userDefaults: defaults))
    }

    func testInMemoryExclusionMatchingUsesCanonicalBundleIDs() {
        XCTAssertTrue(AppExclusionStore.contains(" COM.APPLE.PAGES ", in: ["com.apple.Pages"]))
        XCTAssertTrue(AppExclusionStore.isExcluded(" COM.APPLE.PAGES ", in: ["com.apple.Pages"]))
        XCTAssertFalse(AppExclusionStore.isExcluded("com.apple.TextEdit", in: ["com.apple.Pages"]))
    }

    func testToggledExcludedAppsUsesCanonicalBundleIDs() {
        XCTAssertEqual(
            AppExclusionStore.toggledExcludedApps(
                "com.apple.Pages",
                in: [" COM.APPLE.PAGES ", "com.apple.TextEdit"]
            ),
            ["com.apple.TextEdit"]
        )

        XCTAssertEqual(
            AppExclusionStore.toggledExcludedApps(
                " com.apple.Pages ",
                in: ["com.apple.TextEdit"]
            ),
            ["com.apple.TextEdit", "com.apple.Pages"]
        )
    }
}
