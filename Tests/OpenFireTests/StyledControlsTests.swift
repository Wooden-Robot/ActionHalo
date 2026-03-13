import XCTest
@testable import OpenFire

final class StyledControlsTests: XCTestCase {

    func testSolidToolbarStyleUsesTransparentInnerButtonChrome() {
        let button = CapsuleActionButton(frame: NSRect(x: 0, y: 0, width: 80, height: 28))

        button.style = .accent
        button.usesSolidToolbarStyle = true

        XCTAssertEqual(button.layer?.borderWidth, 0)
        XCTAssertEqual(button.layer?.shadowRadius, 0)
        XCTAssertEqual(button.alphaValue, 1.0)
    }

    func testSolidToolbarStyleHoverAddsInnerHighlight() {
        let button = CapsuleActionButton(frame: NSRect(x: 0, y: 0, width: 80, height: 28))

        button.style = .accent
        button.usesSolidToolbarStyle = true
        button.mouseEntered(with: NSEvent())

        XCTAssertEqual(button.layer?.borderWidth, 1)
        XCTAssertEqual(button.layer?.shadowRadius, 6)
    }

    func testDisablingButtonReducesAlpha() {
        let button = CapsuleActionButton(frame: NSRect(x: 0, y: 0, width: 80, height: 28))

        button.usesSolidToolbarStyle = true
        button.isEnabled = false

        XCTAssertEqual(button.alphaValue, 0.55)
    }
}
