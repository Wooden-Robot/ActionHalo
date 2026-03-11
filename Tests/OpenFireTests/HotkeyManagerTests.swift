import XCTest
@testable import OpenFire

final class HotkeyManagerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }
    
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        super.tearDown()
    }
    
    func testHotkeyDescriptions() {
        let manager = HotkeyManager.shared
        
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
    
    func testToggleHotkeyEquivalent() {
        let manager = HotkeyManager.shared
        manager.toggleHotkey = (0x0B, 0) // 'B' key
        XCTAssertEqual(manager.toggleHotkeyEquivalent, "b")
        
        manager.toggleHotkey = nil
        XCTAssertEqual(manager.toggleHotkeyEquivalent, "e", "Fallback default for unset hotkey equivalent")
    }
}
