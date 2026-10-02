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
    func testEditorCloseRequiresExplicitDiscardOfUnsavedChanges() {
        let editor = PluginEditorWindow()
        defer { editor.close() }
        XCTAssertTrue(editor.delegate === editor)
        XCTAssertTrue(editor.confirmClose {
            XCTFail("A clean editor must close without prompting")
            return false
        })

        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(editor.confirmClose { false })
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.isDocumentEdited)

        XCTAssertTrue(editor.confirmClose { true })
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.isDocumentEdited)
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
    func testSwitchingToNativeActionsAndBackPreservesUnsavedScript() throws {
        let editor = PluginEditorWindow()
        defer { editor.close() }
        let contentView = try XCTUnwrap(editor.contentView)
        let typePopUp = try XCTUnwrap(contentView.subviews.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Simulate Key Combo".localized) })
        let scrollView = try XCTUnwrap(contentView.subviews.compactMap { $0 as? NSScrollView }.first)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)

        typePopUp.selectItem(at: 1)
        XCTAssertTrue(typePopUp.sendAction(typePopUp.action, to: typePopUp.target))
        textView.string = "echo unsaved-work"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        for nativeIndex in 4...6 {
            typePopUp.selectItem(at: nativeIndex)
            XCTAssertTrue(typePopUp.sendAction(typePopUp.action, to: typePopUp.target))
            XCTAssertTrue(scrollView.isHidden)

            typePopUp.selectItem(at: 1)
            XCTAssertTrue(typePopUp.sendAction(typePopUp.action, to: typePopUp.target))
            XCTAssertFalse(scrollView.isHidden)
            XCTAssertTrue(textView.isEditable)
            XCTAssertEqual(textView.string, "echo unsaved-work")
            XCTAssertTrue(editor.hasUnsavedChanges)
        }
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
    func testRecordedShortcutsRoundTripThroughSavedAction() throws {
        let recorder = ShortcutRecorderField(frame: .zero)
        for (characters, keyCode, expectedKey): (String, UInt16, String) in [
            ("+", 0x18, "="), ("?", 0x2C, "/"), ("!", 0x12, "1"),
            ("K", 0x28, "k"), (" ", 0x31, "space"), ("\u{1B}", 0x35, "esc")
        ] {
            XCTAssertTrue(recorder.becomeFirstResponder())
            recorder.keyDown(with: try makeKeyDownEvent(
                modifiers: [.command, .shift], characters: characters, keyCode: keyCode
            ))
            let data = try JSONSerialization.data(withJSONObject:
                PluginEditorWindow.keyComboActionUpdates(from: recorder.rawComboString)
            )
            let config = try JSONDecoder().decode(PluginActionConfig.self, from: data)
            let combo = try XCTUnwrap(PluginKeyCombo(key: config.key, modifiers: config.modifiers))
            XCTAssertEqual(config.key, expectedKey)
            XCTAssertEqual(combo.keyCode, keyCode)
            XCTAssertEqual(combo.modifierFlags, [.maskCommand, .maskShift])
            XCTAssertNotNil(PluginAction(config: config, allowNativeCommands: false))
        }

        let savedCombo = recorder.rawComboString
        recorder.keyDown(with: try makeKeyDownEvent(
            modifiers: [.command], characters: "x", keyCode: 0xFF // Unknown virtual key code.
        ))
        XCTAssertEqual(recorder.rawComboString, savedCombo)
    }

    @MainActor
    func testFunctionKeysCanBeRecordedAndExecuted() throws {
        let keyCodes: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
        ]
        for globalHotkey in [false, true] {
            for (index, keyCode) in keyCodes.enumerated() {
                let recorder = ShortcutRecorderField(frame: .zero)
                recorder.requiresGlobalHotkeyModifier = globalHotkey
                var recordedCode: UInt32?
                recorder.onKeyComboRecorded = { keyCode, _ in recordedCode = keyCode }
                XCTAssertTrue(recorder.becomeFirstResponder())
                recorder.keyDown(with: try makeKeyDownEvent(
                    modifiers: [.control],
                    characters: String(UnicodeScalar(0xF704 + index)!), keyCode: keyCode
                ))

                XCTAssertEqual(recordedCode, UInt32(keyCode))
                XCTAssertEqual(recorder.rawComboString, "Control+F\(index + 1)")
                let action = PluginEditorWindow.keyComboActionUpdates(from: recorder.rawComboString)
                XCTAssertEqual(PluginKeyCombo(key: action["key"] as? String, modifiers: ["Control"])?.keyCode, keyCode)
            }
        }
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

        recorder.keyDown(with: try makeKeyDownEvent(
            modifiers: [.command, .shift], characters: "+", keyCode: 0x18
        ))
        XCTAssertEqual(recordedKeyCode, 0x18)
        XCTAssertEqual(recordedModifiers, 0x0300)
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

    func testScriptSavePreservesOriginalEntryPointAndAuxiliaryFiles() throws {
        for (typeIndex, actionType, fileExtension) in [
            (1, "shell-script", "sh"),
            (2, "applescript", "applescript"),
        ] {
            let originalReference = "scripts/main.\(fileExtension)"
            let bundleURL = try makePluginPackage(config: """
                {"name":"Old","identifier":"com.test.original","action":{"type":"\(actionType)","script":"\(originalReference)"}}
                """)
            try FileManager.default.createDirectory(
                at: bundleURL.appendingPathComponent("scripts"),
                withIntermediateDirectories: true
            )
            try "old entry".write(to: bundleURL.appendingPathComponent(originalReference), atomically: true, encoding: .utf8)
            let helperURL = bundleURL.appendingPathComponent("script.\(fileExtension)")
            try "keep helper".write(to: helperURL, atomically: true, encoding: .utf8)
            var config = PluginEditorWindow.existingConfigDictionary(from: bundleURL)
            let scriptName = try XCTUnwrap(PluginEditorWindow.scriptFileName(
                for: typeIndex,
                existingConfig: config,
                directoryURL: bundleURL
            ))
            XCTAssertEqual(scriptName, originalReference)
            config["name"] = "Renamed"
            config["action"] = ["type": actionType, "script": scriptName]

            try PluginEditorWindow.writePluginPackageAtomically(
                bundleURL: bundleURL,
                templateURL: bundleURL,
                configData: JSONSerialization.data(withJSONObject: config),
                scriptFileName: scriptName,
                scriptContent: "edited entry",
                customIconSourceURL: nil,
                shouldKeepCustomIcon: false
            )

            XCTAssertEqual(PluginLoader.load(from: bundleURL)?.config.action.script, originalReference)
            XCTAssertEqual(try String(contentsOf: bundleURL.appendingPathComponent(originalReference), encoding: .utf8), "edited entry")
            XCTAssertEqual(try String(contentsOf: helperURL, encoding: .utf8), "keep helper")
        }
    }

    func testInlineScriptSaveAvoidsExistingFilesAndRejectsUnsafeOverwrites() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Inline","identifier":"com.test.inline","action":{"type":"shell-script","inline":"echo inline"}}"#
        )
        let helperURL = bundleURL.appendingPathComponent("script.sh")
        try "keep helper".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("script-2.sh"),
            withIntermediateDirectories: true
        )
        let config = PluginEditorWindow.existingConfigDictionary(from: bundleURL)
        let scriptName = try XCTUnwrap(PluginEditorWindow.scriptFileName(
            for: 1,
            existingConfig: config,
            directoryURL: bundleURL
        ))
        XCTAssertEqual(scriptName, "script-3.sh")

        // A file can appear after the editor chose an unused name.
        let lateFileURL = bundleURL.appendingPathComponent(scriptName)
        try "keep late file".write(to: lateFileURL, atomically: true, encoding: .utf8)
        for unsafeName in [scriptName, "script.sh", "../outside.sh"] {
            var updatedConfig = config
            updatedConfig["action"] = ["type": "shell-script", "script": unsafeName]
            XCTAssertThrowsError(try PluginEditorWindow.writePluginPackageAtomically(
                bundleURL: bundleURL,
                templateURL: bundleURL,
                configData: JSONSerialization.data(withJSONObject: updatedConfig),
                scriptFileName: unsafeName,
                scriptContent: "echo edited",
                customIconSourceURL: nil,
                shouldKeepCustomIcon: false
            ))
        }
        XCTAssertEqual(try String(contentsOf: lateFileURL, encoding: .utf8), "keep late file")
        XCTAssertEqual(try String(contentsOf: helperURL, encoding: .utf8), "keep helper")
        XCTAssertEqual(PluginLoader.load(from: bundleURL)?.config.action.inline, "echo inline")

        try FileManager.default.removeItem(at: lateFileURL)
        var updatedConfig = config
        updatedConfig["action"] = ["type": "shell-script", "script": scriptName]
        try PluginEditorWindow.writePluginPackageAtomically(
            bundleURL: bundleURL,
            templateURL: bundleURL,
            configData: JSONSerialization.data(withJSONObject: updatedConfig),
            scriptFileName: scriptName,
            scriptContent: "echo edited",
            customIconSourceURL: nil,
            shouldKeepCustomIcon: false
        )
        XCTAssertEqual(try String(contentsOf: lateFileURL, encoding: .utf8), "echo edited")
        XCTAssertEqual(try String(contentsOf: helperURL, encoding: .utf8), "keep helper")
        XCTAssertEqual(PluginLoader.load(from: bundleURL)?.config.action.script, scriptName)
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

final class PluginEditorPersistenceTests: GlobalStateTestCase {
    private var rootURL: URL!
    private var previousUserPluginsURL: URL?
    private var previousPlugins: [Plugin] = []

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        previousUserPluginsURL = PluginManager.shared.userPluginsDirectoryOverride
        previousPlugins = PluginManager.shared.plugins
        PluginManager.shared.userPluginsDirectoryOverride = rootURL
    }

    override func tearDown() {
        PluginManager.shared.userPluginsDirectoryOverride = previousUserPluginsURL
        PluginManager.shared.plugins = previousPlugins
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    @MainActor
    func testSavingBlocksDeletionAndKeepsLaterDraftEdits() throws {
        let (editor, plugin, saveButton, deleteButton) = try makeEditor()
        defer { editor.close() }
        let reload = expectation(forNotification: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)

        XCTAssertTrue(saveButton.sendAction(saveButton.action, to: saveButton.target))
        XCTAssertFalse(saveButton.isEnabled)
        XCTAssertFalse(deleteButton.isEnabled)
        XCTAssertFalse(editor.confirmClose { true })
        editor.deletePluginAfterConfirmation(plugin)
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        wait(for: [reload], timeout: 5)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directoryURL.path))
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertTrue(deleteButton.isEnabled)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    @MainActor
    func testDeletingBlocksSavingAndRepeatedDeletion() throws {
        let (editor, plugin, saveButton, deleteButton) = try makeEditor()
        defer { editor.close() }
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let reload = expectation(forNotification: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)

        editor.deletePluginAfterConfirmation(plugin)
        XCTAssertFalse(saveButton.isEnabled)
        XCTAssertFalse(deleteButton.isEnabled)
        XCTAssertFalse(editor.confirmClose { true })
        XCTAssertTrue(saveButton.sendAction(saveButton.action, to: saveButton.target))
        editor.deletePluginAfterConfirmation(plugin)

        wait(for: [reload], timeout: 5)
        // The reload and deletion completion are separately queued on the main actor.
        let deadline = Date().addingTimeInterval(5)
        while !editor.confirmClose(discardChanges: { false }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.directoryURL.path))
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.confirmClose { false })
    }

    @MainActor
    private func makeEditor() throws -> (PluginEditorWindow, Plugin, NSButton, NSButton) {
        let packageURL = rootURL.appendingPathComponent("Persistence.actionhaloext")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try #"{"name":"Persistence","identifier":"com.test.editor-persistence","action":{"type":"copy"}}"#
            .write(to: packageURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        let plugin = try XCTUnwrap(PluginLoader.load(from: packageURL))
        PluginManager.shared.plugins = [plugin]
        let editor = PluginEditorWindow(plugin: plugin)
        let buttons = try XCTUnwrap(editor.contentView).subviews.compactMap { $0 as? NSButton }
        let saveButton = try XCTUnwrap(buttons.first { $0.title == "Save".localized })
        let deleteButton = try XCTUnwrap(buttons.first { $0.title == "Delete".localized })
        return (editor, plugin, saveButton, deleteButton)
    }
}
