import XCTest
@testable import OpenFire

final class PluginEditorWindowTests: XCTestCase {
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

    func testValidationAllowsExistingCorePluginToBeEdited() {
        let message = PluginEditorWindow.validationMessage(
            name: "Copy",
            identifier: "com.openfire.copy",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: true,
            existingPluginIDs: ["com.openfire.copy"]
        )

        XCTAssertNil(message)
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
}
