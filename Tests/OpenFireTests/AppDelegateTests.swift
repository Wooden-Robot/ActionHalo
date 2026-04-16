import XCTest
@testable import OpenFire

final class AppDelegateTests: XCTestCase {
    func testRadialMenuPluginsIncludesBuiltInPaste() throws {
        let paste = try makePlugin(
            name: "Paste",
            identifier: "com.openfire.builtin.paste",
            actionType: "paste"
        )
        let search = try makePlugin(
            name: "Search",
            identifier: "com.openfire.search",
            actionType: "url",
            actionContent: "\"url\":\"https://example.com?q={text}\""
        )

        let filtered = AppDelegate.radialMenuPlugins(from: [paste, search])

        XCTAssertEqual(filtered.map(\.id), ["com.openfire.builtin.paste", "com.openfire.search"])
    }

    func testRadialMenuPluginsKeepsNonPastePluginsInOrder() throws {
        let first = try makePlugin(
            name: "Copy",
            identifier: "com.openfire.copy",
            actionType: "copy"
        )
        let second = try makePlugin(
            name: "Reveal",
            identifier: "com.openfire.reveal-path",
            actionType: "reveal-path"
        )

        let filtered = AppDelegate.radialMenuPlugins(from: [first, second])

        XCTAssertEqual(filtered.map(\.id), ["com.openfire.copy", "com.openfire.reveal-path"])
    }

    func testEmptyInputPastePluginRespectsPerAppDisabledOverrides() throws {
        let paste = try makePlugin(
            name: "Paste",
            identifier: "com.openfire.builtin.paste",
            actionType: "paste"
        )
        let search = try makePlugin(
            name: "Search",
            identifier: "com.openfire.search",
            actionType: "url",
            actionContent: "\"url\":\"https://example.com?q={text}\""
        )

        PluginManager.shared.setPluginEnabled("com.openfire.builtin.paste", enabled: false, forAppBundleID: "com.apple.Safari")

        let safariPaste = AppDelegate.emptyInputPastePlugin(
            from: [paste, search],
            appBundleID: "com.apple.Safari"
        )
        let finderPaste = AppDelegate.emptyInputPastePlugin(
            from: [paste, search],
            appBundleID: "com.apple.finder"
        )

        XCTAssertNil(safariPaste)
        XCTAssertEqual(finderPaste?.id, "com.openfire.builtin.paste")
    }

    func testEmptyInputPastePluginRespectsVisibilityRules() throws {
        let json = """
        {
            "name": "Paste",
            "identifier": "com.openfire.builtin.paste",
            "action": {
                "type": "paste"
            },
            "filter": {
                "apps": ["com.apple.finder"]
            }
        }
        """
        let paste = Plugin(
            config: try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8)),
            directoryURL: URL(fileURLWithPath: "/tmp/com.openfire.builtin.paste")
        )

        let safariPaste = AppDelegate.emptyInputPastePlugin(
            from: [paste],
            appBundleID: "com.apple.Safari"
        )
        let finderPaste = AppDelegate.emptyInputPastePlugin(
            from: [paste],
            appBundleID: "com.apple.finder"
        )

        XCTAssertNil(safariPaste)
        XCTAssertEqual(finderPaste?.id, "com.openfire.builtin.paste")
    }

    func testDeletePluginRequiresEditableSelectionToBeExecutable() throws {
        let delete = try makePlugin(
            name: "Delete",
            identifier: "com.openfire.delete",
            actionType: "key-combo",
            actionContent: "\"key\":\"delete\""
        )

        XCTAssertFalse(
            AppDelegate.isPluginExecutable(
                delete,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: false
            )
        )
        XCTAssertTrue(
            AppDelegate.isPluginExecutable(
                delete,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: true
            )
        )
    }

    func testPastePluginRequiresEditableSelectionToBeExecutable() throws {
        let paste = try makePlugin(
            name: "Paste",
            identifier: "com.openfire.builtin.paste",
            actionType: "paste"
        )

        XCTAssertFalse(
            AppDelegate.isPluginExecutable(
                paste,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: false
            )
        )
        XCTAssertTrue(
            AppDelegate.isPluginExecutable(
                paste,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: true
            )
        )
    }

    func testNonDeletePluginDoesNotRequireEditableSelection() throws {
        let copy = try makePlugin(
            name: "Copy",
            identifier: "com.openfire.copy",
            actionType: "copy"
        )

        XCTAssertTrue(
            AppDelegate.isPluginExecutable(
                copy,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: false
            )
        )
    }

    func testMenuDismissIsIdempotentWhileAlreadyInProgress() {
        let appDelegate = AppDelegate()
        var completionCount = 0

        XCTAssertTrue(appDelegate.beginMenuDismiss {
            completionCount += 1
        })
        XCTAssertFalse(appDelegate.beginMenuDismiss {
            completionCount += 1
        })

        appDelegate.finishMenuDismiss()

        XCTAssertEqual(completionCount, 2)
        XCTAssertTrue(appDelegate.beginMenuDismiss())
    }

    func testShouldResetAccessibilityPermissionsOnVersionChangeIsDisabledByDefault() {
        XCTAssertFalse(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.8",
                currentVersion: "0.3.9",
                resetOptInEnabled: false,
                hasAccessibilityPermission: true
            )
        )
    }

    func testShouldResetAccessibilityPermissionsOnVersionChangeAllowsExplicitOptInOnFirstLaunch() {
        XCTAssertTrue(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: nil,
                currentVersion: "0.3.9",
                resetOptInEnabled: true,
                hasAccessibilityPermission: false
            )
        )
    }

    func testShouldResetAccessibilityPermissionsOnVersionChangeResetsFirstLaunchWhenPermissionIsMissing() {
        XCTAssertTrue(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: nil,
                currentVersion: "0.3.12",
                resetOptInEnabled: false,
                hasAccessibilityPermission: false
            )
        )
    }

    func testShouldResetAccessibilityPermissionsOnVersionChangeSkipsSameVersion() {
        XCTAssertFalse(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.9",
                currentVersion: "0.3.9",
                resetOptInEnabled: true,
                hasAccessibilityPermission: true
            )
        )
    }

    func testShouldResetAccessibilityPermissionsOnVersionChangeAllowsExplicitOptInFallback() {
        XCTAssertTrue(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.8",
                currentVersion: "0.3.9",
                resetOptInEnabled: true,
                hasAccessibilityPermission: true
            )
        )
    }

    func testShouldResetAccessibilityPermissionsOnVersionChangeWhenPermissionIsMissingAfterUpgrade() {
        XCTAssertTrue(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.9",
                currentVersion: "0.3.10",
                resetOptInEnabled: false,
                hasAccessibilityPermission: false
            )
        )
    }

    func testShouldResetAccessibilityPermissionsOnSameVersionWhenPermissionIsMissing() {
        XCTAssertTrue(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.12",
                currentVersion: "0.3.12",
                resetOptInEnabled: false,
                hasAccessibilityPermission: false
            )
        )
    }

    func testMigrateDefaultExcludedAppsAddsOfficeSuitesOnFirstRun() {
        let migrated = AppDelegate.migratedExcludedApps(
            existingExcludedApps: [],
            storedMigrationVersion: 0
        )

        XCTAssertEqual(Set(migrated.apps), Set(AppDelegate.defaultOfficeSuiteExcludedApps))
        XCTAssertEqual(
            migrated.newMigrationVersion,
            AppDelegate.defaultOfficeSuiteExcludedAppsMigrationVersion
        )
    }

    func testMigrateDefaultExcludedAppsMergesWithoutRemovingExistingExclusions() {
        let migrated = AppDelegate.migratedExcludedApps(
            existingExcludedApps: ["com.apple.Safari"],
            storedMigrationVersion: 0
        )

        XCTAssertTrue(migrated.apps.contains("com.apple.Safari"))
        XCTAssertTrue(
            Set(AppDelegate.defaultOfficeSuiteExcludedApps).isSubset(of: Set(migrated.apps))
        )
    }

    func testMigrateDefaultExcludedAppsDoesNotDuplicateExistingOfficeAppEntries() {
        let migrated = AppDelegate.migratedExcludedApps(
            existingExcludedApps: ["com.microsoft.Word", "com.apple.Pages"],
            storedMigrationVersion: 0
        )

        XCTAssertEqual(migrated.apps.filter { $0 == "com.microsoft.Word" }.count, 1)
        XCTAssertEqual(migrated.apps.filter { $0 == "com.apple.Pages" }.count, 1)
    }

    func testMigrateDefaultExcludedAppsDoesNothingAfterMigrationAlreadyRan() {
        let migrated = AppDelegate.migratedExcludedApps(
            existingExcludedApps: ["com.apple.Safari"],
            storedMigrationVersion: AppDelegate.defaultOfficeSuiteExcludedAppsMigrationVersion
        )

        XCTAssertEqual(migrated.apps, ["com.apple.Safari"])
        XCTAssertEqual(
            migrated.newMigrationVersion,
            AppDelegate.defaultOfficeSuiteExcludedAppsMigrationVersion
        )
    }

    private func makePlugin(name: String, identifier: String, actionType: String, actionContent: String? = nil) throws -> Plugin {
        let extraActionFields = actionContent.map { ",\($0)" } ?? ""
        let json = """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": {
                "type": "\(actionType)"\(extraActionFields)
            }
        }
        """

        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/\(identifier)"))
    }
}
