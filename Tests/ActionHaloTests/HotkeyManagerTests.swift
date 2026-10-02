import XCTest
import Carbon
@testable import ActionHalo

final class HotkeyManagerTests: GlobalStateTestCase {
    private let defaultsKeys = [
        "hotkeyConfigured",
        "toggleHotkeyConfigured",
        "hotkeyKeyCode",
        "hotkeyModifiers",
        "toggleHotkeyKeyCode",
        "toggleHotkeyModifiers",
    ]
    override func setUp() {
        super.setUp()
        isolateStandardUserDefaults(keys: defaultsKeys)
    }

    @MainActor
    private func withPreservedManagerState(
        _ body: (HotkeyManager) throws -> Void
    ) rethrows {
        let manager = HotkeyManager.shared
        let savedHotkey = manager.hotkey
        let savedToggleHotkey = manager.toggleHotkey
        defer {
            manager.unregisterHotkeys()
            manager.hotkey = savedHotkey
            manager.toggleHotkey = savedToggleHotkey
        }

        try body(manager)
    }

    @MainActor
    func testHotkeyDescriptions() {
        withPreservedManagerState { manager in
            // 1. Test Unset State
            manager.hotkey = nil
            manager.toggleHotkey = nil

            // Use localized compare or at least check it doesn't crash and returns a non-empty fallback
            XCTAssertFalse(manager.hotkeyDescription.isEmpty, "Description should not be empty even when unset")

            // 2. Test valid key combo (0x00 is 'A', cmd=256, shift=512)
            // Hardcoding standard carbon modifiers for testing:
            manager.hotkey = (0x00, 768)
            let desc = manager.hotkeyDescription

            XCTAssertTrue(desc.contains("A"))
            XCTAssertTrue(desc.contains("⌘") || desc.contains("⇧") || desc.contains("⌥") || desc.contains("⌃"))

            for (keyCode, keyName): (UInt32, String) in [(0x7A, "F1"), (0x5A, "F20"), (0x18, "="), (0x12, "1")] {
                manager.hotkey = (keyCode, UInt32(controlKey))
                XCTAssertEqual(manager.hotkeyDescription, "⌃" + keyName)
            }
        }
    }

    @MainActor
    func testToggleHotkeyDescription() {
        withPreservedManagerState { manager in
            manager.toggleHotkey = (0x0B, UInt32(cmdKey | optionKey)) // ⌘⌥B
            let desc = manager.toggleHotkeyDescription

            XCTAssertTrue(desc.contains("B"))
            XCTAssertTrue(desc.contains("⌘"))
            XCTAssertTrue(desc.contains("⌥"))

            manager.toggleHotkey = nil
            XCTAssertFalse(manager.toggleHotkeyDescription.isEmpty, "Description should not be empty even when unset")
        }
    }

    @MainActor
    func testSettingHotkeyPostsChangeNotification() {
        withPreservedManagerState { manager in
            let expectation = expectation(forNotification: HotkeyManager.hotkeyChangedNotification, object: manager)

            manager.hotkey = (0x00, 768)

            wait(for: [expectation], timeout: 0.1)
        }
    }

    @MainActor
    func testSettingToggleHotkeyPostsChangeNotification() {
        withPreservedManagerState { manager in
            let expectation = expectation(forNotification: HotkeyManager.toggleHotkeyChangedNotification, object: manager)

            manager.toggleHotkey = (0x0B, 0)

            wait(for: [expectation], timeout: 0.1)
        }
    }

    func testGlobalHotkeyRequiresCommandOptionOrControlModifier() {
        XCTAssertTrue(HotkeyManager.hasRequiredGlobalHotkeyModifier(UInt32(cmdKey)))
        XCTAssertTrue(HotkeyManager.hasRequiredGlobalHotkeyModifier(UInt32(optionKey)))
        XCTAssertTrue(HotkeyManager.hasRequiredGlobalHotkeyModifier(UInt32(controlKey)))
        XCTAssertTrue(HotkeyManager.hasRequiredGlobalHotkeyModifier(UInt32(shiftKey | optionKey)))
        XCTAssertFalse(HotkeyManager.hasRequiredGlobalHotkeyModifier(0))
        XCTAssertFalse(HotkeyManager.hasRequiredGlobalHotkeyModifier(UInt32(shiftKey)))
    }

    func testStoredHotkeyValidationRejectsUnsafeLegacyValues() throws {
        let valid = try XCTUnwrap(
            HotkeyManager.validatedStoredHotkey(
                keyCode: 0x02,
                modifiers: Int(shiftKey | optionKey)
            )
        )

        XCTAssertEqual(valid.keyCode, 0x02)
        XCTAssertEqual(valid.modifiers, UInt32(shiftKey | optionKey))
        XCTAssertNil(HotkeyManager.validatedStoredHotkey(keyCode: 0x02, modifiers: Int(shiftKey)))
        XCTAssertNil(HotkeyManager.validatedStoredHotkey(keyCode: -1, modifiers: Int(cmdKey)))
        XCTAssertNil(HotkeyManager.validatedStoredHotkey(keyCode: 0x7F, modifiers: Int(cmdKey)))
        XCTAssertNil(HotkeyManager.validatedStoredHotkey(keyCode: 0x02, modifiers: -1))
        XCTAssertNil(
            HotkeyManager.validatedStoredHotkey(
                keyCode: 0x02,
                modifiers: Int(UInt32(cmdKey) | 0x01)
            )
        )
    }

    @MainActor
    func testRegistrationSkipsInvalidAssignmentWithoutBlockingValidAssignment() {
        withPreservedManagerState { manager in
            manager.hotkey = (0x02, UInt32(shiftKey))
            manager.toggleHotkey = (
                0x71,
                UInt32(cmdKey | shiftKey | optionKey | controlKey)
            )

            let issues = manager.registerHotkeys()
            manager.unregisterHotkeys()

            XCTAssertEqual(issues.filter { $0.kind == .invalidModifiers }.count, 1)
            XCTAssertFalse(issues.contains { $0.kind == .duplicateAssignment })
            XCTAssertLessThanOrEqual(issues.count, 2)
        }
    }

    @MainActor
    func testRejectedUpdatesPreserveBothHotkeysAndPreferences() {
        withPreservedManagerState { manager in
            let modifiers = UInt32(cmdKey | optionKey)
            manager.hotkey = (0x02, modifiers)
            manager.toggleHotkey = (0x07, modifiers)
            let savedPreferences = UserDefaults.standard.dictionaryWithValues(forKeys: defaultsKeys) as NSDictionary

            for isToggle in [false, true] {
                let otherHotkey = isToggle ? manager.hotkey : manager.toggleHotkey
                let duplicateIssues = manager.updateHotkey(otherHotkey, isToggle: isToggle)
                XCTAssertEqual(duplicateIssues.map(\.kind), [.duplicateAssignment])

                let invalidIssues = manager.updateHotkey((0x02, UInt32(shiftKey)), isToggle: isToggle)
                XCTAssertEqual(invalidIssues.map(\.kind), [.invalidModifiers])
                XCTAssertEqual(manager.hotkey?.keyCode, 0x02)
                XCTAssertEqual(manager.toggleHotkey?.keyCode, 0x07)
                XCTAssertEqual(
                    UserDefaults.standard.dictionaryWithValues(forKeys: defaultsKeys) as NSDictionary,
                    savedPreferences
                )
            }
        }
    }

    @MainActor
    func testFailedReplacementRetainsLiveBindingsAndClearingOnlyRemovesOne() throws {
        try withPreservedManagerState { manager in
            manager.unregisterHotkeys()
            manager.hotkey = nil
            manager.toggleHotkey = nil
            let modifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
            let menuKey: UInt32 = 0x6A
            let toggleKey: UInt32 = 0x40
            let occupiedKey: UInt32 = 0x4F
            let replacementKey: UInt32 = 0x50
            var reservedRefs: [EventHotKeyRef] = []
            defer { reservedRefs.forEach { UnregisterEventHotKey($0) } }
            func reserve(_ keyCode: UInt32) -> OSStatus {
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    keyCode, modifiers, EventHotKeyID(signature: 0x41485453, id: keyCode),
                    GetApplicationEventTarget(), 0, &reference
                )
                if let reference { reservedRefs.append(reference) }
                return status
            }
            let availabilityStatus = reserve(occupiedKey)
            guard availabilityStatus == noErr else {
                throw XCTSkip("The current session cannot register integration test hotkeys (\(availabilityStatus)).")
            }
            let initialIssues = manager.updateHotkey((menuKey, modifiers)) +
                manager.updateHotkey((toggleKey, modifiers), isToggle: true)
            XCTAssertTrue(initialIssues.isEmpty)
            guard initialIssues.isEmpty else { return }
            let savedPreferences = UserDefaults.standard.dictionaryWithValues(forKeys: defaultsKeys) as NSDictionary

            for isToggle in [false, true] {
                let issues = manager.updateHotkey((occupiedKey, modifiers), isToggle: isToggle)
                XCTAssertTrue(issues.contains { issue in
                    if case .registerFailed = issue.kind { return true }
                    return false
                })
                XCTAssertEqual(manager.hotkey?.keyCode, menuKey)
                XCTAssertEqual(manager.toggleHotkey?.keyCode, toggleKey)
                XCTAssertEqual(
                    UserDefaults.standard.dictionaryWithValues(forKeys: defaultsKeys) as NSDictionary,
                    savedPreferences
                )
                XCTAssertNotEqual(reserve(menuKey), noErr, "The original menu hotkey must remain registered.")
                XCTAssertNotEqual(reserve(toggleKey), noErr, "The original toggle hotkey must remain registered.")
            }

            XCTAssertTrue(manager.updateHotkey((replacementKey, modifiers)).isEmpty)
            XCTAssertTrue(manager.updateHotkey((replacementKey, modifiers)).isEmpty, "Re-recording the active shortcut is a no-op.")
            XCTAssertEqual(manager.hotkey?.keyCode, replacementKey)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"), Int(replacementKey))
            XCTAssertEqual(reserve(menuKey), noErr, "A successful replacement releases the previous shortcut.")
            XCTAssertNotEqual(reserve(replacementKey), noErr)
            XCTAssertNotEqual(reserve(toggleKey), noErr)

            XCTAssertTrue(manager.updateHotkey(nil).isEmpty)
            XCTAssertNil(manager.hotkey)
            XCTAssertNil(UserDefaults.standard.object(forKey: "hotkeyKeyCode"))
            XCTAssertEqual(reserve(replacementKey), noErr)
            XCTAssertNotEqual(reserve(toggleKey), noErr)
        }
    }
}
