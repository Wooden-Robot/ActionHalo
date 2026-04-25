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
}
