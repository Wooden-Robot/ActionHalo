import XCTest
@testable import OpenFire

final class PluginManagerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        let userPluginsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        PluginManager.shared.userPluginsDirectoryOverride = userPluginsURL
        temporaryDirectories.append(userPluginsURL)
    }
    
    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        PluginManager.shared.userPluginsDirectoryOverride = nil
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        super.tearDown()
    }
    
    func testMaxRadialMenuItemsSettingIsApplied() {
        // Prepare some dummy plugins in the manager
        let manager = PluginManager.shared
        manager.plugins.removeAll() // Clear any system-loaded plugins
        
        // Add 20 mock plugins
        for i in 1...20 {
            let json = "{\"name\": \"Test " + String(i) + "\", \"identifier\": \"com.test.plugin" + String(i) + "\", \"action\": { \"type\": \"url\", \"url\": \"https://example.com\" }, \"icon\": \"star\", \"order\": " + String(i) + "}"
            let config = try! JSONDecoder().decode(PluginConfig.self, from: json.data(using: .utf8)!)
            let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: ""))
            plugin.isEnabled = true
            manager.plugins.append(plugin)
        }
        
        // The plugin manager should return all enabled plugins for menu presentation.
        // Actual page-size truncation happens inside RadialMenuWindow pagination.
        UserDefaults.standard.set(0, forKey: "maxRadialMenuItems")
        var available = manager.presentationPlugins(appBundleID: nil)
        XCTAssertEqual(available.count, 20, "PluginManager should not pre-truncate plugin lists")
        
        // Changing page-size settings should not affect the source plugin list length.
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")
        available = manager.presentationPlugins(appBundleID: nil)
        XCTAssertEqual(available.count, 20, "Page-size settings should not truncate the manager output")
        
        // Pagination still consumes the full ordered list.
        UserDefaults.standard.set(16, forKey: "maxRadialMenuItems")
        available = manager.presentationPlugins(appBundleID: nil)
        XCTAssertEqual(available.count, 20, "Larger page-size settings should also preserve the full list")
    }
    
    func testPresentationPluginsIgnoresTextMatchButRespectsEnabledState() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        
        let jsonEnabled = "{\"name\": \"Enabled\", \"identifier\": \"com.test.enabled\", \"action\": { \"type\": \"url\", \"url\": \"https://example.com\" }, \"icon\": \"star\", \"order\": 1}"
        let configEnabled = try! JSONDecoder().decode(PluginConfig.self, from: jsonEnabled.data(using: .utf8)!)
        let pluginEnabled = Plugin(config: configEnabled, directoryURL: URL(fileURLWithPath: ""))
        pluginEnabled.isEnabled = true
        manager.plugins.append(pluginEnabled)
        
        let jsonDisabled = "{\"name\": \"Disabled\", \"identifier\": \"com.test.disabled\", \"action\": { \"type\": \"url\", \"url\": \"https://example.com\" }, \"icon\": \"star\", \"order\": 2}"
        let configDisabled = try! JSONDecoder().decode(PluginConfig.self, from: jsonDisabled.data(using: .utf8)!)
        let pluginDisabled = Plugin(config: configDisabled, directoryURL: URL(fileURLWithPath: ""))
        pluginDisabled.isEnabled = false // Explicitly disabled
        manager.plugins.append(pluginDisabled)
        
        // 1. Fetch presentation plugins
        let available = manager.presentationPlugins(appBundleID: nil)
        
        // 2. Validate
        XCTAssertEqual(available.count, 1, "Should only return 1 enabled plugin")
        XCTAssertEqual(available.first?.id, "com.test.enabled", "Disabled plugin should be filtered out entirely")
        
        // Note: the `isMatch` filtering on the text string happens *purely* in the UI to gray out matches
        // which we'll test in RadialMenuItemTests.
    }
    
    func testPresentationPluginsKeepsEnabledPluginsEvenWhenFilterDoesNotMatch() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        
        let matchingJSON = #"{"name":"Match","identifier":"com.test.match","action":{"type":"url","url":"https://example.com"},"icon":"star","order":1,"filter":{"regex":"^https://","apps":["com.apple.Safari"]}}"#
        let nonMatchingJSON = #"{"name":"NoMatch","identifier":"com.test.nomatch","action":{"type":"url","url":"https://example.com"},"icon":"star","order":2,"filter":{"regex":"^[0-9]+$"}}"#
        
        let matchingConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(matchingJSON.utf8))
        let nonMatchingConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(nonMatchingJSON.utf8))
        
        let matchingPlugin = Plugin(config: matchingConfig, directoryURL: URL(fileURLWithPath: ""))
        let nonMatchingPlugin = Plugin(config: nonMatchingConfig, directoryURL: URL(fileURLWithPath: ""))
        
        manager.plugins = [matchingPlugin, nonMatchingPlugin]
        
        let available = manager.presentationPlugins(appBundleID: "com.apple.Safari")
        
        XCTAssertEqual(available.map(\.id), ["com.test.match", "com.test.nomatch"])
    }
    
    func testPresentationPluginsKeepsAllEnabledPluginsVisible() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        
        let openURLJSON = #"{"name":"Open URL","identifier":"com.openfire.open-url","action":{"type":"url","url":"{text}"},"icon":"link","order":70,"filter":{"minLength":5,"regex":"^(https?://|www\\.)[^ ]+"}}"#
        let revealPathJSON = #"{"name":"Reveal Path","identifier":"com.openfire.reveal-path","action":{"type":"reveal-path"},"icon":"folder","order":65,"filter":{"minLength":2,"regex":"^/.*$"}}"#
        let normalJSON = #"{"name":"Search","identifier":"com.test.search","action":{"type":"url","url":"https://example.com?q={text}"},"icon":"magnifyingglass","order":10}"#
        
        let openURLConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(openURLJSON.utf8))
        let revealPathConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(revealPathJSON.utf8))
        let normalConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(normalJSON.utf8))
        
        manager.plugins = [
            Plugin(config: normalConfig, directoryURL: URL(fileURLWithPath: "")),
            Plugin(config: revealPathConfig, directoryURL: URL(fileURLWithPath: "")),
            Plugin(config: openURLConfig, directoryURL: URL(fileURLWithPath: ""))
        ]
        
        let available = manager.presentationPlugins(appBundleID: nil)
        
        XCTAssertEqual(available.map(\.id), ["com.test.search", "com.openfire.reveal-path", "com.openfire.open-url"])
    }

    func testPresentationPluginsRespectsPerAppDisabledOverrides() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()

        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1, directory: "/tmp/first")
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2, directory: "/tmp/second")
        manager.plugins = [first, second]

        manager.setPluginEnabled("com.test.second", enabled: false, forAppBundleID: "com.apple.Safari")

        let safariPlugins = manager.presentationPlugins(appBundleID: "com.apple.Safari")
        let finderPlugins = manager.presentationPlugins(appBundleID: "com.apple.finder")

        XCTAssertEqual(safariPlugins.map(\.id), ["com.test.first"])
        XCTAssertEqual(finderPlugins.map(\.id), ["com.test.first", "com.test.second"])
        XCTAssertEqual(manager.disabledPluginIDs(forAppBundleID: "com.apple.Safari"), ["com.test.second"])
    }

    func testVisibilityDiagnosticsExplainPerAppDisabledOverride() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()

        let plugin = makePlugin(name: "Scoped", identifier: "com.test.scoped", order: 1, directory: "/tmp/scoped")
        manager.plugins = [plugin]
        manager.setPluginEnabled("com.test.scoped", enabled: false, forAppBundleID: "com.apple.Safari")

        let diagnostic = try! XCTUnwrap(manager.visibilityDiagnostics(for: "text", appBundleID: "com.apple.Safari").first)

        XCTAssertFalse(diagnostic.isVisible)
        XCTAssertEqual(diagnostic.reasons, [.disabledForApp("com.apple.Safari")])
    }

    func testAllPerAppDisabledPluginOverridesListsEveryScopedDisable() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()

        manager.setPluginEnabled("com.test.first", enabled: false, forAppBundleID: "com.apple.Safari")
        manager.setPluginEnabled("com.test.second", enabled: false, forAppBundleID: "com.apple.finder")

        let overrides = manager.allPerAppDisabledPluginOverrides()

        XCTAssertEqual(
            overrides,
            [
                .init(appBundleID: "com.apple.Safari", pluginID: "com.test.first"),
                .init(appBundleID: "com.apple.finder", pluginID: "com.test.second")
            ]
        )

        manager.clearPerAppOverride(pluginID: "com.test.first", forAppBundleID: "com.apple.Safari")
        XCTAssertEqual(
            manager.allPerAppDisabledPluginOverrides(),
            [.init(appBundleID: "com.apple.finder", pluginID: "com.test.second")]
        )
    }

    func testMergePluginsPreservingExistingPrefersUserPluginForDuplicateIdentifier() {
        let oldUserPlugin = makePlugin(
            name: "Old User Version",
            identifier: "com.test.duplicate",
            order: 1,
            directory: "/tmp/user"
        )
        let newBuiltInPlugin = makePlugin(
            name: "New Built-In Version",
            identifier: "com.test.duplicate",
            order: 99,
            directory: "/tmp/builtin"
        )

        let merged = PluginManager.mergePluginsPreservingExisting(
            user: [oldUserPlugin],
            builtIn: [newBuiltInPlugin]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.name, "Old User Version")
        XCTAssertEqual(merged.first?.directoryURL.path, "/tmp/user")
    }

    func testMergePluginsPreservingExistingKeepsBuiltInCorePluginWhenUserUsesCoreIdentifier() {
        let userOverride = makePlugin(
            name: "Fake Copy",
            identifier: "com.openfire.copy",
            order: 1,
            directory: "/tmp/user-copy"
        )
        let builtInCopy = makePlugin(
            name: "Copy",
            identifier: "com.openfire.copy",
            order: 1,
            directory: "/Applications/OpenFire.app/Contents/Resources/Plugins/Copy.openfireext"
        )

        let merged = PluginManager.mergePluginsPreservingExisting(
            user: [userOverride],
            builtIn: [builtInCopy]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "com.openfire.copy")
        XCTAssertEqual(merged.first?.directoryURL.path, builtInCopy.directoryURL.path)
    }

    func testMergePluginsPreservingExistingKeepsFirstUserDuplicate() {
        let oldestPlugin = makePlugin(
            name: "Oldest",
            identifier: "com.test.duplicate",
            order: 1,
            directory: "/tmp/oldest"
        )
        let newerPlugin = makePlugin(
            name: "Newer",
            identifier: "com.test.duplicate",
            order: 2,
            directory: "/tmp/newer"
        )

        let merged = PluginManager.mergePluginsPreservingExisting(
            user: [oldestPlugin, newerPlugin],
            builtIn: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.name, "Oldest")
        XCTAssertEqual(merged.first?.directoryURL.path, "/tmp/oldest")
    }

    func testFilterSoftDeletedBuiltInsKeepsUserOverrideAndRemovesBundledCopy() {
        let userPlugin = makePlugin(
            name: "User Search",
            identifier: "com.test.search",
            order: 1,
            directory: "/Users/me/Library/Application Support/OpenFire/Plugins/Search.openfireext"
        )
        let builtInDeletedPlugin = makePlugin(
            name: "Built In Search",
            identifier: "com.test.deleted",
            order: 2,
            directory: "/Applications/OpenFire.app/Contents/Resources/Plugins/Search.openfireext"
        )
        let coreBuiltIn = makePlugin(
            name: "Copy",
            identifier: "com.openfire.copy",
            order: 3,
            directory: "/Applications/OpenFire.app/Contents/Resources/Plugins/Copy.openfireext"
        )

        let filtered = PluginManager.filterSoftDeletedBuiltIns(
            [
                userPlugin,
                builtInDeletedPlugin,
                coreBuiltIn
            ],
            deletedBuiltInPluginIDs: ["com.test.search", "com.test.deleted", "com.openfire.copy"],
            builtInPluginsURL: URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins")
        )

        XCTAssertEqual(filtered.map(\.id), ["com.test.search", "com.openfire.copy"])
    }

    func testFilterSoftDeletedBuiltInsDoesNotTreatSiblingPathPrefixAsBuiltIn() {
        let siblingPlugin = makePlugin(
            name: "Sibling Search",
            identifier: "com.test.sibling",
            order: 1,
            directory: "/Applications/OpenFire.app/Contents/Resources/PluginsBackup/Search.openfireext"
        )

        let filtered = PluginManager.filterSoftDeletedBuiltIns(
            [siblingPlugin],
            deletedBuiltInPluginIDs: ["com.test.sibling"],
            builtInPluginsURL: URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins")
        )

        XCTAssertEqual(filtered.map(\.id), ["com.test.sibling"])
    }

    func testPluginDirectoryContainmentRequiresDirectoryBoundary() {
        let pluginsURL = URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins")

        XCTAssertTrue(PluginManager.isPluginDirectory(
            URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins/Search.openfireext"),
            inside: pluginsURL
        ))
        XCTAssertFalse(PluginManager.isPluginDirectory(
            URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/PluginsBackup/Search.openfireext"),
            inside: pluginsURL
        ))
        XCTAssertFalse(PluginManager.isPluginDirectory(
            URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins"),
            inside: pluginsURL
        ))
    }

    func testBuiltInPluginDirectoryUsesConfiguredBuiltInDirectory() {
        let builtInPluginsURL = URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins")

        XCTAssertTrue(PluginManager.isBuiltInPluginDirectory(
            URL(fileURLWithPath: "/Applications/OpenFire.app/Contents/Resources/Plugins/Search.openfireext"),
            builtInPluginsURL: builtInPluginsURL
        ))
        XCTAssertFalse(PluginManager.isBuiltInPluginDirectory(
            URL(fileURLWithPath: "/tmp/Other.app/Contents/Resources/Plugins/Search.openfireext"),
            builtInPluginsURL: builtInPluginsURL
        ))
    }

    func testVisibleUserPluginFileNameDoesNotCreateHiddenPackageNames() {
        XCTAssertEqual(PluginManager.visibleUserPluginFileName(for: ".book"), "book.openfireext")
        XCTAssertEqual(PluginManager.visibleUserPluginFileName(for: "com.test.book"), "com.test.book.openfireext")
    }

    func testPluginIdentifierValidationMatchesEditorRulesForNewPlugins() {
        XCTAssertNil(PluginManager.pluginIdentifierValidationMessage("z-lib"))
        XCTAssertEqual(
            PluginManager.pluginIdentifierValidationMessage("z/lib"),
            "Identifier must use only letters, numbers, dots, and hyphens.".localized
        )
        XCTAssertEqual(
            PluginManager.pluginIdentifierValidationMessage(".book"),
            "Identifier cannot start or end with dots or hyphens.".localized
        )
        XCTAssertEqual(
            PluginManager.pluginIdentifierValidationMessage("COM.OPENFIRE.COPY"),
            "Identifier is reserved for a built-in plugin.".localized
        )
        XCTAssertNil(PluginManager.pluginIdentifierValidationMessage(
            ".book",
            allowLegacyBoundaryCharacters: true
        ))
    }

    func testPresentationPluginsOrdersUnlistedPluginsByConfiguredOrderAfterSavedOrder() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1, directory: "/tmp/first")
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2, directory: "/tmp/second")
        let third = makePlugin(name: "Third", identifier: "com.test.third", order: 3, directory: "/tmp/third")
        manager.plugins = [third, first, second]

        UserDefaults.standard.set(["com.test.second"], forKey: "pluginOrder")

        let available = manager.presentationPlugins(appBundleID: nil)

        XCTAssertEqual(available.map(\.id), ["com.test.second", "com.test.first", "com.test.third"])
    }

    func testOrderedPluginsForDisplayUsesSameSavedOrderFallback() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1, directory: "/tmp/first")
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2, directory: "/tmp/second")
        let third = makePlugin(name: "Third", identifier: "com.test.third", order: 3, directory: "/tmp/third")
        manager.plugins = [third, first, second]

        UserDefaults.standard.set(["com.test.second"], forKey: "pluginOrder")

        XCTAssertEqual(
            manager.orderedPluginsForDisplay().map(\.id),
            ["com.test.second", "com.test.first", "com.test.third"]
        )
    }

    func testRepairHiddenUserPluginPackagesRenamesDotPrefixedPackage() throws {
        let pluginsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let hiddenPackageURL = pluginsURL.appendingPathComponent(".book.openfireext")
        let visiblePackageURL = pluginsURL.appendingPathComponent("book.openfireext")
        temporaryDirectories.append(pluginsURL)

        try FileManager.default.createDirectory(at: hiddenPackageURL, withIntermediateDirectories: true)
        let config = """
        {
            "name": "Book",
            "identifier": ".book",
            "action": { "type": "url", "url": "https://example.com?q={text}" }
        }
        """
        try config.write(to: hiddenPackageURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)

        PluginManager.repairHiddenUserPluginPackages(in: pluginsURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenPackageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: visiblePackageURL.path))
        XCTAssertEqual(PluginLoader.load(from: visiblePackageURL)?.id, ".book")
    }

    func testWatchablePluginDirectoriesIncludesExistingPluginPackages() throws {
        let pluginsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(pluginsURL)

        let packageURL = pluginsURL.appendingPathComponent("Custom.openfireext")
        let regularDirectoryURL = pluginsURL.appendingPathComponent("Notes")
        let fakePackageFileURL = pluginsURL.appendingPathComponent("NotADirectory.openfireext")

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: regularDirectoryURL, withIntermediateDirectories: true)
        try Data().write(to: fakePackageFileURL)

        let watchableNames = PluginManager.watchablePluginDirectories(userPluginsURL: pluginsURL)
            .map(\.lastPathComponent)

        XCTAssertEqual(watchableNames, [pluginsURL.lastPathComponent, "Custom.openfireext"])
    }

    func testExecutionTrustTracksCurrentFingerprint() throws {
        let manager = PluginManager.shared
        let bundleURL = try makeScriptPluginBundle(
            identifier: "com.test.trust",
            scriptContent: "echo first"
        )

        let pluginA = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        XCTAssertFalse(manager.isExecutionTrusted(for: pluginA))

        manager.setExecutionTrusted(true, for: pluginA)
        XCTAssertTrue(manager.isExecutionTrusted(for: pluginA))

        try "echo second".write(to: bundleURL.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
        let pluginB = try XCTUnwrap(PluginLoader.load(from: bundleURL))

        XCTAssertFalse(manager.isExecutionTrusted(for: pluginB))
    }

    func testTrustedExecutionSnapshotIsDetachedFromMutablePluginPackage() throws {
        let manager = PluginManager.shared
        let bundleURL = try makeScriptPluginBundle(
            identifier: "com.test.trusted-snapshot",
            scriptContent: "source helper.sh"
        )
        let sourceHelperURL = bundleURL.appendingPathComponent("helper.sh")
        try "echo trusted".write(to: sourceHelperURL, atomically: true, encoding: .utf8)

        let plugin = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        manager.setExecutionTrusted(true, for: plugin)
        let snapshot = try XCTUnwrap(manager.makeTrustedExecutionSnapshot(for: plugin))
        defer { manager.removeTrustedExecutionSnapshot(snapshot) }

        try "echo changed".write(to: sourceHelperURL, atomically: true, encoding: .utf8)

        let snapshotHelper = try String(
            contentsOf: snapshot.plugin.directoryURL.appendingPathComponent("helper.sh"),
            encoding: .utf8
        )
        XCTAssertEqual(snapshotHelper, "echo trusted")
        XCTAssertNotEqual(snapshot.plugin.directoryURL, plugin.directoryURL)
        XCTAssertTrue(manager.isExecutionTrusted(for: snapshot.plugin))
    }

    func testTrustedExecutionSnapshotRejectsPackageChangedAfterTrust() throws {
        let manager = PluginManager.shared
        let bundleURL = try makeScriptPluginBundle(
            identifier: "com.test.changed-before-snapshot",
            scriptContent: "source helper.sh"
        )
        let helperURL = bundleURL.appendingPathComponent("helper.sh")
        try "echo trusted".write(to: helperURL, atomically: true, encoding: .utf8)

        let plugin = try XCTUnwrap(PluginLoader.load(from: bundleURL))
        manager.setExecutionTrusted(true, for: plugin)
        try "echo changed".write(to: helperURL, atomically: true, encoding: .utf8)

        XCTAssertNil(manager.makeTrustedExecutionSnapshot(for: plugin))
    }

    func testUserPluginURLFindsLegacyNamedOverrideByIdentifier() throws {
        let manager = PluginManager.shared
        let legacyURL = manager.userPluginsURL.appendingPathComponent("Legacy Name.openfireext")
        temporaryDirectories.append(legacyURL)

        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let config = """
        {
            "name": "Legacy",
            "identifier": "com.test.legacy",
            "action": { "type": "copy" }
        }
        """
        try config.write(to: legacyURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)

        let resolvedURL = manager.userPluginURL(for: "com.test.legacy")

        XCTAssertEqual(resolvedURL?.lastPathComponent, "Legacy Name.openfireext")
    }

    func testRemoveDuplicateUserPluginsPreservesNewlySavedPackageURL() throws {
        let manager = PluginManager.shared
        let identifier = "z-lib-test-\(UUID().uuidString.lowercased())"
        let packageURL = manager.userPluginsURL.appendingPathComponent("\(identifier).openfireext")
        temporaryDirectories.append(packageURL)

        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let config = """
        {
            "name": "Z-Lib",
            "identifier": "\(identifier)",
            "action": { "type": "url", "url": "https://z-library.sk/s/{text}" }
        }
        """
        try config.write(to: packageURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)

        manager.removeDuplicateUserPlugins(for: identifier, keeping: packageURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testInstallPluginRejectsInvalidPluginPackage() throws {
        let manager = PluginManager.shared
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".openfireext")
        let destinationURL = manager.userPluginsURL.appendingPathComponent(invalidURL.lastPathComponent)
        temporaryDirectories.append(invalidURL)
        temporaryDirectories.append(destinationURL)

        try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)

        XCTAssertFalse(manager.installPlugin(from: invalidURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testInstallPluginDetailedReturnsInvalidPackageFailure() throws {
        let manager = PluginManager.shared
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".openfireext")
        temporaryDirectories.append(invalidURL)

        try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)

        XCTAssertEqual(manager.installPluginDetailed(from: invalidURL), .failed(.invalidPackage))
    }

    func testInstallPackagePreflightRejectsFileCountAndByteLimits() throws {
        let pluginURL = try makePluginBundle(identifier: "com.test.install-limits", name: "Limits")
        try "helper".write(
            to: pluginURL.appendingPathComponent("helper.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(
            PluginManager.isInstallPackageWithinLimits(
                pluginURL,
                maxFileCount: 2,
                maxTotalBytes: 4_096
            )
        )
        XCTAssertFalse(
            PluginManager.isInstallPackageWithinLimits(
                pluginURL,
                maxFileCount: 1,
                maxTotalBytes: 4_096
            )
        )
        XCTAssertFalse(
            PluginManager.isInstallPackageWithinLimits(
                pluginURL,
                maxFileCount: 2,
                maxTotalBytes: 1
            )
        )
    }

    func testInstallPackagePreflightRejectsSymbolicLinks() throws {
        let pluginURL = try makePluginBundle(identifier: "com.test.install-symlink", name: "Symlink")
        let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(outsideURL)
        try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: pluginURL.appendingPathComponent("helper.txt"),
            withDestinationURL: outsideURL
        )

        XCTAssertFalse(PluginManager.isInstallPackageWithinLimits(pluginURL))
    }

    func testInstallPluginRejectsCorePluginIdentifierOverride() throws {
        let manager = PluginManager.shared
        let pluginURL = try makePluginBundle(identifier: "com.openfire.copy", name: "Fake Copy")
        let destinationURL = manager.userPluginsURL.appendingPathComponent("com.openfire.copy.openfireext")
        temporaryDirectories.append(destinationURL)

        XCTAssertFalse(manager.installPlugin(from: pluginURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testInstallPluginRejectsCaseInsensitiveCorePluginIdentifierOverride() throws {
        let manager = PluginManager.shared
        let pluginURL = try makePluginBundle(identifier: "COM.OPENFIRE.COPY", name: "Fake Copy")
        let destinationURL = manager.userPluginsURL.appendingPathComponent("COM.OPENFIRE.COPY.openfireext")
        temporaryDirectories.append(destinationURL)

        XCTAssertFalse(manager.installPlugin(from: pluginURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testInstallPluginRejectsExternalPackageWithUnsafeIdentifier() throws {
        let manager = PluginManager.shared
        let pluginURL = try makePluginBundle(identifier: "z/lib", name: "Z-Lib")
        let destinationURL = manager.userPluginsURL.appendingPathComponent("z-lib.openfireext")
        temporaryDirectories.append(destinationURL)

        XCTAssertFalse(manager.installPlugin(from: pluginURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testInstallPluginDetailedReturnsIdentifierFailure() throws {
        let manager = PluginManager.shared
        let pluginURL = try makePluginBundle(identifier: "z/lib", name: "Z-Lib")

        XCTAssertEqual(
            manager.installPluginDetailed(from: pluginURL),
            .failed(.invalidIdentifier("Identifier must use only letters, numbers, dots, and hyphens.".localized))
        )
    }

    func testInstallPluginReplacesExistingPackageWithValidatedStagedCopy() throws {
        let manager = PluginManager.shared
        let identifier = "com.test.replace"
        let destinationURL = manager.userPluginsURL.appendingPathComponent("\(identifier).openfireext")
        temporaryDirectories.append(destinationURL)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try pluginConfig(identifier: identifier, name: "Old").write(
            to: destinationURL.appendingPathComponent("Config.json"),
            atomically: true,
            encoding: .utf8
        )

        let sourceURL = try makePluginBundle(identifier: identifier, name: "New")

        XCTAssertTrue(manager.installPlugin(from: sourceURL))

        let installed = try XCTUnwrap(PluginLoader.load(from: destinationURL))
        XCTAssertEqual(installed.config.name, "New")
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: manager.userPluginsURL.path))
                .contains { $0.hasSuffix(".openfireext.pending") }
        )
    }

    func testRestoreBackedUpPackageMovesBackupWhenDestinationIsMissing() throws {
        let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(parentURL)
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let backupURL = parentURL.appendingPathComponent(".backup-test.openfireext.pending")
        let destinationURL = parentURL.appendingPathComponent("Plugin.openfireext")
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try "old".write(to: backupURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)

        let shouldRemoveBackup = PluginManager.restoreBackedUpPackageIfNeeded(
            backupURL: backupURL,
            destinationURL: destinationURL,
            didMoveDestinationToBackup: true,
            logPrefix: "Test"
        )

        XCTAssertTrue(shouldRemoveBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testRestoreBackedUpPackagePreservesBackupWhenDestinationAlreadyExists() throws {
        let parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(parentURL)
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let backupURL = parentURL.appendingPathComponent(".backup-test.openfireext.pending")
        let destinationURL = parentURL.appendingPathComponent("Plugin.openfireext")
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let shouldRemoveBackup = PluginManager.restoreBackedUpPackageIfNeeded(
            backupURL: backupURL,
            destinationURL: destinationURL,
            didMoveDestinationToBackup: true,
            logPrefix: "Test"
        )

        XCTAssertFalse(shouldRemoveBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testStalePluginLoadResultsAreDiscarded() {
        let manager = PluginManager.shared

        let firstLoad = manager.beginPluginLoad()
        let secondLoad = manager.beginPluginLoad()

        XCTAssertFalse(manager.shouldApplyPluginLoadResult(firstLoad))
        XCTAssertTrue(manager.shouldApplyPluginLoadResult(secondLoad))
    }

    func testPluginProcessStderrSummaryDoesNotExposeOutputUnlessVerboseLoggingIsEnabled() {
        XCTAssertEqual(
            PluginManager.pluginProcessStderrLogMessage(
                logPrefix: "Shell script",
                stderr: "selected private text",
                terminationStatus: 1,
                verboseLoggingEnabled: false
            ),
            "Shell script produced stderr (21 bytes). Enable verbose plugin logging to inspect output."
        )
        XCTAssertNil(
            PluginManager.pluginProcessStderrLogMessage(
                logPrefix: "Shell script",
                stderr: "selected private text",
                terminationStatus: 0,
                verboseLoggingEnabled: false
            )
        )
        XCTAssertEqual(
            PluginManager.pluginProcessStderrLogMessage(
                logPrefix: "Shell script",
                stderr: "selected private text",
                terminationStatus: 0,
                verboseLoggingEnabled: true
            ),
            "Shell script stderr: selected private text"
        )
    }

    func testAppendPluginProcessStderrChunkCapsStoredBytes() {
        var stderrData = Data()

        let firstTruncated = PluginManager.appendPluginProcessStderrChunk(
            Data("abcdef".utf8),
            to: &stderrData,
            maxBytes: 4
        )
        let secondTruncated = PluginManager.appendPluginProcessStderrChunk(
            Data("gh".utf8),
            to: &stderrData,
            maxBytes: 4
        )

        XCTAssertTrue(firstTruncated)
        XCTAssertTrue(secondTruncated)
        XCTAssertEqual(String(data: stderrData, encoding: .utf8), "abcd")
    }

    func testProcessListParserIgnoresMalformedRows() {
        let processes = PluginManager.processList(from: """
             PID PPID
             10  1
             nope 10
             11  10 extra
        """)

        XCTAssertEqual(processes.map(\.pid), [10, 11])
        XCTAssertEqual(processes.map(\.parentPID), [1, 10])
    }

    func testProcessTreeTerminationOrderKillsChildrenBeforeParents() {
        let processes: [(pid: pid_t, parentPID: pid_t)] = [
            (pid: 10, parentPID: 1),
            (pid: 11, parentPID: 10),
            (pid: 12, parentPID: 11),
            (pid: 13, parentPID: 10),
            (pid: 99, parentPID: 1)
        ]

        XCTAssertEqual(
            PluginManager.processTreeTerminationOrder(rootPID: 10, processList: processes),
            [12, 11, 13, 10]
        )
    }

    func testProcessTreeEscalationUsesOnlyCurrentlyVerifiedDescendants() {
        let currentProcesses: [(pid: pid_t, parentPID: pid_t)] = [
            (pid: 10, parentPID: 1),
            (pid: 12, parentPID: 10),
            (pid: 11, parentPID: 1)
        ]

        XCTAssertEqual(
            PluginManager.processTreeTerminationOrder(rootPID: 10, processList: currentProcesses),
            [12, 10]
        )
    }

    func testResolvedPluginScriptSourceAllowsBundledFilesAndInlineCode() throws {
        let bundleURL = try makeScriptPluginBundle(
            identifier: "com.test.script-source",
            scriptContent: "echo bundled"
        )
        let fileSource = PluginManager.resolvedPluginScriptSource(
            "script.sh",
            pluginDirectoryURL: bundleURL
        )
        let inlineSource = PluginManager.resolvedPluginScriptSource(
            "echo inline",
            pluginDirectoryURL: bundleURL
        )

        XCTAssertEqual(fileSource, .bundledFile(bundleURL.appendingPathComponent("script.sh")))
        XCTAssertEqual(inlineSource, .inline("echo inline"))
    }

    func testResolvedPluginScriptSourceRejectsPathsOutsidePackage() throws {
        let bundleURL = try makeScriptPluginBundle(
            identifier: "com.test.script-traversal",
            scriptContent: "echo bundled"
        )
        let externalURL = bundleURL.deletingLastPathComponent().appendingPathComponent("payload.sh")
        try "echo external".write(to: externalURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: externalURL) }

        XCTAssertNil(PluginManager.resolvedPluginScriptSource(
            "../payload.sh",
            pluginDirectoryURL: bundleURL
        ))
        XCTAssertNil(PluginManager.resolvedPluginScriptSource(
            "missing.sh",
            pluginDirectoryURL: bundleURL
        ))
    }

    func testRenderedURLStringEncodesPlaceholderAsOneComponent() {
        let rendered = PluginManager.renderedURLString(
            template: "https://example.com/search?q={text}",
            text: "a&b=c?d+e/f"
        )

        XCTAssertEqual(rendered, "https://example.com/search?q=a%26b%3Dc%3Fd%2Be%2Ff")
    }

    func testRenderedURLStringNormalizesDirectOpenURLTemplate() {
        XCTAssertEqual(
            PluginManager.renderedURLString(template: "{text}", text: "www.example.com"),
            "https://www.example.com"
        )
        XCTAssertEqual(
            PluginManager.renderedURLString(template: "{text}", text: "https://example.com?a=1&b=2"),
            "https://example.com?a=1&b=2"
        )
    }

    func testRenderedAppleScriptSourceEscapesPlaceholderInsideQuotedString() {
        let rendered = PluginManager.renderedAppleScriptSource(
            #"set query to "prefix {text} suffix""#,
            text: #"a "quoted" value"#
        )

        XCTAssertEqual(rendered, #"set query to "prefix " & "a \"quoted\" value" & " suffix""#)
    }

    func testRenderedAppleScriptSourceUsesLiteralExpressionOutsideString() {
        let rendered = PluginManager.renderedAppleScriptSource(
            "set query to {text}",
            text: "line 1\nline 2"
        )

        XCTAssertEqual(rendered, #"set query to "line 1" & linefeed & "line 2""#)
    }

    private func makePlugin(name: String, identifier: String, order: Int, directory: String) -> Plugin {
        let json = """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": { "type": "copy" },
            "icon": "star",
            "order": \(order)
        }
        """

        let config = try! JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: directory))
    }

    private func makePluginBundle(identifier: String, name: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".openfireext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        try pluginConfig(identifier: identifier, name: name)
            .write(to: bundleURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        return bundleURL
    }

    private func pluginConfig(identifier: String, name: String) -> String {
        """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": { "type": "copy" }
        }
        """
    }

    private func makeScriptPluginBundle(identifier: String, scriptContent: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".openfireext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let config = """
        {
            "name": "Script Plugin",
            "identifier": "\(identifier)",
            "action": { "type": "shell-script", "script": "script.sh" }
        }
        """

        try config.write(to: bundleURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        try scriptContent.write(to: bundleURL.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
        return bundleURL
    }
}
