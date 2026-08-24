import AppKit
import XCTest
@testable import ActionHalo

final class PluginEditorWindowTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testDirtyStateKeepsEditsMadeAfterAsyncSaveCheckpoint() {
        var state = PluginEditorDirtyState()
        XCTAssertFalse(state.hasUnsavedChanges)

        state.recordUserEdit()
        let saveCheckpoint = state.currentRevision
        state.recordUserEdit()
        state.recordPersistenceSuccess(through: saveCheckpoint)

        XCTAssertTrue(state.hasUnsavedChanges)

        state.recordPersistenceSuccess(through: state.currentRevision)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    @MainActor
    func testEditorStartsCleanAndProgrammaticPresentationRefreshDoesNotMarkDirty() {
        let editor = PluginEditorWindow()

        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.isDocumentEdited)

        editor.refreshTypePresentation()

        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.isDocumentEdited)
        editor.close()
    }

    @MainActor
    func testEditorTextChangeMarksDirtyAndExplicitDiscardClearsIt() {
        let editor = PluginEditorWindow()

        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.isDocumentEdited)

        editor.discardUnsavedChanges()

        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.isDocumentEdited)
        editor.close()
    }

    @MainActor
    func testTypeIconAndShortcutUserActionsMarkEditorDirty() throws {
        let editor = PluginEditorWindow()
        let contentView = try XCTUnwrap(editor.contentView)
        let popUps = contentView.subviews.compactMap { $0 as? NSPopUpButton }
        let typePopUp = try XCTUnwrap(
            popUps.first { $0.itemTitles.contains("Simulate Key Combo".localized) }
        )
        let iconPopUp = try XCTUnwrap(
            popUps.first { $0.itemTitles.contains("bolt.fill") }
        )

        typePopUp.selectItem(at: 1)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(typePopUp.sendAction(typePopUp.action, to: typePopUp.target))
        XCTAssertTrue(editor.hasUnsavedChanges)

        editor.discardUnsavedChanges()
        iconPopUp.selectItem(at: max(0, iconPopUp.numberOfItems - 1))
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(iconPopUp.sendAction(iconPopUp.action, to: iconPopUp.target))
        XCTAssertTrue(editor.hasUnsavedChanges)

        editor.discardUnsavedChanges()
        typePopUp.selectItem(at: 3)
        XCTAssertTrue(typePopUp.sendAction(typePopUp.action, to: typePopUp.target))
        editor.discardUnsavedChanges()
        let shortcutField = try XCTUnwrap(
            contentView.subviews.compactMap { $0 as? ShortcutRecorderField }.first
        )
        let event = try makeKeyDownEvent(
            modifiers: [.command, .shift],
            characters: "k",
            keyCode: 0x28
        )

        XCTAssertTrue(shortcutField.becomeFirstResponder())
        shortcutField.keyDown(with: event)

        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.isDocumentEdited)
        editor.close()
    }

    @MainActor
    func testShortcutRecorderWritesNewCombinationToRawValue() throws {
        let recorder = ShortcutRecorderField(frame: .zero)
        let event = try makeKeyDownEvent(
            modifiers: [.command, .shift],
            characters: "k",
            keyCode: 0x28
        )

        XCTAssertTrue(recorder.becomeFirstResponder())
        recorder.keyDown(with: event)

        XCTAssertEqual(recorder.rawComboString, "Shift+Command+K")
    }

    @MainActor
    func testShortcutRecorderReplacesExistingCombinationWhenRerecorded() throws {
        let recorder = ShortcutRecorderField(frame: .zero)
        recorder.stringValue = "Command+Q"
        let event = try makeKeyDownEvent(
            modifiers: [.option],
            characters: "r",
            keyCode: 0x0F
        )

        XCTAssertTrue(recorder.becomeFirstResponder())
        recorder.keyDown(with: event)

        XCTAssertEqual(recorder.rawComboString, "Option+R")
    }

    @MainActor
    func testGlobalShortcutRecorderStillReportsCarbonValues() throws {
        let recorder = ShortcutRecorderField(frame: .zero)
        recorder.requiresGlobalHotkeyModifier = true
        var recordedKeyCode: UInt32?
        var recordedModifiers: UInt32?
        recorder.onKeyComboRecorded = { keyCode, modifiers in
            recordedKeyCode = keyCode
            recordedModifiers = modifiers
        }
        let event = try makeKeyDownEvent(
            modifiers: [.command, .control],
            characters: "k",
            keyCode: 0x28
        )

        XCTAssertTrue(recorder.becomeFirstResponder())
        recorder.keyDown(with: event)

        XCTAssertEqual(recordedKeyCode, 0x28)
        XCTAssertEqual(recordedModifiers, 0x1100)
    }

    func testValidationRejectsReservedCorePluginIdentifiersForNewPlugins() {
        let message = PluginEditorWindow.validationMessage(
            name: "Fake Copy",
            identifier: "com.actionhalo.copy",
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
            identifier: "com.actionhalo.copy",
            typeIndex: 1,
            content: "echo hi",
            isEditingExistingPlugin: true,
            existingPluginIDs: ["com.actionhalo.copy"],
            originalIdentifier: "com.actionhalo.copy"
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

    func testEditableScriptContentRejectsTraversalOutsidePluginPackage() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"../outside.sh"}}"#
        )
        let outsideURL = bundleURL.deletingLastPathComponent().appendingPathComponent("outside.sh")
        temporaryDirectories.append(outsideURL)
        try "external secret".write(to: outsideURL, atomically: true, encoding: .utf8)
        let action = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"../outside.sh"}}"#.utf8
            )
        ).action

        XCTAssertNil(
            PluginEditorWindow.editableScriptContent(
                for: action,
                pluginDirectoryURL: bundleURL
            )
        )
    }

    func testEditableScriptContentRejectsSymbolicLinkEscape() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#
        )
        let outsideURL = bundleURL.deletingLastPathComponent().appendingPathComponent("outside.sh")
        temporaryDirectories.append(outsideURL)
        try "external secret".write(to: outsideURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: bundleURL.appendingPathComponent("script.sh"),
            withDestinationURL: outsideURL
        )
        let action = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#.utf8
            )
        ).action

        XCTAssertNil(
            PluginEditorWindow.editableScriptContent(
                for: action,
                pluginDirectoryURL: bundleURL
            )
        )
    }

    func testEditableScriptContentRejectsFilesOverEditorLimit() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#
        )
        try "12345".write(
            to: bundleURL.appendingPathComponent("script.sh"),
            atomically: true,
            encoding: .utf8
        )
        let action = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#.utf8
            )
        ).action

        XCTAssertNil(
            PluginEditorWindow.editableScriptContent(
                for: action,
                pluginDirectoryURL: bundleURL,
                maximumFileBytes: 4
            )
        )
    }

    func testEditableScriptContentRejectsInlineSourceOverEditorLimit() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Inline","identifier":"com.test.inline","action":{"type":"shell-script","inline":"12345"}}"#
        )
        let action = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Inline","identifier":"com.test.inline","action":{"type":"shell-script","inline":"12345"}}"#.utf8
            )
        ).action

        XCTAssertNil(
            PluginEditorWindow.editableScriptContent(
                for: action,
                pluginDirectoryURL: bundleURL,
                maximumFileBytes: 4
            )
        )
    }

    func testEditableScriptContentLoadsPackageFileAndInlineFallback() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#
        )
        try "echo package".write(
            to: bundleURL.appendingPathComponent("script.sh"),
            atomically: true,
            encoding: .utf8
        )
        let fileAction = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#.utf8
            )
        ).action
        let inlineAction = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(
                #"{"name":"Inline","identifier":"com.test.inline","action":{"type":"shell-script","inline":"echo inline"}}"#.utf8
            )
        ).action

        XCTAssertEqual(
            PluginEditorWindow.editableScriptContent(
                for: fileAction,
                pluginDirectoryURL: bundleURL
            ),
            "echo package"
        )
        XCTAssertEqual(
            PluginEditorWindow.editableScriptContent(
                for: inlineAction,
                pluginDirectoryURL: bundleURL
            ),
            "echo inline"
        )
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

    func testMergedConfigPreservesUnknownFieldsLocalesAndActionMetadata() throws {
        let existing: [String: Any] = [
            "name": "Old",
            "identifier": "com.test.preserve",
            "author": "Original Author",
            "version": "2.0",
            "customMetadata": ["channel": "stable"],
            "localizedNames": ["en": "Old English", "zh-Hans": "保留名称"],
            "localizedDescriptions": ["en": "Old Description", "zh-Hans": "保留描述"],
            "action": [
                "type": "shell-script",
                "script": "old.sh",
                "customActionMetadata": "keep",
            ],
        ]

        let merged = PluginEditorWindow.mergedConfigDictionary(
            preserving: existing,
            name: "New",
            englishName: "New English",
            description: "New Description",
            englishDescription: "New English Description",
            identifier: "com.test.preserve",
            icon: "star",
            actionUpdates: [
                "type": "url",
                "url": "https://example.com?q={text}",
            ]
        )
        let localizedNames = try XCTUnwrap(
            merged["localizedNames"] as? [String: String]
        )
        let localizedDescriptions = try XCTUnwrap(
            merged["localizedDescriptions"] as? [String: String]
        )
        let action = try XCTUnwrap(merged["action"] as? [String: Any])

        XCTAssertEqual(merged["author"] as? String, "Original Author")
        XCTAssertEqual(merged["version"] as? String, "2.0")
        XCTAssertEqual(
            (merged["customMetadata"] as? [String: String])?["channel"],
            "stable"
        )
        XCTAssertEqual(localizedNames["zh-Hans"], "保留名称")
        XCTAssertEqual(localizedNames["en"], "New English")
        XCTAssertEqual(localizedDescriptions["zh-Hans"], "保留描述")
        XCTAssertEqual(localizedDescriptions["en"], "New English Description")
        XCTAssertEqual(action["customActionMetadata"] as? String, "keep")
        XCTAssertEqual(action["type"] as? String, "url")
        XCTAssertEqual(action["url"] as? String, "https://example.com?q={text}")
        XCTAssertNil(action["script"])
    }

    func testWritePluginPackageAtomicallyRejectsSymbolicLinkTemplate() throws {
        let realTemplateURL = try makePluginPackage(
            config: #"{"name":"Real","identifier":"com.test.real","action":{"type":"copy"}}"#
        )
        let symbolicLinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".actionhaloext")
        temporaryDirectories.append(symbolicLinkURL)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: realTemplateURL
        )
        let destinationParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(destinationParent)
        let destinationURL = destinationParent.appendingPathComponent(
            "com.test.saved.actionhaloext"
        )

        XCTAssertThrowsError(
            try PluginEditorWindow.writePluginPackageAtomically(
                bundleURL: destinationURL,
                templateURL: symbolicLinkURL,
                configData: Data(
                    #"{"name":"Saved","identifier":"com.test.saved","action":{"type":"copy"}}"#.utf8
                ),
                scriptFileName: nil,
                scriptContent: nil,
                customIconSourceURL: nil,
                shouldKeepCustomIcon: false
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testWritePluginPackageAtomicallyRejectsInvalidFinalConfiguration() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Old","identifier":"com.test.valid","action":{"type":"copy"}}"#
        )

        XCTAssertThrowsError(
            try PluginEditorWindow.writePluginPackageAtomically(
                bundleURL: bundleURL,
                templateURL: bundleURL,
                configData: Data(
                    #"{"name":"Unsafe","identifier":"../outside","action":{"type":"copy"}}"#.utf8
                ),
                scriptFileName: nil,
                scriptContent: nil,
                customIconSourceURL: nil,
                shouldKeepCustomIcon: false
            )
        )

        XCTAssertEqual(PluginLoader.load(from: bundleURL)?.id, "com.test.valid")
    }

    private func makePluginPackage(config: String) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".actionhaloext")
        temporaryDirectories.append(bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try config.write(to: bundleURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        return bundleURL
    }

    @MainActor
    private func makeKeyDownEvent(
        modifiers: NSEvent.ModifierFlags,
        characters: String,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}
