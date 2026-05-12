import XCTest
@testable import OpenFire

final class PluginManagerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }
    
    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
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
        
        // The plugin manager should return all enabled plugins.
        // Actual page-size truncation happens inside RadialMenuWindow pagination.
        UserDefaults.standard.set(0, forKey: "maxRadialMenuItems")
        var available = manager.availablePlugins(for: "test", appBundleID: nil)
        XCTAssertEqual(available.count, 20, "PluginManager should not pre-truncate plugin lists")
        
        // Changing page-size settings should not affect the source plugin list length.
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")
        available = manager.availablePlugins(for: "test", appBundleID: nil)
        XCTAssertEqual(available.count, 20, "Page-size settings should not truncate the manager output")
        
        // Pagination still consumes the full ordered list.
        UserDefaults.standard.set(16, forKey: "maxRadialMenuItems")
        available = manager.availablePlugins(for: "test", appBundleID: nil)
        XCTAssertEqual(available.count, 20, "Larger page-size settings should also preserve the full list")
    }
    
    func testAvailablePluginsIgnoresTextMatchButRespectsEnabledState() {
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
        
        // 1. Fetch available plugins
        let available = manager.availablePlugins(for: "some random text", appBundleID: nil)
        
        // 2. Validate
        XCTAssertEqual(available.count, 1, "Should only return 1 enabled plugin")
        XCTAssertEqual(available.first?.id, "com.test.enabled", "Disabled plugin should be filtered out entirely")
        
        // Note: the `isMatch` filtering on the text string happens *purely* in the UI to gray out matches
        // which we'll test in RadialMenuItemTests.
    }
    
    func testAvailablePluginsKeepsEnabledPluginsEvenWhenFilterDoesNotMatch() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        
        let matchingJSON = #"{"name":"Match","identifier":"com.test.match","action":{"type":"url","url":"https://example.com"},"icon":"star","order":1,"filter":{"regex":"^https://","apps":["com.apple.Safari"]}}"#
        let nonMatchingJSON = #"{"name":"NoMatch","identifier":"com.test.nomatch","action":{"type":"url","url":"https://example.com"},"icon":"star","order":2,"filter":{"regex":"^[0-9]+$"}}"#
        
        let matchingConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(matchingJSON.utf8))
        let nonMatchingConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(nonMatchingJSON.utf8))
        
        let matchingPlugin = Plugin(config: matchingConfig, directoryURL: URL(fileURLWithPath: ""))
        let nonMatchingPlugin = Plugin(config: nonMatchingConfig, directoryURL: URL(fileURLWithPath: ""))
        
        manager.plugins = [matchingPlugin, nonMatchingPlugin]
        
        let available = manager.availablePlugins(for: "https://openai.com", appBundleID: "com.apple.Safari")
        
        XCTAssertEqual(available.map(\.id), ["com.test.match", "com.test.nomatch"])
    }
    
    func testAvailablePluginsKeepsAllEnabledPluginsVisible() {
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
        
        let available = manager.availablePlugins(for: "plain text", appBundleID: nil)
        
        XCTAssertEqual(available.map(\.id), ["com.test.search", "com.openfire.reveal-path", "com.openfire.open-url"])
    }

    func testAvailablePluginsRespectsPerAppDisabledOverrides() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()

        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1, directory: "/tmp/first")
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2, directory: "/tmp/second")
        manager.plugins = [first, second]

        manager.setPluginEnabled("com.test.second", enabled: false, forAppBundleID: "com.apple.Safari")

        let safariPlugins = manager.availablePlugins(for: "text", appBundleID: "com.apple.Safari")
        let finderPlugins = manager.availablePlugins(for: "text", appBundleID: "com.apple.finder")

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

    func testInstallPluginRejectsCorePluginIdentifierOverride() throws {
        let manager = PluginManager.shared
        let pluginURL = try makePluginBundle(identifier: "com.openfire.copy", name: "Fake Copy")
        let destinationURL = manager.userPluginsURL.appendingPathComponent("com.openfire.copy.openfireext")
        temporaryDirectories.append(destinationURL)

        XCTAssertFalse(manager.installPlugin(from: pluginURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
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

        let config = """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": { "type": "copy" }
        }
        """

        try config.write(to: bundleURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        return bundleURL
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
