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
}
