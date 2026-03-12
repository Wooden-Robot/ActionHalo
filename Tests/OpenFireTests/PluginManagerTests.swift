import XCTest
@testable import OpenFire

final class PluginManagerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }
    
    override func tearDown() {
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
        
        // 1. Test Default Limit (12)
        UserDefaults.standard.set(0, forKey: "maxRadialMenuItems")
        var available = manager.availablePlugins(for: "test", appBundleID: nil)
        XCTAssertEqual(available.count, 12, "Default undefined limit should truncate to 12 items")
        
        // 2. Test Limit 6
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")
        available = manager.availablePlugins(for: "test", appBundleID: nil)
        XCTAssertEqual(available.count, 6, "Limit should truncate to 6 items")
        
        // 3. Test Limit 16
        UserDefaults.standard.set(16, forKey: "maxRadialMenuItems")
        available = manager.availablePlugins(for: "test", appBundleID: nil)
        XCTAssertEqual(available.count, 16, "Limit should truncate to 16 items")
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
    
    func testAvailablePluginsRespectsPluginFilters() {
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
        
        XCTAssertEqual(available.map(\.id), ["com.test.match"])
    }
    
    func testAvailablePluginsKeepsReservedOpenURLPlaceholder() {
        let manager = PluginManager.shared
        manager.plugins.removeAll()
        
        let openURLJSON = #"{"name":"Open URL","identifier":"com.openfire.open-url","action":{"type":"url","url":"{text}"},"icon":"link","order":70,"filter":{"minLength":5,"regex":"^(https?://|www\\.)[^ ]+"}}"#
        let normalJSON = #"{"name":"Search","identifier":"com.test.search","action":{"type":"url","url":"https://example.com?q={text}"},"icon":"magnifyingglass","order":10}"#
        
        let openURLConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(openURLJSON.utf8))
        let normalConfig = try! JSONDecoder().decode(PluginConfig.self, from: Data(normalJSON.utf8))
        
        manager.plugins = [
            Plugin(config: normalConfig, directoryURL: URL(fileURLWithPath: "")),
            Plugin(config: openURLConfig, directoryURL: URL(fileURLWithPath: ""))
        ]
        
        let available = manager.availablePlugins(for: "plain text", appBundleID: nil)
        
        XCTAssertEqual(available.map(\.id), ["com.test.search", "com.openfire.open-url"])
    }
}
