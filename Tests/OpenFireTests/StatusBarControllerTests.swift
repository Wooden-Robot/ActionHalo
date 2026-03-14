import XCTest
@testable import OpenFire

final class StatusBarControllerTests: XCTestCase {
    func testLaunchAgentPlistUsesBundleIdentifierInsteadOfBundlePath() {
        let plist = StatusBarController.launchAgentPlist(bundleIdentifier: "com.openfire.app")

        XCTAssertTrue(plist.contains("<string>/usr/bin/open</string>"))
        XCTAssertTrue(plist.contains("<string>-b</string>"))
        XCTAssertTrue(plist.contains("<string>com.openfire.app</string>"))
        XCTAssertFalse(plist.contains(Bundle.main.bundlePath))
    }

    func testRelaunchArgumentsPreserveRawBundlePath() {
        let args = StatusBarController.relaunchArguments(bundlePath: "/Applications/OpenFire Beta.app")

        XCTAssertEqual(args, ["/Applications/OpenFire Beta.app"])
        XCTAssertFalse(args[0].contains("%20"))
    }
}
