import XCTest
@testable import OpenFire

final class AccessibilityManagerTests: XCTestCase {
    func testAccessibilityScreenPointUsesContainingScreenCoordinates() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No main screen available")
        }

        let point = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let converted = try XCTUnwrap(AccessibilityManager.shared.accessibilityScreenPoint(for: point))

        XCTAssertEqual(converted.x, point.x, accuracy: 0.001)
        XCTAssertEqual(converted.y, screen.frame.maxY - point.y, accuracy: 0.001)
    }

    func testCoreGraphicsScreenPointUsesVirtualDesktopTopEdge() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: -900, width: 1920, height: 1080)
        ]
        let point = NSPoint(x: 1600, y: -120)

        let converted = AccessibilityManager.coreGraphicsScreenPoint(for: point, screenFrames: screens)

        XCTAssertNotNil(converted)
        XCTAssertEqual(converted?.x ?? .zero, point.x, accuracy: 0.001)
        XCTAssertEqual(converted?.y ?? .zero, 1020, accuracy: 0.001)
    }

    func testShouldTreatElementAsTextRejectsStaticTextInsideStructuralAncestors() {
        let result = AccessibilityManager.shouldTreatElementAsText(
            role: kAXStaticTextRole,
            ancestorRoles: ["AXGroup", kAXRowRole, kAXOutlineRole],
            bundleID: "com.jetbrains.pycharm",
            allowedRoles: [
                kAXStaticTextRole,
                kAXTextFieldRole,
                kAXTextAreaRole,
                "AXWebArea",
                "AXHeading",
                "AXParagraph",
                "AXLink"
            ],
            forbiddenRoles: [
                kAXImageRole,
                kAXCellRole,
                kAXRowRole,
                kAXButtonRole,
                kAXWindowRole,
                kAXApplicationRole
            ]
        )

        XCTAssertFalse(result)
    }

    func testShouldTreatElementAsTextKeepsRegularEditorTextAllowed() {
        let result = AccessibilityManager.shouldTreatElementAsText(
            role: kAXStaticTextRole,
            ancestorRoles: ["AXGroup", "AXScrollArea"],
            bundleID: "com.jetbrains.pycharm",
            allowedRoles: [
                kAXStaticTextRole,
                kAXTextFieldRole,
                kAXTextAreaRole,
                "AXWebArea",
                "AXHeading",
                "AXParagraph",
                "AXLink"
            ],
            forbiddenRoles: [
                kAXImageRole,
                kAXCellRole,
                kAXRowRole,
                kAXButtonRole,
                kAXWindowRole,
                kAXApplicationRole
            ]
        )

        XCTAssertTrue(result)
    }
}
