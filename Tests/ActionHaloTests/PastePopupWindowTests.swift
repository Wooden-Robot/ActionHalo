import XCTest
@testable import ActionHalo

@MainActor
final class PastePopupWindowTests: GlobalStateTestCase {
    func testPopupStaysInsideVisibleFrameAtScreenEdgesIncludingNegativeCoordinates() {
        let window = PastePopupWindow()
        defer { window.close() }

        for visibleFrame in [
            NSRect(x: 0, y: 40, width: 1920, height: 1015),
            NSRect(x: -1920, y: -400, width: 1920, height: 1055)
        ] {
            for point in [
                NSPoint(x: visibleFrame.minX + 1, y: visibleFrame.minY + 1),
                NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.minY + 1),
                NSPoint(x: visibleFrame.minX + 1, y: visibleFrame.maxY - 1),
                NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.maxY - 1),
                NSPoint(x: visibleFrame.midX, y: visibleFrame.maxY + 20),
                NSPoint(x: visibleFrame.midX, y: visibleFrame.minY - 20)
            ] {
                let frame = NSRect(
                    origin: window.popupOrigin(at: point, visibleFrame: visibleFrame),
                    size: window.frame.size
                )
                XCTAssertTrue(visibleFrame.contains(frame), "Popup \(frame) escaped \(visibleFrame) at \(point)")
            }
        }
    }

    func testPopupKeepsCursorOffsetWhenNoClampingIsNeeded() {
        let window = PastePopupWindow()
        defer { window.close() }
        let point = NSPoint(x: 300, y: 300)
        let expectedOrigin = NSPoint(x: 226, y: 315)

        XCTAssertEqual(
            window.popupOrigin(at: point, visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080)),
            expectedOrigin
        )
        XCTAssertEqual(window.popupOrigin(at: point, visibleFrame: nil), expectedOrigin)
    }

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
