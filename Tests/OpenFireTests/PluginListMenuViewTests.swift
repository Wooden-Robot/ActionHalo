import Cocoa
import XCTest
@testable import OpenFire

final class PluginListMenuViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        PluginManager.shared.plugins.removeAll()
    }

    override func tearDown() {
        PluginManager.shared.plugins.removeAll()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        super.tearDown()
    }

    func testVisiblePluginListReloadsWhenPluginsReloadedNotificationArrives() {
        let firstPlugin = makePlugin(name: "First", identifier: "com.test.first", order: 1)
        let secondPlugin = makePlugin(name: "Second", identifier: "com.test.second", order: 2)
        let listView = PluginListMenuView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))

        PluginManager.shared.plugins = [firstPlugin]
        listView.reloadPlugins()
        XCTAssertEqual(listView.numberOfRows(in: NSTableView()), 1)

        PluginManager.shared.plugins = [firstPlugin, secondPlugin]
        NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)

        XCTAssertEqual(listView.numberOfRows(in: NSTableView()), 2)
    }

    private func makePlugin(name: String, identifier: String, order: Int) -> Plugin {
        let json = """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": { "type": "url", "url": "https://example.com?q={text}" },
            "icon": "star",
            "order": \(order)
        }
        """
        let config = try! JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/\(identifier).openfireext"))
    }
}
