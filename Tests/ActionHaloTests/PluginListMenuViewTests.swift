import Cocoa
import XCTest
@testable import ActionHalo

final class PluginListMenuViewTests: GlobalStateTestCase {
    override func setUp() {
        super.setUp()
        isolateStandardUserDefaults(keys: ["pluginOrder"])
        PluginManager.shared.plugins.removeAll()
    }

    override func tearDown() {
        PluginManager.shared.plugins.removeAll()
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
            sourcePluginID: first.id,
            proposedRow: 3
        ))
        XCTAssertEqual(movedDown.plugins.map(\.id), ["com.test.second", "com.test.third", "com.test.first"])
        XCTAssertEqual(movedDown.targetRow, 2)

        let movedUp = try XCTUnwrap(PluginListMenuView.reorderedPlugins(
            [first, second, third],
            sourcePluginID: third.id,
            proposedRow: 0
        ))
        XCTAssertEqual(movedUp.plugins.map(\.id), ["com.test.third", "com.test.first", "com.test.second"])
        XCTAssertEqual(movedUp.targetRow, 0)
    }

    func testReorderedPluginsRejectsInvalidRows() {
        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1)
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2)
        let plugins = [first, second]

        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourcePluginID: "missing", proposedRow: 1))
        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourcePluginID: first.id, proposedRow: -1))
        XCTAssertNil(PluginListMenuView.reorderedPlugins(plugins, sourcePluginID: first.id, proposedRow: 3))
    }

    func testDragPreservesPluginIdentityAcrossReloadAndRejectsRemovedPlugin() throws {
        let first = makePlugin(name: "First", identifier: "com.test.first", order: 1)
        let second = makePlugin(name: "Second", identifier: "com.test.second", order: 2)
        let third = makePlugin(name: "Third", identifier: "com.test.third", order: 3)
        let listView = PluginListMenuView(frame: .zero)
        PluginManager.shared.plugins = [first, second, third]
        listView.reloadPlugins()
        let tableView = NSTableView()
        let payload = try XCTUnwrap(listView.tableView(tableView, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let sourcePluginID = try XCTUnwrap(payload.string(forType: .init("com.actionhalo.plugin-row")))
        XCTAssertEqual(sourcePluginID, first.id)

        // Another reload has moved the dragged plugin from row 0 to row 1.
        let reloaded = [second, first, third]
        let result = try XCTUnwrap(PluginListMenuView.reorderedPlugins(
            reloaded, sourcePluginID: sourcePluginID, proposedRow: 3
        ))
        XCTAssertEqual(result.sourceRow, 1)
        XCTAssertEqual(result.plugins.map(\.id), [second.id, third.id, first.id])
        XCTAssertNil(PluginListMenuView.reorderedPlugins(
            [second, third], sourcePluginID: sourcePluginID, proposedRow: 2
        ))
    }

    func testCoreAndInternalCommandPluginsCannotBeEditedFromPluginList() throws {
        let corePlugin = makePlugin(name: "Copy", identifier: "com.actionhalo.copy", order: 1)
        let customPlugin = makePlugin(name: "Custom", identifier: "com.test.custom", order: 2)
        let nativeConfig = try JSONDecoder().decode(PluginConfig.self, from: Data(
            #"{"name":"Telegram","identifier":"com.actionhalo.plugin.search-telegram","action":{"type":"native-command","command":"telegram-search"}}"#.utf8
        ))
        let nativePlugin = Plugin(config: nativeConfig, directoryURL: URL(fileURLWithPath: "/tmp/Telegram.actionhaloext"))

        XCTAssertFalse(PluginListMenuView.shouldAllowEditing(corePlugin))
        XCTAssertFalse(PluginListMenuView.shouldAllowEditing(nativePlugin))
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
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/\(identifier).actionhaloext"))
    }
}
