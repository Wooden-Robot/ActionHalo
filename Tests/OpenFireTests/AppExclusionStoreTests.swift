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
        AppExclusionStore.setExcludedApps([" com.apple.Pages ", "", "com.apple.Pages"], userDefaults: defaults)

        XCTAssertEqual(AppExclusionStore.excludedApps(userDefaults: defaults), ["com.apple.Pages"])
        XCTAssertTrue(AppExclusionStore.isExcluded("com.apple.Pages", userDefaults: defaults))
        XCTAssertFalse(AppExclusionStore.isExcluded("com.apple.TextEdit", userDefaults: defaults))
        XCTAssertFalse(AppExclusionStore.isExcluded("", userDefaults: defaults))
        XCTAssertFalse(AppExclusionStore.isExcluded(nil, userDefaults: defaults))
    }
}
