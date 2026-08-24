import XCTest
@testable import ActionHalo

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

    func testBaseStatusIconTracksEnabledState() {
        XCTAssertEqual(StatusBarController.baseStatusIconSymbolName(isEnabled: true), "flame.fill")
        XCTAssertEqual(StatusBarController.baseStatusIconSymbolName(isEnabled: false), "flame")
    }

    func testEnabledStateMigratesLegacyPreference() throws {
        let suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "OpenFireEnabled")

        XCTAssertFalse(StatusBarController.migratedEnabledState(userDefaults: defaults))
        XCTAssertEqual(defaults.object(forKey: "ActionHaloEnabled") as? Bool, false)
    }

    func testCurrentEnabledStateTakesPrecedenceOverLegacyPreference() throws {
        let suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "ActionHaloEnabled")
        defaults.set(false, forKey: "OpenFireEnabled")

        XCTAssertTrue(StatusBarController.migratedEnabledState(userDefaults: defaults))
    }

    func testEnabledStateWritesCurrentAndLegacyPreferencesForRollback() throws {
        let suiteName = "StatusBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        StatusBarController.persistEnabledState(false, userDefaults: defaults)

        XCTAssertEqual(defaults.object(forKey: "ActionHaloEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "OpenFireEnabled") as? Bool, false)
    }
}
