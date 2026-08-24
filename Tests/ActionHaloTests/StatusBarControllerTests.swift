import XCTest
@testable import ActionHalo

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func testLaunchAgentPlistUsesBundleIdentifierInsteadOfBundlePath() {
        let plist = StatusBarController.launchAgentPlist(bundleIdentifier: "com.actionhalo.app")

        XCTAssertTrue(plist.contains("<string>/usr/bin/open</string>"))
        XCTAssertTrue(plist.contains("<string>-b</string>"))
        XCTAssertTrue(plist.contains("<string>com.actionhalo.app</string>"))
        XCTAssertFalse(plist.contains(Bundle.main.bundlePath))
    }

    func testRelaunchArgumentsPreserveRawBundlePath() {
        let args = StatusBarController.relaunchArguments(bundlePath: "/Applications/ActionHalo Beta.app")

        XCTAssertEqual(args, ["/Applications/ActionHalo Beta.app"])
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

    func testBaseStatusIconTracksEnabledState() throws {
        let enabledImage = StatusBarController.baseStatusIconImage(isEnabled: true)
        let disabledImage = StatusBarController.baseStatusIconImage(isEnabled: false)

        XCTAssertEqual(enabledImage.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(disabledImage.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(enabledImage.isTemplate)
        XCTAssertTrue(disabledImage.isTemplate)
        XCTAssertEqual(enabledImage.accessibilityDescription, "ActionHalo")
        XCTAssertNotEqual(
            try XCTUnwrap(enabledImage.tiffRepresentation),
            try XCTUnwrap(disabledImage.tiffRepresentation)
        )
    }

    func testEnabledStateDefaultsToTrue() throws {
        let suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(StatusBarController.enabledState(userDefaults: defaults))
    }

    func testEnabledStateReadsActionHaloPreference() throws {
        let suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "ActionHaloEnabled")

        XCTAssertFalse(StatusBarController.enabledState(userDefaults: defaults))
    }

    func testEnabledStateWritesActionHaloPreference() throws {
        let suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        StatusBarController.persistEnabledState(false, userDefaults: defaults)

        XCTAssertEqual(defaults.object(forKey: "ActionHaloEnabled") as? Bool, false)
    }
}
