import XCTest
@testable import ActionHalo

final class RadialMenuWindowTests: GlobalStateTestCase {

    override func setUp() {
        super.setUp()
        isolateStandardUserDefaults(
            keys: ["maxRadialMenuItems", "WheelBackdropEnabled", "ringOpacity"]
        )
    }

    override func tearDown() {
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

    func testDismissRequestIsDelegatedToWindowOwner() {
        let window = RadialMenuWindow()
        window.showMenu(
            at: NSPoint(x: 400, y: 300),
            items: makeItems(count: 4),
            selectedText: "hello"
        )
        var requestCount = 0
        window.onDismissRequested = {
            requestCount += 1
        }

        window.requestDismissal()
        window.requestDismissal()

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(window.isVisible)
        window.hideMenu()
    }

    func testRepeatedMouseUpDispatchesExecutableActionOnlyOnce() throws {
        UserDefaults.standard.set(false, forKey: "WheelBackdropEnabled")
        let window = RadialMenuWindow()
        window.showMenu(
            at: NSPoint(x: 400, y: 300),
            items: makeItems(count: 4),
            selectedText: "hello"
        )
        let radialMenuView = try XCTUnwrap(renderedMenuView(in: window))
        var selectionCount = 0
        window.onItemSelected = { _ in
            selectionCount += 1
        }

        let radius = (radialMenuView.innerRadius + radialMenuView.outerRadius) / 2
        let point = NSPoint(
            x: radialMenuView.trackingCenter.x + radius * cos(.pi / 4),
            y: radialMenuView.trackingCenter.y + radius * sin(.pi / 4)
        )
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        )

        radialMenuView.mouseUp(with: event)
        radialMenuView.mouseUp(with: event)

        XCTAssertEqual(selectionCount, 1)
        window.hideMenu()
    }

    func testClickInOuterDirectionalAreaDispatchesAction() throws {
        UserDefaults.standard.set(false, forKey: "WheelBackdropEnabled")
        let window = RadialMenuWindow()
        window.showMenu(
            at: NSPoint(x: 400, y: 300),
            items: makeItems(count: 4),
            selectedText: "hello"
        )
        let radialMenuView = try XCTUnwrap(renderedMenuView(in: window))
        let contentView = try XCTUnwrap(window.contentView)
        var selectionCount = 0
        window.onItemSelected = { _ in
            selectionCount += 1
        }

        let radius = radialMenuView.outerRadius + 60
        let point = NSPoint(
            x: radialMenuView.trackingCenter.x + radius * cos(.pi / 4),
            y: radialMenuView.trackingCenter.y + radius * sin(.pi / 4)
        )
        let hitView = contentView.hitTest(point)
        XCTAssertTrue(
            hitView === radialMenuView,
            "Expected RadialMenuView, got \(String(describing: hitView.map { type(of: $0) }))"
        )

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        )
        hitView?.mouseUp(with: event)

        XCTAssertEqual(selectionCount, 1)
        window.hideMenu()
    }

    func testInvalidStoredPageSizeFallsBackToDefault() {
        XCTAssertEqual(RadialMenuWindow.validatedPageSize(0), 12)
        XCTAssertEqual(RadialMenuWindow.validatedPageSize(1), 12)
        XCTAssertEqual(RadialMenuWindow.validatedPageSize(2), 12)
        XCTAssertEqual(RadialMenuWindow.validatedPageSize(999), 12)
        XCTAssertEqual(RadialMenuWindow.validatedPageSize(6), 6)
        XCTAssertEqual(RadialMenuWindow.validatedPageSize(16), 16)
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
