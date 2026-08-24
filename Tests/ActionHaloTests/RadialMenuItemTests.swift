import XCTest
@testable import ActionHalo

final class RadialMenuItemTests: XCTestCase {
    
    func testInitializationAndDefaults() {
        let action = RadialMenuAction.pageNext
        
        let item = RadialMenuItem(
            title: "Next",
            iconName: "arrow.right",
            action: action
        )
        
        XCTAssertEqual(item.title, "Next")
        XCTAssertEqual(item.iconName, "arrow.right")
        XCTAssertTrue(item.isExecutable, "Items should be executable by default")
    }
    
    func testDisabledExecutableState() {
        let json = "{\"name\": \"URL Action\", \"identifier\": \"com.test.url\", \"action\": { \"type\": \"url\", \"url\": \"https://example.com\" }, \"icon\": \"star\"}"
        let config = try! JSONDecoder().decode(PluginConfig.self, from: json.data(using: .utf8)!)
        let plugin = Plugin(config: config, directoryURL: URL(fileURLWithPath: ""))
        
        let item = RadialMenuItem(
            title: plugin.name,
            iconName: plugin.iconName,
            action: .plugin(plugin),
            isExecutable: false
        )
        
        XCTAssertFalse(item.isExecutable)
    }
}
