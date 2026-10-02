import AppKit
import XCTest
@testable import ActionHalo

@MainActor
final class RadialMenuAccessibilityTests: GlobalStateTestCase {
    func testAccessibilityExposesItemLabelsAndSessionEnabledState() throws {
        let (window, view) = makeView(items: [
            RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: .builtIn(.copy)),
            RadialMenuItem(title: "Unavailable", iconName: "doc.on.clipboard", action: .builtIn(.paste), isExecutable: false)
        ])
        defer { window.close() }
        let children = try accessibilityItems(in: view)

        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, ["Copy", "Unavailable"])
        XCTAssertTrue(children.allSatisfy { $0.accessibilityRole() == .button })
        XCTAssertTrue(children[0].isAccessibilityEnabled())
        XCTAssertFalse(children[1].isAccessibilityEnabled())

        view.endInteractionSession()
        XCTAssertTrue(children.allSatisfy { !$0.isAccessibilityEnabled() })
        XCTAssertFalse(children[0].accessibilityPerformPress())

        view.beginInteractionSession()
        XCTAssertTrue(children[0].isAccessibilityEnabled())
        XCTAssertFalse(children[1].isAccessibilityEnabled())
    }

    func testAccessibilityFramesFollowWindowMovementInNegativeScreenCoordinates() throws {
        let (window, view) = makeView(items: [
            RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: .builtIn(.copy))
        ])
        defer { window.close() }
        let child = try XCTUnwrap(try accessibilityItems(in: view).first)
        let originalFrame = child.accessibilityFrame()
        XCTAssertGreaterThan(originalFrame.width, 0)
        XCTAssertGreaterThan(originalFrame.height, 0)
        XCTAssertTrue(window.frame.contains(originalFrame))
        XCTAssertLessThan(originalFrame.maxX, 0)

        window.setFrameOrigin(NSPoint(x: window.frame.minX + 80, y: window.frame.minY - 350))
        let movedFrame = child.accessibilityFrame()

        XCTAssertEqual(movedFrame.minX, originalFrame.minX + 80, accuracy: 0.01)
        XCTAssertEqual(movedFrame.minY, originalFrame.minY - 350, accuracy: 0.01)
        XCTAssertEqual(movedFrame.size, originalFrame.size)
        XCTAssertFalse(window.isVisible)
    }

    func testAccessibilityPressSharesSingleFireGateWithOtherActivationPaths() throws {
        let (window, view) = makeView(items: [
            RadialMenuItem(title: "Unavailable", iconName: "doc.on.clipboard", action: .builtIn(.paste), isExecutable: false),
            RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: .builtIn(.copy))
        ])
        defer { window.close() }
        let children = try accessibilityItems(in: view)
        var selectedTitles: [String] = []
        view.onItemSelected = { selectedTitles.append($0.title) }

        XCTAssertFalse(children[0].accessibilityPerformPress())
        XCTAssertFalse(view.activateItem(at: -1))
        XCTAssertFalse(view.activateItem(at: 2))
        XCTAssertTrue(children[1].accessibilityPerformPress())
        XCTAssertFalse(children[1].accessibilityPerformPress())
        XCTAssertFalse(view.activateItem(at: 1))
        XCTAssertEqual(selectedTitles, ["Copy"])
        XCTAssertTrue(children.allSatisfy { !$0.isAccessibilityEnabled() })
    }

    func testPageRebuildRejectsOldAccessibilityNodesAndEnablesNewPage() throws {
        let (window, view) = makeView(items: [
            RadialMenuItem(title: "Old Copy", iconName: "doc.on.doc", action: .builtIn(.copy)),
            RadialMenuItem(title: "Next", iconName: "arrow.right", action: .pageNext)
        ])
        defer { window.close() }
        let oldChildren = try accessibilityItems(in: view)
        var selectedTitles: [String] = []
        view.onItemSelected = { [weak view] item in
            guard let view else { return }
            if case .pageNext = item.action {
                view.menuItems = [RadialMenuItem(title: "New Copy", iconName: "doc.on.doc", action: .builtIn(.copy))]
                view.buildMenu()
                view.beginInteractionSession()
            } else {
                selectedTitles.append(item.title)
            }
        }

        XCTAssertTrue(oldChildren[1].accessibilityPerformPress())
        XCTAssertFalse(oldChildren[0].accessibilityPerformPress())
        XCTAssertFalse(oldChildren[1].accessibilityPerformPress())
        XCTAssertTrue(oldChildren.allSatisfy { !$0.isAccessibilityEnabled() })
        let newChild = try XCTUnwrap(try accessibilityItems(in: view).first)
        XCTAssertEqual(newChild.accessibilityLabel(), "New Copy")
        XCTAssertTrue(newChild.accessibilityPerformPress())
        XCTAssertEqual(selectedTitles, ["New Copy"])
    }

    func testEmptyMenuClearsAccessibilityNodesAndCanRebuildSameGeometry() throws {
        let item = RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: .builtIn(.copy))
        let (window, view) = makeView(items: [item])
        defer { window.close() }
        let oldChild = try XCTUnwrap(try accessibilityItems(in: view).first)

        view.menuItems = []
        view.buildMenu()
        XCTAssertTrue(try accessibilityItems(in: view).isEmpty)
        XCTAssertFalse(oldChild.accessibilityPerformPress())

        view.menuItems = [item]
        view.buildMenu()
        view.beginInteractionSession()
        let newChild = try XCTUnwrap(try accessibilityItems(in: view).first)
        XCTAssertGreaterThan(newChild.accessibilityFrame().width, 0)
        XCTAssertFalse(oldChild.accessibilityPerformPress())
        XCTAssertTrue(newChild.accessibilityPerformPress())
    }

    private func accessibilityItems(in view: RadialMenuView) throws -> [NSAccessibilityElement] {
        try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
    }

    private func makeView(items: [RadialMenuItem]) -> (NSPanel, RadialMenuView) {
        let window = NSPanel(
            contentRect: NSRect(x: -1000, y: 100, width: 440, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        let view = RadialMenuView(frame: NSRect(x: 20, y: 30, width: 400, height: 340))
        view.visualCenter = NSPoint(x: 200, y: 170)
        view.trackingCenter = view.visualCenter
        view.menuItems = items
        window.contentView?.addSubview(view)
        view.beginInteractionSession()
        view.buildMenu()
        return (window, view)
    }
}
