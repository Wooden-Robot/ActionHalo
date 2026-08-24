import XCTest
@testable import ActionHalo

@MainActor
final class PastePopupWindowTests: GlobalStateTestCase {
    func testRepeatedButtonActionDispatchesPasteOnlyOnce() throws {
        let window = PastePopupWindow()
        var pasteCount = 0
        window.onPasteClicked = {
            pasteCount += 1
        }
        window.show(at: NSPoint(x: 300, y: 300))

        let pasteButton = try XCTUnwrap(
            window.contentView?.subviews
                .compactMap { $0 as? NSButton }
                .first(where: { $0.title == "Paste".localized })
        )

        pasteButton.performClick(nil)
        pasteButton.performClick(nil)

        XCTAssertEqual(pasteCount, 1)
        XCTAssertTrue(window.ignoresMouseEvents)
        window.hidePopup()
    }

    func testDismissalDisablesInputBeforeAnimationCompletes() {
        let window = PastePopupWindow()
        window.show(at: NSPoint(x: 300, y: 300))

        window.hidePopup()

        XCTAssertTrue(window.ignoresMouseEvents)
    }
}
