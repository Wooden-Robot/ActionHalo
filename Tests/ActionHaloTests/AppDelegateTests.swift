import XCTest
@testable import ActionHalo

@MainActor
final class AppDelegateTests: XCTestCase {
    func testTerminationRequiresExplicitDiscardWhenPluginEditorsAreDirty() {
        XCTAssertTrue(
            AppDelegate.shouldTerminate(
                hasVisibleUnsavedPluginEditors: false,
                discardConfirmed: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldTerminate(
                hasVisibleUnsavedPluginEditors: true,
                discardConfirmed: false
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldTerminate(
                hasVisibleUnsavedPluginEditors: true,
                discardConfirmed: true
            )
        )
    }

    func testMonitoringStartFailureMessagesExplainNextStep() {
        XCTAssertEqual(
            AppDelegate.monitoringStartFailureMessage(.accessibilityPermissionMissing),
            "ActionHalo does not currently have Accessibility permission. Please re-check ActionHalo in System Settings.".localized
        )
        XCTAssertEqual(
            AppDelegate.monitoringStartFailureMessage(.eventTapCreationFailed),
            "ActionHalo could not start the text selection monitor. If Accessibility is already enabled but ActionHalo still does not respond, reset the permission record and re-check ActionHalo in System Settings.".localized
        )
    }

    func testEventTapFailureOffersAccessibilityReset() {
        XCTAssertFalse(AppDelegate.shouldOfferAccessibilityPermissionReset(for: .accessibilityPermissionMissing))
        XCTAssertTrue(AppDelegate.shouldOfferAccessibilityPermissionReset(for: .eventTapCreationFailed))
    }

    func testAccessibilityResetArgumentsPreserveLegacyBundleIDForTCCContinuity() {
        XCTAssertEqual(
            AppDelegate.accessibilityResetArguments(bundleIdentifier: "com.openfire.app"),
            ["reset", "Accessibility", "com.openfire.app"]
        )
    }

    func testPluginPackageOpeningAcceptsCurrentAndLegacyExtensions() {
        XCTAssertTrue(
            AppDelegate.isSupportedPluginPackageURL(
                URL(fileURLWithPath: "/tmp/Search.actionhaloext")
            )
        )
        XCTAssertTrue(
            AppDelegate.isSupportedPluginPackageURL(
                URL(fileURLWithPath: "/tmp/Search.openfireext")
            )
        )
        XCTAssertFalse(
            AppDelegate.isSupportedPluginPackageURL(
                URL(fileURLWithPath: "/tmp/Search.plugin")
            )
        )
    }

    func testMigrationRelaunchCarriesPendingFinderPluginRequests() {
        XCTAssertEqual(
            AppDelegate.migrationLaunchArguments(
                commandLineArguments: ["--verbose", "/tmp/Legacy.openfireext"],
                pendingPluginURLs: [
                    URL(fileURLWithPath: "/tmp/Plugin with spaces.actionhaloext"),
                    URL(fileURLWithPath: "/tmp/Legacy.openfireext")
                ]
            ),
            [
                "--verbose",
                "/tmp/Legacy.openfireext",
                "/tmp/Plugin with spaces.actionhaloext"
            ]
        )
    }

    func testProcessRunnerReturnsWithoutWaitingForever() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["1"]

        let startedAt = Date()
        let status = try AppDelegate.runProcess(process, timeout: 0.02)

        XCTAssertNil(status)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
    }

    func testRadialMenuPluginsIncludesBuiltInPaste() throws {
        let paste = try makePlugin(
            name: "Paste",
            identifier: "com.actionhalo.builtin.paste",
            actionType: "paste"
        )
        let search = try makePlugin(
            name: "Search",
            identifier: "com.actionhalo.search",
            actionType: "url",
            actionContent: "\"url\":\"https://example.com?q={text}\""
        )

        let filtered = AppDelegate.radialMenuPlugins(from: [paste, search])

        XCTAssertEqual(filtered.map(\.id), ["com.actionhalo.builtin.paste", "com.actionhalo.search"])
    }

    func testRadialMenuPluginsKeepsNonPastePluginsInOrder() throws {
        let first = try makePlugin(
            name: "Copy",
            identifier: "com.actionhalo.copy",
            actionType: "copy"
        )
        let second = try makePlugin(
            name: "Reveal",
            identifier: "com.actionhalo.reveal-path",
            actionType: "reveal-path"
        )

        let filtered = AppDelegate.radialMenuPlugins(from: [first, second])

        XCTAssertEqual(filtered.map(\.id), ["com.actionhalo.copy", "com.actionhalo.reveal-path"])
    }

    func testEmptyInputPastePluginRespectsVisibilityRules() throws {
        let json = """
        {
            "name": "Paste",
            "identifier": "com.actionhalo.builtin.paste",
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
            directoryURL: URL(fileURLWithPath: "/tmp/com.actionhalo.builtin.paste")
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
        XCTAssertEqual(finderPaste?.id, "com.actionhalo.builtin.paste")
    }

    func testMenuPresentationRequiresEnabledStateAndAllowedFrontmostApp() {
        XCTAssertFalse(
            AppDelegate.shouldAllowMenuPresentation(
                isEnabled: false,
                frontmostBundleID: "com.apple.Safari",
                frontmostLocalizedName: "Safari",
                isFocusedSelectionEditable: false
            )
        )

        XCTAssertFalse(
            AppDelegate.shouldAllowMenuPresentation(
                isEnabled: true,
                frontmostBundleID: "com.apple.finder",
                frontmostLocalizedName: "Finder",
                isFocusedSelectionEditable: false
            )
        )

        XCTAssertTrue(
            AppDelegate.shouldAllowMenuPresentation(
                isEnabled: true,
                frontmostBundleID: "com.apple.finder",
                frontmostLocalizedName: "Finder",
                isFocusedSelectionEditable: true
            )
        )
    }

    func testMenuPresentationRespectsExcludedAppsEvenWhenEditable() {
        XCTAssertFalse(
            AppDelegate.shouldAllowMenuPresentation(
                isEnabled: true,
                frontmostBundleID: "com.microsoft.Word",
                frontmostLocalizedName: "Microsoft Word",
                isFocusedSelectionEditable: true,
                isAppExcluded: { $0 == "com.microsoft.Word" }
            )
        )
    }

    func testMenuPresentationRespectsExcludedAppsForEmptyInputContext() {
        XCTAssertFalse(
            AppDelegate.shouldAllowMenuPresentation(
                isEnabled: true,
                frontmostBundleID: "com.microsoft.Word",
                frontmostLocalizedName: "Microsoft Word",
                isFocusedSelectionEditable: false,
                isAppExcluded: { $0 == "com.microsoft.Word" }
            )
        )
    }

    func testDeletePluginRequiresEditableSelectionToBeExecutable() throws {
        let delete = try makePlugin(
            name: "Delete",
            identifier: "com.actionhalo.delete",
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

    func testCutPluginRequiresEditableSelectionToBeExecutable() throws {
        let cut = try makePlugin(
            name: "Cut",
            identifier: "com.actionhalo.cut",
            actionType: "key-combo",
            actionContent: "\"key\":\"x\",\"modifiers\":[\"command\"]"
        )

        XCTAssertFalse(
            AppDelegate.isPluginExecutable(
                cut,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: false
            )
        )
        XCTAssertTrue(
            AppDelegate.isPluginExecutable(
                cut,
                text: "selected",
                appBundleID: nil,
                isSelectionEditable: true
            )
        )
    }

    func testPastePluginRequiresEditableSelectionToBeExecutable() throws {
        let paste = try makePlugin(
            name: "Paste",
            identifier: "com.actionhalo.builtin.paste",
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

    func testCustomPasteActionAlsoRequiresEditableSelection() throws {
        let paste = try makePlugin(
            name: "Custom Paste",
            identifier: "com.example.custom-paste",
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
            identifier: "com.actionhalo.copy",
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

    func testEditableMenuActionRequiresOriginalFocusedElement() {
        XCTAssertFalse(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                requiresOriginalFocusedElement: true,
                requiresEditableTarget: true,
                focusedElementMatches: false,
                isFocusedSelectionEditable: true
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                requiresOriginalFocusedElement: true,
                requiresEditableTarget: true,
                focusedElementMatches: true,
                isFocusedSelectionEditable: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                requiresOriginalFocusedElement: true,
                requiresEditableTarget: true,
                focusedElementMatches: true,
                isFocusedSelectionEditable: false
            )
        )
    }

    func testReadOnlyMenuActionDoesNotDependOnFocusedElementIdentity() {
        XCTAssertTrue(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                requiresOriginalFocusedElement: false,
                requiresEditableTarget: false,
                focusedElementMatches: false,
                isFocusedSelectionEditable: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 7,
                requiresOriginalFocusedElement: false,
                requiresEditableTarget: false,
                focusedElementMatches: true,
                isFocusedSelectionEditable: true
            )
        )
    }

    func testCustomKeyComboRequiresOriginalFocusWithoutAssumingEditability() throws {
        let keyCombo = try makePlugin(
            name: "Command Palette",
            identifier: "com.example.command-palette",
            actionType: "key-combo",
            actionContent: "\"key\":\"p\",\"modifiers\":[\"command\",\"shift\"]"
        )

        XCTAssertTrue(AppDelegate.pluginRequiresOriginalFocusedElement(keyCombo))
        XCTAssertFalse(AppDelegate.pluginRequiresEditableTarget(keyCombo))
        XCTAssertTrue(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                requiresOriginalFocusedElement: true,
                requiresEditableTarget: false,
                focusedElementMatches: true,
                isFocusedSelectionEditable: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldExecuteMenuAction(
                expectedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                requiresOriginalFocusedElement: true,
                requiresEditableTarget: false,
                focusedElementMatches: false,
                isFocusedSelectionEditable: true
            )
        )
    }

    func testNotificationAccessibilityElementExtractionRejectsWrongTypes() {
        let element = AXUIElementCreateApplication(42)

        XCTAssertNil(AppDelegate.accessibilityElement(from: nil))
        XCTAssertNil(AppDelegate.accessibilityElement(from: "not an accessibility element"))
        XCTAssertTrue(
            AccessibilityManager.areSameAccessibilityElement(
                AppDelegate.accessibilityElement(from: element),
                element
            )
        )
    }

    func testAccessibilityElementIdentityMatchesEquivalentTargetsOnly() {
        let firstTarget = AXUIElementCreateApplication(42)
        let sameTarget = AXUIElementCreateApplication(42)
        let otherTarget = AXUIElementCreateApplication(43)

        XCTAssertTrue(
            AccessibilityManager.areSameAccessibilityElement(firstTarget, sameTarget)
        )
        XCTAssertFalse(
            AccessibilityManager.areSameAccessibilityElement(firstTarget, otherTarget)
        )
    }

    func testPluginInstallPreviewRunsOffMainThreadAndReturnsOnMainActor() async {
        let completed = expectation(description: "preview completion")

        AppDelegate.loadPluginInstallPreview(
            from: URL(fileURLWithPath: "/tmp/Test.actionhaloext"),
            on: DispatchQueue(label: "com.actionhalo.tests.install-preview"),
            previewProvider: { _ -> PluginManager.PluginInstallPreview? in
                XCTAssertFalse(Thread.isMainThread)
                return nil
            },
            completion: { preview in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertNil(preview)
                completed.fulfill()
            }
        )

        await fulfillment(of: [completed], timeout: 1)
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

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(appDelegate.beginMenuDismiss())
    }

    func testSingleFireActionGateConsumesOnlyOnceUntilReset() {
        let gate = SingleFireActionGate()

        XCTAssertTrue(gate.consume())
        XCTAssertFalse(gate.consume())

        gate.reset()

        XCTAssertTrue(gate.consume())
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

    func testShouldResetAccessibilityPermissionsOnSameVersionWhenPermissionIsMissingWithoutRecordedReset() {
        XCTAssertTrue(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.12",
                currentVersion: "0.3.12",
                resetOptInEnabled: false,
                hasAccessibilityPermission: false
            )
        )
    }

    func testShouldNotResetAccessibilityPermissionsTwiceInSameVersion() {
        XCTAssertFalse(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.12",
                currentVersion: "0.3.12",
                resetOptInEnabled: false,
                hasAccessibilityPermission: false,
                lastResetVersion: "0.3.12"
            )
        )
    }

    func testExplicitAccessibilityResetOptInStillRunsOnlyOncePerVersion() {
        XCTAssertFalse(
            AppDelegate.shouldResetAccessibilityPermissionsOnVersionChange(
                lastVersion: "0.3.11",
                currentVersion: "0.3.12",
                resetOptInEnabled: true,
                hasAccessibilityPermission: true,
                lastResetVersion: "0.3.12"
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

@MainActor
final class AppDelegateGlobalStateTests: GlobalStateTestCase {
    override func setUp() {
        super.setUp()
        isolateStandardUserDefaults(keys: [PluginManager.perAppDisabledPluginsKey])
    }

    func testEmptyInputPastePluginRespectsPerAppDisabledOverrides() throws {
        let pasteConfig = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Paste","identifier":"com.actionhalo.builtin.paste","action":{"type":"paste"}}"#.utf8
            )
        )
        let searchConfig = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Search","identifier":"com.actionhalo.search","action":{"type":"url","url":"https://example.com?q={text}"}}"#.utf8
            )
        )
        let paste = Plugin(
            config: pasteConfig,
            directoryURL: URL(fileURLWithPath: "/tmp/com.actionhalo.builtin.paste")
        )
        let search = Plugin(
            config: searchConfig,
            directoryURL: URL(fileURLWithPath: "/tmp/com.actionhalo.search")
        )

        PluginManager.shared.setPluginEnabled(
            "com.actionhalo.builtin.paste",
            enabled: false,
            forAppBundleID: "com.apple.Safari"
        )

        XCTAssertNil(
            AppDelegate.emptyInputPastePlugin(
                from: [paste, search],
                appBundleID: "com.apple.Safari"
            )
        )
        XCTAssertEqual(
            AppDelegate.emptyInputPastePlugin(
                from: [paste, search],
                appBundleID: "com.apple.finder"
            )?.id,
            "com.actionhalo.builtin.paste"
        )
    }
}
