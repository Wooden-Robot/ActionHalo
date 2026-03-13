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
}
