import XCTest
@testable import OpenFire

final class UpdateCheckerTests: XCTestCase {
    func testNormalizeVersionStripsPrefixAndSuffix() {
        let checker = UpdateChecker.shared

        XCTAssertEqual(checker.normalizeVersion("v1.2.3"), "1.2.3")
        XCTAssertEqual(checker.normalizeVersion("V2.0.0-beta"), "2.0.0")
        XCTAssertEqual(checker.normalizeVersion("3.4.5-rc.1"), "3.4.5")
    }

    func testNormalizeVersionHandlesWhitespace() {
        let checker = UpdateChecker.shared

        XCTAssertEqual(checker.normalizeVersion("  v0.9.0  "), "0.9.0")
        XCTAssertEqual(checker.normalizeVersion(" 1.0.1 "), "1.0.1")
    }

    func testUserFriendlyErrorMessageMapsNetworkErrors() {
        let checker = UpdateChecker.shared

        let noInternet = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        XCTAssertEqual(checker.userFriendlyErrorMessage(for: noInternet), "No Internet Connection".localized)

        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        XCTAssertEqual(checker.userFriendlyErrorMessage(for: timeout), "Request Timed Out".localized)
    }

    func testUserFriendlyErrorMessageFallsBackToLocalizedDescription() {
        let checker = UpdateChecker.shared

        let error = NSError(domain: "TestDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        XCTAssertEqual(checker.userFriendlyErrorMessage(for: error), "Boom")
    }

    func testAutoCheckEnabledDefaultsToTrueAndPersists() {
        let checker = UpdateChecker.shared
        let defaults = UserDefaults.standard
        let key = UpdateChecker.autoCheckEnabledKey
        let existingValue = defaults.object(forKey: key)
        defer {
            if let existingValue = existingValue {
                defaults.set(existingValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(checker.isAutoCheckEnabled())

        defaults.set(false, forKey: key)
        XCTAssertFalse(checker.isAutoCheckEnabled())

        defaults.set(true, forKey: key)
        XCTAssertTrue(checker.isAutoCheckEnabled())
    }
}
