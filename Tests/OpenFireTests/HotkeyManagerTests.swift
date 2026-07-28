import XCTest
import Carbon
@testable import OpenFire

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
        _ body: (HotkeyManager) -> Void
    ) {
        let manager = HotkeyManager.shared
        let savedHotkey = manager.hotkey
        let savedToggleHotkey = manager.toggleHotkey
        defer {
            manager.unregisterHotkeys()
            manager.hotkey = savedHotkey
            manager.toggleHotkey = savedToggleHotkey
        }

        body(manager)
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
}
