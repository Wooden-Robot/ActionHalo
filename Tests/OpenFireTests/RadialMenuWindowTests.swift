import XCTest
@testable import OpenFire

final class RadialMenuWindowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        super.tearDown()
    }

    func testShowMenuWithoutPaginationKeepsOriginalItems() {
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")

        let window = RadialMenuWindow()
        let items = makeItems(count: 4)
        window.showMenu(at: NSPoint(x: 400, y: 300), items: items, selectedText: "hello")

        let renderedItems = renderedMenuItems(in: window)
        XCTAssertEqual(renderedItems.map(\.title), items.map(\.title))
        XCTAssertFalse(renderedItems.contains { item in
            if case .pageNext = item.action { return true }
            if case .pagePrev = item.action { return true }
            return false
        })

        window.hideMenu()
    }

    func testShowMenuAddsNextControlOnFirstPageWhenNeeded() {
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")

        let window = RadialMenuWindow()
        window.showMenu(at: NSPoint(x: 400, y: 300), items: makeItems(count: 10), selectedText: "hello")

        let renderedItems = renderedMenuItems(in: window)
        XCTAssertEqual(renderedItems.count, 6)
        XCTAssertEqual(renderedItems.dropLast().map(\.title), ["Item 1", "Item 2", "Item 3", "Item 4", "Item 5"])
        XCTAssertTrue(matchesPageNext(renderedItems.last))

        window.hideMenu()
    }

    func testShowMenuInGTAModeKeepsWindowVisibleWithoutFullscreenFade() {
        UserDefaults.standard.set(true, forKey: "WheelBackdropEnabled")

        let window = RadialMenuWindow()
        window.showMenu(at: NSPoint(x: 400, y: 300), items: makeItems(count: 4), selectedText: "hello")

        XCTAssertEqual(window.alphaValue, 1.0, accuracy: 0.001)

        window.hideMenu()
    }

    func testSelectingNextPageShowsPreviousAndRemainingItems() throws {
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")

        let window = RadialMenuWindow()
        window.showMenu(at: NSPoint(x: 400, y: 300), items: makeItems(count: 10), selectedText: "hello")

        let radialMenuView = try XCTUnwrap(renderedMenuView(in: window))
        radialMenuView.onItemSelected?(RadialMenuItem(title: "Next", iconName: "arrow.uturn.forward", action: .pageNext))

        let renderedItems = renderedMenuItems(in: window)
        XCTAssertEqual(renderedItems.count, 6)
        XCTAssertTrue(matchesPagePrev(renderedItems.first))
        XCTAssertEqual(Array(renderedItems.dropFirst().dropLast()).map(\.title), ["Item 6", "Item 7", "Item 8", "Item 9"])
        XCTAssertTrue(matchesPageNext(renderedItems.last))

        window.hideMenu()
    }

    private func renderedMenuView(in window: RadialMenuWindow) -> RadialMenuView? {
        window.contentView?.subviews.compactMap { $0 as? RadialMenuView }.first
    }

    private func renderedMenuItems(in window: RadialMenuWindow) -> [RadialMenuItem] {
        renderedMenuView(in: window)?.menuItems ?? []
    }

    private func makeItems(count: Int) -> [RadialMenuItem] {
        (1...count).map { index in
            RadialMenuItem(title: "Item \(index)", iconName: "star", action: .builtIn(.copy))
        }
    }

    private func matchesPageNext(_ item: RadialMenuItem?) -> Bool {
        guard let item else { return false }
        if case .pageNext = item.action { return true }
        return false
    }

    private func matchesPagePrev(_ item: RadialMenuItem?) -> Bool {
        guard let item else { return false }
        if case .pagePrev = item.action { return true }
        return false
    }
}
