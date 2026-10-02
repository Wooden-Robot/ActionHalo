import Foundation
import XCTest
@testable import ActionHalo

final class PluginDeletionPromptTests: GlobalStateTestCase {
    private var rootURL: URL!
    private var builtInURL: URL { rootURL.appendingPathComponent("BuiltIn") }
    private var userURL: URL { rootURL.appendingPathComponent("User") }

    override func setUp() {
        super.setUp()
        isolateStandardUserDefaults(keys: ["deletedBuiltInPlugins"])
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        PluginManager.shared.userPluginsDirectoryOverride = userURL
    }

    override func tearDown() {
        PluginManager.shared.userPluginsDirectoryOverride = nil
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    func testUnmodifiedBuiltInOffersDeletionWithHiddenPluginExplanation() throws {
        let plugin = try makePlugin(in: builtInURL, packageName: "BuiltIn", identifier: "com.test.built-in")
        let prompt = PluginDeletionPrompt(plugin: plugin, builtInPluginsURL: builtInURL)

        XCTAssertEqual(prompt, .hideBuiltIn)
        XCTAssertEqual(prompt.buttonTitle, "Delete".localized)
        XCTAssertEqual(prompt.title, "Delete Built-in Plugin?".localized)
        XCTAssertEqual(prompt.confirmationTitle, "Confirm Delete".localized)
        XCTAssertEqual(prompt.message, "Are you sure you want to delete this built-in plugin? It will still exist but will be hidden from the list.".localized)
    }

    func testUserOverrideFindsBuiltInByIdentifierAndOffersRestoreDefault() throws {
        let builtIn = try makePlugin(in: builtInURL, packageName: "Original Name", identifier: "com.test.built-in")
        let override = try makePlugin(in: userURL, packageName: "Renamed Override", identifier: builtIn.id)

        XCTAssertEqual(
            PluginManager.builtInPluginURL(for: override.id, in: builtInURL)?.resolvingSymlinksInPath().path,
            builtIn.directoryURL.resolvingSymlinksInPath().path
        )
        // Both the loaded override and an editor opened before the override was saved must agree.
        for plugin in [override, builtIn] {
            let prompt = PluginDeletionPrompt(plugin: plugin, builtInPluginsURL: builtInURL)
            XCTAssertEqual(prompt, .restoreDefault)
            XCTAssertEqual(prompt.buttonTitle, "Restore Default".localized)
            XCTAssertEqual(prompt.title, "Restore Default?".localized)
            XCTAssertEqual(prompt.confirmationTitle, "Restore Default".localized)
            XCTAssertEqual(prompt.message, "Are you sure you want to delete your modifications to this plugin? It will be restored to the built-in default state.".localized)
        }
    }

    func testCustomUserPluginOffersPermanentDeletionDespiteMatchingPackageName() throws {
        _ = try makePlugin(in: builtInURL, packageName: "Same Name", identifier: "com.test.built-in")
        let plugin = try makePlugin(in: userURL, packageName: "Same Name", identifier: "com.test.custom")
        let prompt = PluginDeletionPrompt(plugin: plugin, builtInPluginsURL: builtInURL)

        XCTAssertEqual(prompt, .delete)
        XCTAssertEqual(prompt.buttonTitle, "Delete".localized)
        XCTAssertEqual(prompt.title, "Delete Plugin?".localized)
        XCTAssertEqual(prompt.confirmationTitle, "Confirm Delete".localized)
        XCTAssertEqual(prompt.message, "Are you sure you want to completely delete this plugin? This action is irreversible.".localized)
    }

    func testOverrideOfPreviouslyHiddenBuiltInDoesNotPromiseToRestoreIt() throws {
        let builtIn = try makePlugin(in: builtInURL, packageName: "Original", identifier: "com.test.built-in")
        let override = try makePlugin(in: userURL, packageName: "Override", identifier: builtIn.id)
        UserDefaults.standard.set([builtIn.id], forKey: "deletedBuiltInPlugins")

        XCTAssertEqual(PluginDeletionPrompt(plugin: override, builtInPluginsURL: builtInURL), .delete)
    }

    private func makePlugin(in directory: URL, packageName: String, identifier: String) throws -> Plugin {
        let packageURL = directory.appendingPathComponent(packageName + ".actionhaloext")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let config = """
        {"name":"Test","identifier":"\(identifier)","action":{"type":"copy"}}
        """
        try config.write(to: packageURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PluginLoader.load(from: packageURL, source: .bundled))
    }
}
