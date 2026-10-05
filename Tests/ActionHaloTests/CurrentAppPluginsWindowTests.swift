import Cocoa
import XCTest
@testable import ActionHalo

@MainActor
final class CurrentAppPluginsWindowTests: GlobalStateTestCase {
    private var changeCount = 0

    func testFilteredPluginCheckboxSupportsClickAccessibilityAndKeyboardWithoutDoubleToggle() throws {
        isolateStandardUserDefaults(keys: ["pluginOrder", PluginManager.perAppDisabledPluginsKey])
        let manager = PluginManager.shared
        let previousPlugins = manager.plugins
        defer { manager.plugins = previousPlugins }
        let first = try makePlugin(name: "Alpha", identifier: "com.test.alpha")
        let second = try makePlugin(name: "Beta", identifier: "com.test.beta")
        manager.plugins = [first, second]
        let controller = CurrentAppPluginsWindow(appName: "Test", bundleID: "com.test.app")
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSearchField }.first)
        let scrollView = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        search.stringValue = "Beta"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 1)

        NotificationCenter.default.addObserver(self, selector: #selector(pluginStateChanged),
                                               name: PluginManager.pluginsReloadedNotification, object: manager)
        defer { NotificationCenter.default.removeObserver(self) }

        let button = try checkbox(in: table)
        XCTAssertEqual(button.accessibilityLabel(), second.name)
        XCTAssertEqual(button.state, .on)
        button.performClick(nil)
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(manager.disabledPluginIDs(forAppBundleID: "com.test.app"), [second.id])
        XCTAssertEqual(try checkbox(in: table).state, .off)

        // Native accessibility performs the action even when its return value is
        // false in an offscreen AppKit session; verify the resulting model state.
        _ = try checkbox(in: table).accessibilityPerformPress()
        XCTAssertEqual(changeCount, 2)
        XCTAssertTrue(manager.disabledPluginIDs(forAppBundleID: "com.test.app").isEmpty)

        let keyboardButton = try checkbox(in: table)
        XCTAssertTrue(window.makeFirstResponder(keyboardButton))
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        keyboardButton.keyDown(with: space)
        XCTAssertEqual(changeCount, 3)
        XCTAssertEqual(manager.disabledPluginIDs(forAppBundleID: "com.test.app"), [second.id])
        XCTAssertTrue(first.isEnabled)
        XCTAssertTrue(second.isEnabled)
    }

    func testGloballyDisabledPluginCheckboxCannotCreateAnAppOverride() throws {
        isolateStandardUserDefaults(keys: ["pluginOrder", PluginManager.perAppDisabledPluginsKey])
        let manager = PluginManager.shared
        let previousPlugins = manager.plugins
        defer { manager.plugins = previousPlugins }
        let plugin = try makePlugin(name: "Disabled", identifier: "com.test.disabled")
        plugin.isEnabled = false
        manager.plugins = [plugin]
        let controller = CurrentAppPluginsWindow(appName: "Test", bundleID: "com.test.app")
        defer { controller.close() }
        let scrollView = try XCTUnwrap(controller.window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let button = try checkbox(in: table)

        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.state, .off)
        button.performClick(nil)
        // The action guard must also reject direct dispatch to a disabled row.
        NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button)
        XCTAssertFalse(plugin.isEnabled)
        XCTAssertTrue(manager.disabledPluginIDs(forAppBundleID: "com.test.app").isEmpty)
    }

    @objc private func pluginStateChanged() {
        changeCount += 1
    }

    private func checkbox(in table: NSTableView) throws -> NSButton {
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        return try XCTUnwrap(cell.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func makePlugin(name: String, identifier: String) throws -> Plugin {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data("""
        {"name":"\(name)","identifier":"\(identifier)","action":{"type":"url","url":"https://example.com/?q={text}"}}
        """.utf8))
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/\(identifier).actionhaloext"))
    }
}
