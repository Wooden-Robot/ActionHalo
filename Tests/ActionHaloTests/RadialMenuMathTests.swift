import QuartzCore
import XCTest
@testable import ActionHalo

final class RadialMenuMathTests: XCTestCase {
    @MainActor
    func testSlotNumbersStayUprightAndTangentialInBothModes() throws {
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.visualCenter = NSPoint(x: 250, y: 250)
        for gtaMode in [false, true] {
            view.isGTAModeEnabled = gtaMode
            for count in 1...16 {
                view.menuItems = Array(repeating: RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: .builtIn(.copy)), count: count)
                view.buildMenu()
                let labels = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.filter {
                    !$0.isHidden && Int($0.string as? String ?? "") != nil
                })
                XCTAssertEqual(labels.count, count)
                for label in labels {
                    let detail = "GTA=\(gtaMode) count=\(count) slot=\(label.string ?? "")"
                    XCTAssertGreaterThanOrEqual(label.transform.m22, -0.000001, "Text must face the reader; \(detail)")
                    let dx = label.position.x - view.visualCenter.x
                    let dy = label.position.y - view.visualCenter.y
                    XCTAssertEqual(dx * label.transform.m11 + dy * label.transform.m12, 0, accuracy: 0.000001,
                                   "Text must follow the ring; \(detail)")
                }
            }
        }
    }
    
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
