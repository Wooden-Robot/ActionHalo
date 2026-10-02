import XCTest
import QuartzCore
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

    func testOnlyExplicitKeyboardMenusRequestKeyFocus() throws {
        UserDefaults.standard.set(false, forKey: "WheelBackdropEnabled")
        for keyboardNavigation in [false, true] {
            let window = RadialMenuWindow()
            window.showMenu(
                at: NSPoint(x: 400, y: 300),
                items: makeItems(count: 4),
                selectedText: "hello",
                keyboardNavigation: keyboardNavigation
            )
            XCTAssertEqual(window.canBecomeKey, keyboardNavigation)
            XCTAssertFalse(window.canBecomeMain)
            XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
            if keyboardNavigation {
                let menu = try XCTUnwrap(renderedMenuView(in: window))
                XCTAssertTrue(window.firstResponder === menu)
            }
            window.hideMenu()
            XCTAssertFalse(window.canBecomeKey)
        }
    }

    func testKeyboardSelectionReleasesFocusBeforeActionCallback() throws {
        UserDefaults.standard.set(true, forKey: "WheelBackdropEnabled")
        let window = RadialMenuWindow()
        window.showMenu(
            at: NSPoint(x: 400, y: 300),
            items: makeItems(count: 4),
            selectedText: "hello",
            keyboardNavigation: true
        )
        let menu = try XCTUnwrap(renderedMenuView(in: window))
        let selected = expectation(description: "Action runs after keyboard focus is released")
        var callbackRan = false
        window.onItemSelected = { _ in
            callbackRan = true
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.canBecomeKey)
            selected.fulfill()
        }

        menu.onItemSelected?(try XCTUnwrap(menu.menuItems.first))
        XCTAssertFalse(window.isVisible, "Do not keep key focus during the backdrop fade-out")
        XCTAssertFalse(callbackRan, "Allow one main-loop turn for source focus to be published")
        wait(for: [selected], timeout: 1)
        window.hideMenu()
    }

    func testKeyboardPaginationKeepsMenuFocused() throws {
        UserDefaults.standard.set(6, forKey: "maxRadialMenuItems")
        UserDefaults.standard.set(false, forKey: "WheelBackdropEnabled")
        let window = RadialMenuWindow()
        window.showMenu(
            at: NSPoint(x: 400, y: 300),
            items: makeItems(count: 10),
            selectedText: "hello",
            keyboardNavigation: true
        )
        let menu = try XCTUnwrap(renderedMenuView(in: window))
        menu.onItemSelected?(try XCTUnwrap(menu.menuItems.last))
        XCTAssertTrue(matchesPagePrev(menu.menuItems.first))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.firstResponder === menu)
        XCTAssertTrue(window.isVisible)
        menu.onItemSelected?(try XCTUnwrap(menu.menuItems.first))
        XCTAssertEqual(menu.menuItems.first?.title, "Item 1")
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.firstResponder === menu)
        window.hideMenu()
    }

    func testNewPresentationCancelsDeferredKeyboardSelection() throws {
        UserDefaults.standard.set(false, forKey: "WheelBackdropEnabled")
        let window = RadialMenuWindow()
        let items = makeItems(count: 4)
        window.showMenu(
            at: NSPoint(x: 400, y: 300), items: items, selectedText: "old",
            keyboardNavigation: true
        )
        let menu = try XCTUnwrap(renderedMenuView(in: window))
        var selectionCount = 0
        window.onItemSelected = { _ in selectionCount += 1 }
        menu.onItemSelected?(try XCTUnwrap(menu.menuItems.first))
        window.showMenu(at: NSPoint(x: 400, y: 300), items: items, selectedText: "new")
        let nextTurn = expectation(description: "Deferred selection has been checked")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertEqual(selectionCount, 0)
        XCTAssertFalse(window.canBecomeKey)
        window.hideMenu()
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

    func testShowMenuIsImmediatelyVisibleWithoutEntranceAnimations() throws {
        UserDefaults.standard.set(0.25, forKey: "ringOpacity")
        for backdropEnabled in [true, false] {
            UserDefaults.standard.set(backdropEnabled, forKey: "WheelBackdropEnabled")
            let window = RadialMenuWindow()
            window.showMenu(at: NSPoint(x: 400, y: 300), items: makeItems(count: 4), selectedText: "hello")
            defer { window.hideMenu() }

            let menu = try XCTUnwrap(renderedMenuView(in: window))
            let menuLayer = try XCTUnwrap(menu.layer)
            let glass = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.first)
            let backdrop = try XCTUnwrap(window.contentView?.subviews.first)
            let vignette = try XCTUnwrap(backdrop.layer?.sublayers?.first)

            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(window.alphaValue, 1.0, accuracy: 0.001)
            XCTAssertEqual(menu.alphaValue, 1.0, accuracy: 0.001)
            XCTAssertTrue(CATransform3DIsIdentity(menuLayer.transform))
            XCTAssertTrue(menuLayer.animationKeys()?.isEmpty ?? true)
            XCTAssertEqual(glass.alphaValue, backdropEnabled ? 1.0 : 0.25, accuracy: 0.001)
            XCTAssertEqual(backdrop.alphaValue, backdropEnabled ? 0.94 : 0, accuracy: 0.001)
            XCTAssertEqual(vignette.opacity, backdropEnabled ? 0.72 : 0, accuracy: 0.001)
            XCTAssertTrue(vignette.animationKeys()?.isEmpty ?? true)
        }
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
