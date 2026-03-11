import XCTest
@testable import OpenFire

final class RadialMenuMathTests: XCTestCase {
    
    // Test the dynamic radius sizing logic
    func testOuterRadiusCalculation() {
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        
        // When there are no items or 1 item, it should fall back to baseOuterRadius
        view.menuItems = []
        XCTAssertEqual(view.outerRadius, 130.0)
        
        // With 6 items: (6 * 60) / (2 * .pi) ≈ 57.29, which is less than base 130
        view.menuItems = Array(repeating: RadialMenuItem(title: "", iconName: "", action: .pageNext), count: 6)
        XCTAssertEqual(view.outerRadius, 130.0)
        
        // With 16 items: (16 * 60) / (2 * .pi) ≈ 152.78, which is > 130, so radius expands!
        view.menuItems = Array(repeating: RadialMenuItem(title: "", iconName: "", action: .pageNext), count: 16)
        XCTAssertTrue(view.outerRadius > 130.0)
        XCTAssertTrue(view.outerRadius < 200.0) // Max cap is 200
    }
}
