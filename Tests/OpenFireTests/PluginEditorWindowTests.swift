import XCTest
@testable import OpenFire

final class PluginEditorWindowTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testValidationRejectsReservedCorePluginIdentifiersForNewPlugins() {
        let message = PluginEditorWindow.validationMessage(
            name: "Fake Copy",
            identifier: "com.openfire.copy",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: false,
            existingPluginIDs: []
        )

        XCTAssertEqual(message, "Identifier is reserved for a built-in plugin.".localized)
    }

    func testValidationRejectsExistingCorePluginEdits() {
        let message = PluginEditorWindow.validationMessage(
            name: "Copy",
            identifier: "com.openfire.copy",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: true,
            existingPluginIDs: ["com.openfire.copy"],
            originalIdentifier: "com.openfire.copy"
        )

        XCTAssertEqual(
            message,
            "Core plugins cannot be edited. Disable them instead if you do not want to use them.".localized
        )
    }

    func testValidationAllowsExistingCustomPluginToKeepIdentifier() {
        let message = PluginEditorWindow.validationMessage(
            name: "Keep",
            identifier: "com.test.keep",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: true,
            existingPluginIDs: ["com.test.keep", "com.test.other"],
            originalIdentifier: "com.test.keep"
        )

        XCTAssertNil(message)
    }

    func testValidationRejectsChangingExistingCustomPluginIdentifier() {
        let message = PluginEditorWindow.validationMessage(
            name: "Keep",
            identifier: "com.test.other",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: true,
            existingPluginIDs: ["com.test.keep", "com.test.other"],
            originalIdentifier: "com.test.keep"
        )

        XCTAssertEqual(message, "Identifier cannot be changed after the plugin is created.".localized)
    }

    func testValidationRejectsDuplicatePluginIdentifiersForNewPlugins() {
        let message = PluginEditorWindow.validationMessage(
            name: "Duplicate",
            identifier: "com.test.duplicate",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: false,
            existingPluginIDs: ["com.test.duplicate"]
        )

        XCTAssertEqual(message, "A plugin with this identifier already exists".localized)
    }

    func testValidationAllowsSimpleCustomPluginIdentifiers() {
        let message = PluginEditorWindow.validationMessage(
            name: "Book",
            identifier: "book",
            typeIndex: 0,
            content: "https://example.com?q={text}",
            isEditingExistingPlugin: false,
            existingPluginIDs: []
        )

        XCTAssertNil(message)
    }

    func testValidationAllowsHyphenatedSimpleCustomPluginIdentifiers() {
        let message = PluginEditorWindow.validationMessage(
            name: "Z-Lib",
            identifier: "z-lib",
            typeIndex: 0,
            content: "https://z-library.sk/s/{text}",
            isEditingExistingPlugin: false,
            existingPluginIDs: []
        )

        XCTAssertNil(message)
    }

    func testValidationRejectsIdentifiersThatWouldCreateHiddenPluginPackages() {
        let message = PluginEditorWindow.validationMessage(
            name: "Book",
            identifier: ".book",
            typeIndex: 0,
            content: "https://example.com?q={text}",
            isEditingExistingPlugin: false,
            existingPluginIDs: []
        )

        XCTAssertEqual(message, "Identifier cannot start or end with dots or hyphens.".localized)
    }

    func testWritePluginPackageAtomicallyReplacesConfigAndPreservesExtraFiles() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Old","identifier":"com.test.plugin","action":{"type":"shell-script","script":"script.sh"}}"#
        )
        try "old script".write(to: bundleURL.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
        try "extra".write(to: bundleURL.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)

        let newConfig = Data(#"{"name":"New","identifier":"com.test.plugin","action":{"type":"shell-script","script":"script.sh"}}"#.utf8)

        try PluginEditorWindow.writePluginPackageAtomically(
            bundleURL: bundleURL,
            templateURL: bundleURL,
            configData: newConfig,
            scriptFileName: "script.sh",
            scriptContent: "new script",
            customIconSourceURL: nil,
            shouldKeepCustomIcon: false
        )

        let configData = try Data(contentsOf: bundleURL.appendingPathComponent("Config.json"))
        let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
        let script = try String(contentsOf: bundleURL.appendingPathComponent("script.sh"), encoding: .utf8)

        XCTAssertEqual(config.name, "New")
        XCTAssertEqual(script, "new script")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("extra.txt").path))
    }

    func testWritePluginPackageAtomicallyPreservesExistingCustomIconWhenNoNewIconIsSelected() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Icon","identifier":"com.test.icon","icon":"bolt.fill","action":{"type":"copy"}}"#
        )
        let iconURL = bundleURL.appendingPathComponent("icon.png")
        try Data([1, 2, 3]).write(to: iconURL)

        let newConfig = Data(#"{"name":"Icon 2","identifier":"com.test.icon","icon":"bolt.fill","action":{"type":"copy"}}"#.utf8)

        try PluginEditorWindow.writePluginPackageAtomically(
            bundleURL: bundleURL,
            templateURL: bundleURL,
            configData: newConfig,
            scriptFileName: nil,
            scriptContent: nil,
            customIconSourceURL: nil,
            shouldKeepCustomIcon: true
        )

        XCTAssertEqual(try Data(contentsOf: iconURL), Data([1, 2, 3]))
    }

    private func makePluginPackage(config: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".openfireext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try config.write(to: bundleURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        return bundleURL
    }
}
