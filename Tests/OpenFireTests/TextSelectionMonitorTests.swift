import XCTest
@testable import OpenFire

final class TextSelectionMonitorTests: XCTestCase {
    func testNotificationName() {
        XCTAssertEqual(TextSelectionMonitor.textSelectedNotification.rawValue, "OpenFireTextSelected")
        XCTAssertEqual(TextSelectionMonitor.emptyTextInputClickedNotification.rawValue, "OpenFireEmptyTextInputClicked")
    }

    func testSingletonInstance() {
        let instance1 = TextSelectionMonitor.shared
        let instance2 = TextSelectionMonitor.shared
        XCTAssertTrue(instance1 === instance2)
    }

    func testHasUsableClipboardTextTreatsWhitespaceOnlyAsEmpty() {
        XCTAssertFalse(TextSelectionMonitor.hasUsableClipboardText(nil))
        XCTAssertFalse(TextSelectionMonitor.hasUsableClipboardText(""))
        XCTAssertFalse(TextSelectionMonitor.hasUsableClipboardText("   \n\t"))
        XCTAssertTrue(TextSelectionMonitor.hasUsableClipboardText("hello"))
    }
}
