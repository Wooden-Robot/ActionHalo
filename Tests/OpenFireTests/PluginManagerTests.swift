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
