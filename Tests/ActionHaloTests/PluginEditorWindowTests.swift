import AppKit
import XCTest
@testable import ActionHalo

private class WritableRootMoveFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        let permissions = try attributesOfItem(atPath: sourceURL.path)[.posixPermissions] as! Int
        guard permissions & 0o200 != 0 else { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}

private final class FailingEditorCommitFileManager: WritableRootMoveFileManager, @unchecked Sendable {
    private(set) var didRejectCommit = false

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.lastPathComponent.hasPrefix(".save-") {
            didRejectCommit = true
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}

private final class FailingMovedPermissionsFileManager: WritableRootMoveFileManager, @unchecked Sendable {
    let failOnBackup: Bool
    let keepRejectingPermissions: Bool
    let rejectRollback: Bool
    private(set) var didRejectPermissions = false
    private(set) var rejectedPermissionAttempts = 0
    private(set) var didRejectRollback = false
    private var movedDestination: String?

    init(failOnBackup: Bool, keepRejectingPermissions: Bool = false, rejectRollback: Bool = false) {
        self.failOnBackup = failOnBackup
        self.keepRejectingPermissions = keepRejectingPermissions
        self.rejectRollback = rejectRollback
        super.init()
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if rejectRollback, didRejectPermissions, sourceURL.lastPathComponent.hasPrefix(".backup-") {
            didRejectRollback = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
        movedDestination = destinationURL.path
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if attributes[.posixPermissions] as? Int == 0o555,
           movedDestination == path,
           URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".backup-") == failOnBackup,
           !didRejectPermissions || keepRejectingPermissions {
            didRejectPermissions = true
            rejectedPermissionAttempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

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

    func testEditableUnicodeScriptsKeepByteLimitAndRejectInvalidEncoding() throws {
        let bundleURL = try makePluginPackage(
            config: #"{"name":"Script","identifier":"com.test.script","action":{"type":"shell-script","script":"script.sh"}}"#
        )
        let scriptURL = bundleURL.appendingPathComponent("script.sh")
        for encoding in [String.Encoding.utf16, .utf32] {
            for text in ["printf '中文😀'", ""] {
                let data = try XCTUnwrap(text.data(using: encoding))
                try data.write(to: scriptURL)
                let action = try XCTUnwrap(PluginLoader.load(from: bundleURL)).config.action
                XCTAssertEqual(PluginEditorWindow.editableScriptContent(
                    for: action, pluginDirectoryURL: bundleURL, maximumFileBytes: data.count
                ), text)
                XCTAssertNil(PluginEditorWindow.editableScriptContent(
                    for: action, pluginDirectoryURL: bundleURL, maximumFileBytes: data.count - 1
                ))
            }
        }
        try Data([0xff, 0xfe, 0x00, 0xd8]).write(to: scriptURL)
        let action = try XCTUnwrap(PluginLoader.load(from: bundleURL)).config.action
        XCTAssertNil(PluginEditorWindow.editableScriptContent(for: action, pluginDirectoryURL: bundleURL))
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

    func testSavingReadOnlyScriptDirectoriesPreservesSourceAndCleansBackup() throws {
        let sourceURL = try makeReadOnlyScriptPackage()
        let rootURL = sourceURL.deletingLastPathComponent()
        let destinationURL = rootURL.appendingPathComponent("Saved.actionhaloext")
        defer {
            for package in [sourceURL, destinationURL] {
                for relativePath in ["", "scripts", "scripts/nested"] {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.appendingPathComponent(relativePath).path)
                }
            }
        }
        let originalFingerprint = try XCTUnwrap(PluginLoader.load(from: sourceURL)?.packageFingerprint)
        let config = Data(#"{"name":"Edited","identifier":"com.test.readonly-editor","action":{"type":"shell-script","script":"scripts/nested/main.sh"}}"#.utf8)

        for destination in [destinationURL, sourceURL] {
            try PluginEditorWindow.writePluginPackageAtomically(
                bundleURL: destination, templateURL: sourceURL, configData: config,
                scriptFileName: "scripts/nested/main.sh", scriptContent: "printf 'edited'",
                customIconSourceURL: nil, shouldKeepCustomIcon: false,
                fileManager: WritableRootMoveFileManager()
            )
            XCTAssertEqual(PluginLoader.load(from: destination)?.config.name, "Edited")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("scripts/nested/main.sh"), encoding: .utf8), "printf 'edited'")
            for package in [sourceURL, destination] {
                for relativePath in ["", "scripts", "scripts/nested"] {
                    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: package.appendingPathComponent(relativePath).path)[.posixPermissions] as? Int, 0o555)
                }
            }
            if destination == destinationURL {
                XCTAssertEqual(PluginLoader.load(from: sourceURL)?.packageFingerprint, originalFingerprint)
                XCTAssertEqual(try String(contentsOf: sourceURL.appendingPathComponent("scripts/nested/main.sh"), encoding: .utf8), "printf 'original'")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rootURL.path).sorted(), ["Saved.actionhaloext", "Source.actionhaloext"])
        }
    }

    func testFailedSaveOfReadOnlyScriptDirectoriesRestoresOriginalWithoutResidue() throws {
        let sourceURL = try makeReadOnlyScriptPackage()
        defer {
            for relativePath in ["", "scripts", "scripts/nested"] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceURL.appendingPathComponent(relativePath).path)
            }
        }
        let originalFingerprint = try XCTUnwrap(PluginLoader.load(from: sourceURL)?.packageFingerprint)
        let fileManager = FailingEditorCommitFileManager()
        XCTAssertThrowsError(try PluginEditorWindow.writePluginPackageAtomically(
            bundleURL: sourceURL, templateURL: sourceURL,
            configData: Data(#"{"name":"Edited","identifier":"com.test.readonly-editor","action":{"type":"shell-script","script":"scripts/nested/main.sh"}}"#.utf8),
            scriptFileName: "scripts/nested/main.sh", scriptContent: "printf 'edited'",
            customIconSourceURL: nil, shouldKeepCustomIcon: false, fileManager: fileManager
        ))
        XCTAssertTrue(fileManager.didRejectCommit, "The save must reach replacement before the injected failure")
        XCTAssertEqual(PluginLoader.load(from: sourceURL)?.packageFingerprint, originalFingerprint)
        XCTAssertEqual(PluginLoader.load(from: sourceURL)?.config.name, "Original")
        XCTAssertEqual(try String(contentsOf: sourceURL.appendingPathComponent("scripts/nested/main.sh"), encoding: .utf8), "printf 'original'")
        for relativePath in ["", "scripts", "scripts/nested"] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sourceURL.appendingPathComponent(relativePath).path)[.posixPermissions] as? Int, 0o555)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sourceURL.deletingLastPathComponent().path), ["Source.actionhaloext"])
    }

    func testPermissionFailureAfterMoveNeverDeletesTheOriginalPackage() throws {
        for failOnBackup in [true, false] {
            let sourceURL = try makeReadOnlyScriptPackage()
            let rootURL = sourceURL.deletingLastPathComponent()
            defer { PluginManager.removeDisposablePluginDirectory(rootURL) }
            let fileManager = FailingMovedPermissionsFileManager(failOnBackup: failOnBackup)
            XCTAssertThrowsError(try PluginEditorWindow.writePluginPackageAtomically(
                bundleURL: sourceURL, templateURL: sourceURL,
                configData: Data(#"{"name":"Edited","identifier":"com.test.readonly-editor","action":{"type":"shell-script","script":"scripts/nested/main.sh"}}"#.utf8),
                scriptFileName: "scripts/nested/main.sh", scriptContent: "printf 'edited'",
                customIconSourceURL: nil, shouldKeepCustomIcon: false, fileManager: fileManager
            ))
            XCTAssertTrue(fileManager.didRejectPermissions, "The move must finish before the injected permission failure")
            let packages = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            XCTAssertEqual(packages.map(\.lastPathComponent), ["Source.actionhaloext"])
            XCTAssertEqual(PluginLoader.load(from: sourceURL)?.config.name, "Original")
            XCTAssertEqual(try String(contentsOf: sourceURL.appendingPathComponent("scripts/nested/main.sh"), encoding: .utf8), "printf 'original'")
            for package in packages {
                for relativePath in ["", "scripts", "scripts/nested"] {
                    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: package.appendingPathComponent(relativePath).path)[.posixPermissions] as? Int, 0o555)
                }
            }
        }
    }

    func testPersistentPermissionAndRollbackFailureKeepsTheOnlyOriginalCopy() throws {
        let sourceURL = try makeReadOnlyScriptPackage()
        let rootURL = sourceURL.deletingLastPathComponent()
        defer { PluginManager.removeDisposablePluginDirectory(rootURL) }
        let fileManager = FailingMovedPermissionsFileManager(
            failOnBackup: true, keepRejectingPermissions: true, rejectRollback: true
        )
        XCTAssertThrowsError(try PluginEditorWindow.writePluginPackageAtomically(
            bundleURL: sourceURL, templateURL: sourceURL,
            configData: Data(#"{"name":"Edited","identifier":"com.test.readonly-editor","action":{"type":"shell-script","script":"scripts/nested/main.sh"}}"#.utf8),
            scriptFileName: "scripts/nested/main.sh", scriptContent: "printf 'edited'",
            customIconSourceURL: nil, shouldKeepCustomIcon: false, fileManager: fileManager
        ))
        XCTAssertGreaterThanOrEqual(fileManager.rejectedPermissionAttempts, 2)
        XCTAssertTrue(fileManager.didRejectRollback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        let packages = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(packages.count, 1)
        let backupURL = try XCTUnwrap(packages.first { $0.lastPathComponent.hasPrefix(".backup-") })
        XCTAssertEqual(PluginLoader.load(from: backupURL)?.config.name, "Original")
        XCTAssertEqual(try String(contentsOf: backupURL.appendingPathComponent("scripts/nested/main.sh"), encoding: .utf8), "printf 'original'")
    }

    private func makeReadOnlyScriptPackage() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryDirectories.append(rootURL)
        let sourceURL = rootURL.appendingPathComponent("Source.actionhaloext")
        try FileManager.default.createDirectory(at: sourceURL.appendingPathComponent("scripts/nested"), withIntermediateDirectories: true)
        try Data(#"{"name":"Original","identifier":"com.test.readonly-editor","action":{"type":"shell-script","script":"scripts/nested/main.sh"}}"#.utf8)
            .write(to: sourceURL.appendingPathComponent("Config.json"))
        try "printf 'original'".write(to: sourceURL.appendingPathComponent("scripts/nested/main.sh"), atomically: true, encoding: .utf8)
        for relativePath in ["", "scripts", "scripts/nested"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sourceURL.appendingPathComponent(relativePath).path)
        }
        return sourceURL
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

    @MainActor
    func testGlobalHotkeyRecorderKeyEquivalentsKeepModifierRequirement() throws {
        let window = HotkeyRecorderWindow()
        defer { window.close() }
        let recorder = try XCTUnwrap(try XCTUnwrap(window.contentView).subviews
            .compactMap { $0 as? ShortcutRecorderField }.first)
        XCTAssertTrue(window.makeFirstResponder(recorder))
        var recordedKeyCode: UInt32?
        window.onHotkeyRecorded = { keyCode, _ in recordedKeyCode = keyCode }

        for (characters, keyCode): (String, UInt16) in [("\r", 0x24), ("\u{1B}", 0x35)] {
            XCTAssertTrue(window.performKeyEquivalent(with: try makeKeyDownEvent(
                modifiers: [], characters: characters, keyCode: keyCode
            )))
            XCTAssertNil(recordedKeyCode)
            XCTAssertEqual(recorder.rawComboString, "")
        }

        XCTAssertTrue(window.performKeyEquivalent(with: try makeKeyDownEvent(
            modifiers: [.option], characters: "\r", keyCode: 0x24
        )))
        XCTAssertEqual(recordedKeyCode, 0x24)
        XCTAssertEqual(recorder.rawComboString, "Option+Return")
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
        XCTAssertTrue(editor.isPersisting)
        XCTAssertFalse(saveButton.isEnabled)
        XCTAssertFalse(deleteButton.isEnabled)
        XCTAssertFalse(editor.confirmClose { true })
        editor.deletePluginAfterConfirmation(plugin)
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        wait(for: [reload], timeout: 5)

        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directoryURL.path))
        XCTAssertFalse(editor.isPersisting)
        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertTrue(deleteButton.isEnabled)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    @MainActor
    func testUnicodeScriptOpensAndSavesThroughEditor() throws {
        for (actionType, encoding) in [("shell-script", String.Encoding.utf16), ("applescript", .utf32)] {
            let script = actionType == "shell-script" ? "printf '中文😀'" : "return \"中文😀\""
            let (editor, plugin, saveButton, _) = try makeEditor(
                actionJSON: "{\"type\":\"\(actionType)\",\"script\":\"script.txt\"}",
                scriptData: script.data(using: encoding)
            )
            defer { editor.close() }
            let contentView = try XCTUnwrap(editor.contentView)
            let scriptView = try XCTUnwrap(contentView.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first)
            XCTAssertEqual(scriptView.string, script)
            XCTAssertTrue(saveButton.isEnabled)
            let nameField = try XCTUnwrap(contentView.subviews.compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.stringValue == "Persistence" })
            nameField.stringValue = "Renamed"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            let reload = expectation(forNotification: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)

            XCTAssertTrue(saveButton.sendAction(saveButton.action, to: saveButton.target))
            XCTAssertTrue(editor.isPersisting)
            wait(for: [reload], timeout: 5)

            XCTAssertFalse(editor.isPersisting)
            XCTAssertEqual(PluginLoader.load(from: plugin.directoryURL)?.config.name, "Renamed")
            XCTAssertEqual(try String(contentsOf: plugin.directoryURL.appendingPathComponent("script.txt"), encoding: .utf8), script)
        }
    }

    @MainActor
    func testDeletingBlocksSavingAndRepeatedDeletion() throws {
        let (editor, plugin, saveButton, deleteButton) = try makeEditor()
        defer { editor.close() }
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let reload = expectation(forNotification: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)

        editor.deletePluginAfterConfirmation(plugin)
        XCTAssertTrue(editor.isPersisting)
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
        XCTAssertFalse(editor.isPersisting)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.confirmClose { false })
    }

    @MainActor
    func testFocusedShortcutRecorderHandlesReturnBeforeSaveButton() throws {
        let (editor, plugin, _, _) = try makeEditor(
            actionJSON: #"{"type":"key-combo","key":"c","modifiers":["Command"]}"#
        )
        defer { editor.close() }
        let contentView = try XCTUnwrap(editor.contentView)
        let recorder = try XCTUnwrap(contentView.subviews.compactMap { $0 as? ShortcutRecorderField }.first)
        XCTAssertTrue(editor.makeFirstResponder(recorder))
        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editor.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 0x24
        ))

        XCTAssertTrue(editor.performKeyEquivalent(with: returnEvent))
        XCTAssertEqual(recorder.rawComboString, "Return")
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.isPersisting, "Recording Return must not invoke the default Save button")
        XCTAssertEqual(PluginLoader.load(from: plugin.directoryURL)?.config.action.key, "c")

        let nameField = try XCTUnwrap(contentView.subviews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.stringValue == "Persistence" })
        XCTAssertTrue(editor.makeFirstResponder(nameField))
        let reload = expectation(forNotification: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)
        XCTAssertTrue(editor.performKeyEquivalent(with: returnEvent))
        XCTAssertTrue(editor.isPersisting, "Return in ordinary text fields must still invoke Save")
        wait(for: [reload], timeout: 5)
        XCTAssertFalse(editor.isPersisting)
        XCTAssertEqual(PluginLoader.load(from: plugin.directoryURL)?.config.action.key, "return")
    }

    @MainActor
    func testSavingCustomIconAfterLanguageChangePreservesImageAndSymbolName() throws {
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(
            previousArguments.merging(["AppLanguage": "en"]) { _, new in new },
            forName: UserDefaults.argumentDomain
        )

        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
        ))
        let (editor, plugin, saveButton, _) = try makeEditor(customIconData: imageData)
        defer { editor.close() }
        let iconPopUp = try iconPopUp(in: editor)
        XCTAssertEqual(iconPopUp.titleOfSelectedItem, "Custom Image".localized)
        XCTAssertFalse(editor.hasUnsavedChanges)

        defaults.setVolatileDomain(
            previousArguments.merging(["AppLanguage": "zh-Hans"]) { _, new in new },
            forName: UserDefaults.argumentDomain
        )
        XCTAssertNotEqual(iconPopUp.titleOfSelectedItem, "Custom Image".localized)
        let reload = expectation(forNotification: PluginManager.pluginsReloadedNotification, object: PluginManager.shared)
        XCTAssertTrue(saveButton.sendAction(saveButton.action, to: saveButton.target))
        wait(for: [reload], timeout: 5)

        let savedPlugin = try XCTUnwrap(PluginLoader.load(from: plugin.directoryURL))
        XCTAssertEqual(savedPlugin.iconName, plugin.iconName)
        XCTAssertEqual(try Data(contentsOf: plugin.directoryURL.appendingPathComponent("icon.png")), imageData)
    }

    @MainActor
    func testChoosingCustomIconAfterLanguageChangeReplacesExistingMenuItem() throws {
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(
            previousArguments.merging(["AppLanguage": "en"]) { _, new in new },
            forName: UserDefaults.argumentDomain
        )

        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
        ))
        let (editor, _, _, _) = try makeEditor(customIconData: imageData)
        defer { editor.close() }
        let iconPopUp = try iconPopUp(in: editor)
        let initialItemCount = iconPopUp.numberOfItems
        let previousCustomItem = try XCTUnwrap(iconPopUp.selectedItem)
        let replacementURL = rootURL.appendingPathComponent("Replacement.png")
        try imageData.write(to: replacementURL)

        defaults.setVolatileDomain(
            previousArguments.merging(["AppLanguage": "zh-Hans"]) { _, new in new },
            forName: UserDefaults.argumentDomain
        )
        editor.selectCustomIcon(at: replacementURL)

        XCTAssertEqual(iconPopUp.numberOfItems, initialItemCount)
        XCTAssertFalse(iconPopUp.itemArray.contains { $0 === previousCustomItem })
        XCTAssertEqual(iconPopUp.titleOfSelectedItem, "Custom Image".localized)
    }

    @MainActor
    private func iconPopUp(in editor: PluginEditorWindow) throws -> NSPopUpButton {
        try XCTUnwrap(try XCTUnwrap(editor.contentView).subviews
            .compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("bolt.fill") })
    }

    @MainActor
    private func makeEditor(
        customIconData: Data? = nil,
        actionJSON: String = #"{"type":"copy"}"#,
        scriptData: Data? = nil
    ) throws -> (PluginEditorWindow, Plugin, NSButton, NSButton) {
        let packageURL = rootURL.appendingPathComponent("Persistence.actionhaloext")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try """
        {"name":"Persistence","identifier":"com.test.editor-persistence","action":\(actionJSON)}
        """.write(to: packageURL.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)
        if let customIconData {
            try customIconData.write(to: packageURL.appendingPathComponent("icon.png"))
        }
        if let scriptData {
            try scriptData.write(to: packageURL.appendingPathComponent("script.txt"))
        }
        let plugin = try XCTUnwrap(PluginLoader.load(from: packageURL))
        PluginManager.shared.plugins = [plugin]
        let editor = PluginEditorWindow(plugin: plugin)
        let buttons = try XCTUnwrap(editor.contentView).subviews.compactMap { $0 as? NSButton }
        let saveButton = try XCTUnwrap(buttons.first { $0.title == "Save".localized })
        let deleteButton = try XCTUnwrap(buttons.first { $0.title == "Delete".localized })
        return (editor, plugin, saveButton, deleteButton)
    }
}
