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

    func testReorderedPluginsMovesRowsUsingTableDropSemantics() throws {
        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1)
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2)
        let third = makePlugin(name: "Third", identifier: "com.test.third", order: 3)

        let movedDown = try XCTUnwrap(PluginListMenuView.reorderedPlugins(
            [first, second, third],
            sourceRow: 0,
            proposedRow: 3
        ))
        XCTAssertEqual(movedDown.plugins.map(\.id), ["com.test.second", "com.test.third", "com.test.first"])
        XCTAssertEqual(movedDown.targetRow, 2)

        let movedUp = try XCTUnwrap(PluginListMenuView.reorderedPlugins(
            [first, second, third],
            sourceRow: 2,
            proposedRow: 0
        ))
        XCTAssertEqual(movedUp.plugins.map(\.id), ["com.test.third", "com.test.first", "com.test.second"])
        XCTAssertEqual(movedUp.targetRow, 0)
    }

    func testReorderedPluginsRejectsInvalidRows() {
        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1)
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2)
        let plugins = [first, second]

        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourceRow: -1, proposedRow: 1))
        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourceRow: 2, proposedRow: 1))
        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourceRow: 0, proposedRow: -1))
        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourceRow: 0, proposedRow: 3))
    }

    func testCorePluginsCannotBeEditedFromPluginList() {
        let corePlugin = makePlugin(name: "Copy", identifier: "com.openfire.copy", order: 1)
        let customPlugin = makePlugin(name: "Custom", identifier: "com.test.custom", order: 2)

        XCTAssertFalse(PluginListMenuView.shouldAllowEditing(corePlugin))
        XCTAssertTrue(PluginListMenuView.shouldAllowEditing(customPlugin))
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
