import XCTest
@testable import OpenFire

@MainActor
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

    func testClosedAttachedMenuIsDetachedEvenAfterMainMenuWasRebuilt() {
        let attachedMenu = NSMenu()
        let rebuiltMenu = NSMenu()

        XCTAssertTrue(
            StatusBarController.shouldDetachStatusMenu(
                attachedMenu: attachedMenu,
                closedMenu: attachedMenu
            )
        )
        XCTAssertFalse(
            StatusBarController.shouldDetachStatusMenu(
                attachedMenu: rebuiltMenu,
                closedMenu: attachedMenu
            )
        )
    }

    func testBaseStatusIconTracksEnabledState() {
        XCTAssertEqual(StatusBarController.baseStatusIconSymbolName(isEnabled: true), "flame.fill")
        XCTAssertEqual(StatusBarController.baseStatusIconSymbolName(isEnabled: false), "flame")
    }
}
