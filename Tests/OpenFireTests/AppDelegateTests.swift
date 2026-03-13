import XCTest
@testable import OpenFire

final class AppDelegateTests: XCTestCase {
    func testRadialMenuPluginsExcludesBuiltInPaste() throws {
        let paste = try makePlugin(
            name: "Paste",
            identifier: "com.openfire.builtin.paste",
            actionType: "paste"
        )
        let search = try makePlugin(
            name: "Search",
            identifier: "com.openfire.search",
            actionType: "url",
            actionContent: "\"url\":\"https://example.com?q={text}\""
        )

        let filtered = AppDelegate.radialMenuPlugins(from: [paste, search])

        XCTAssertEqual(filtered.map(\.id), ["com.openfire.search"])
    }

    func testRadialMenuPluginsKeepsNonPastePluginsInOrder() throws {
        let first = try makePlugin(
            name: "Copy",
            identifier: "com.openfire.copy",
            actionType: "copy"
        )
        let second = try makePlugin(
            name: "Reveal",
            identifier: "com.openfire.reveal-path",
            actionType: "reveal-path"
        )

        let filtered = AppDelegate.radialMenuPlugins(from: [first, second])

        XCTAssertEqual(filtered.map(\.id), ["com.openfire.copy", "com.openfire.reveal-path"])
    }

    private func makePlugin(name: String, identifier: String, actionType: String, actionContent: String? = nil) throws -> Plugin {
        let extraActionFields = actionContent.map { ",\($0)" } ?? ""
        let json = """
        {
            "name": "\(name)",
            "identifier": "\(identifier)",
            "action": {
                "type": "\(actionType)"\(extraActionFields)
            }
        }
        """

        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return Plugin(config: config, directoryURL: URL(fileURLWithPath: "/tmp/\(identifier)"))
    }
}
