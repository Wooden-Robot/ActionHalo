import AppKit
import XCTest
@testable import ActionHalo

@MainActor
final class MenuDismissalTests: GlobalStateTestCase {
    override func setUp() {
        super.setUp()
        isolateStandardUserDefaults(keys: ["WheelBackdropEnabled"])
    }

    func testRingKeepsNearbyClicksAndDismissesClicksBeyondPaddingInBothLayouts() throws {
        for backdropEnabled in [true, false] {
            UserDefaults.standard.set(backdropEnabled, forKey: "WheelBackdropEnabled")
            let ring = makeRing()
            defer { ring.hideMenu() }
            let view = try XCTUnwrap(ring.contentView?.subviews.compactMap { $0 as? RadialMenuView }.first)

            for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                for (distance, expected) in [
                    (CGFloat(0), false),
                    (view.outerRadius, false),
                    (view.outerRadius + 59, false),
                    (view.outerRadius + 61, true)
                ] {
                    let point = view.convert(NSPoint(x: view.trackingCenter.x + distance, y: view.trackingCenter.y), to: nil)
                    let event = try mouseEvent(type, window: ring, point: point)
                    XCTAssertEqual(shouldDismiss(event, ring: ring), expected, "Backdrop: \(backdropEnabled), distance: \(distance), event: \(type)")
                }
            }
        }
    }

    func testPopupButtonsRemainClickableButClicksInAnotherAppWindowDismissEitherMenu() throws {
        let ring = makeRing()
        let popup = PastePopupWindow()
        popup.show(at: NSPoint(x: 400, y: 300))
        let settings = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        defer {
            ring.hideMenu()
            popup.hidePopup()
            settings.close()
        }

        for x: CGFloat in [37, 111] {
            let event = try mouseEvent(.leftMouseDown, window: popup, point: NSPoint(x: x, y: 16))
            XCTAssertFalse(shouldDismiss(event, popup: popup))
            let screenPoint = popup.convertPoint(toScreen: event.locationInWindow)
            XCTAssertFalse(AppDelegate.shouldDismissMenus(
                atScreenPoint: screenPoint, radialMenuWindow: nil, pastePopupWindow: popup
            ))
            XCTAssertFalse(shouldDismiss(try mouseEvent(.leftMouseDown, window: nil, point: screenPoint), popup: popup))
        }
        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try mouseEvent(type, window: settings)
            XCTAssertTrue(shouldDismiss(event, ring: ring))
            XCTAssertTrue(shouldDismiss(event, popup: popup))
            XCTAssertTrue(shouldDismiss(event), "Outside clicks also cancel pending popup presentation")
        }
    }

    func testClicksDeliveredToOtherAppsRespectTheRingBufferInScreenCoordinates() throws {
        for backdropEnabled in [false, true] {
            UserDefaults.standard.set(backdropEnabled, forKey: "WheelBackdropEnabled")
            let ring = makeRing()
            defer { ring.hideMenu() }
            let view = try XCTUnwrap(ring.contentView?.subviews.compactMap { $0 as? RadialMenuView }.first)

            for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                for (padding, expected): (CGFloat, Bool) in [(59, false), (60, false), (61, true)] {
                    let localPoint = view.convert(NSPoint(
                        x: view.trackingCenter.x + view.outerRadius + padding,
                        y: view.trackingCenter.y
                    ), to: nil)
                    let screenPoint = ring.convertPoint(toScreen: localPoint)
                    let event = try mouseEvent(type, window: nil, point: screenPoint)
                    XCTAssertNil(event.window)
                    XCTAssertEqual(shouldDismiss(event, ring: ring), expected)
                    XCTAssertEqual(AppDelegate.shouldDismissMenus(
                        atScreenPoint: screenPoint, radialMenuWindow: ring, pastePopupWindow: nil
                    ), expected)
                }
            }
        }
    }

    func testPhysicalMouseButtonEventsForwardTheirCapturedCoordinates() {
        let monitor = TextSelectionMonitor.shared
        let previousHandler = monitor.onPhysicalMouseDown
        defer {
            monitor.cancelPendingInteraction()
            monitor.onPhysicalMouseDown = previousHandler
        }
        var received: [(type: CGEventType, point: NSPoint, timestamp: CGEventTimestamp)] = []
        monitor.onPhysicalMouseDown = { type, point, timestamp in
            received.append((type, point, timestamp))
            return .noMenu
        }
        let buttons: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        for (index, type) in buttons.enumerated() {
            XCTAssertNotEqual(TextSelectionMonitor.mouseEventMask & (1 << type.rawValue), 0)
            let point = NSPoint(x: -400 + index * 100, y: 1200 + index * 100)
            let timestamp = CGEventTimestamp(index + 1) * 1_000_000_000
            monitor.handleMouseButtonEvent(type, at: point, timestamp: timestamp)
            monitor.cancelPendingInteraction()
            XCTAssertEqual(received.last?.type, type)
            XCTAssertEqual(received.last?.point, point)
            XCTAssertEqual(received.last?.timestamp, timestamp)
            XCTAssertEqual(received.count, index + 1)
        }
        for type: CGEventType in [.leftMouseUp, .rightMouseUp, .mouseMoved] {
            monitor.handleMouseButtonEvent(type, at: .zero)
        }
        XCTAssertEqual(received.count, 3, "Releases and pointer movement must not dismiss a new menu")
    }

    func testMenuClickDoesNotRestartEmptyInputDetectionOnMouseUp() async throws {
        let monitor = TextSelectionMonitor.shared
        let previousHandler = monitor.onPhysicalMouseDown
        defer {
            monitor.cancelPendingInteraction()
            monitor.onPhysicalMouseDown = previousHandler
        }
        guard let window = TextSelectionMonitor.currentFrontmostWindowSnapshot(
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ), let point = AccessibilityManager.appKitScreenPoint(for: NSPoint(
            x: window.bounds.midX, y: window.bounds.midY
        )) else {
            throw XCTSkip("A source application window is required for this mouse-routing integration test")
        }

        monitor.onPhysicalMouseDown = { _, _, _ in .noMenu }
        monitor.handleMouseButtonEvent(.leftMouseDown, at: point)
        monitor.handleMouseButtonEvent(.leftMouseUp, at: point)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard monitor.lastEmptyInputCheckLocation == point else {
            throw XCTSkip("The foreground application does not allow text gesture monitoring")
        }

        let menuPoint = NSPoint(x: point.x + 1, y: point.y + 1)
        monitor.onPhysicalMouseDown = { _, _, _ in .menuClick }
        monitor.handleMouseButtonEvent(.leftMouseDown, at: menuPoint)
        monitor.onPhysicalMouseDown = { _, _, _ in .noMenu }
        monitor.handleMouseButtonEvent(.leftMouseUp, at: menuPoint)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(monitor.lastEmptyInputCheckLocation, point,
                       "A menu click must not reopen the paste popup and cancel its pending paste")
    }

    func testOutsideDismissalDoesNotReopenPopupOnMouseUpAndNextClickCanOpenIt() async throws {
        let monitor = TextSelectionMonitor.shared
        let previousHandler = monitor.onPhysicalMouseDown
        defer {
            monitor.cancelPendingInteraction()
            monitor.onPhysicalMouseDown = previousHandler
        }
        guard let window = TextSelectionMonitor.currentFrontmostWindowSnapshot(
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ), let point = AccessibilityManager.appKitScreenPoint(for: NSPoint(
            x: window.bounds.midX, y: window.bounds.midY
        )) else {
            throw XCTSkip("A source application window is required for this mouse-routing integration test")
        }

        monitor.onPhysicalMouseDown = { _, _, _ in .noMenu }
        monitor.handleMouseButtonEvent(.leftMouseDown, at: point)
        monitor.handleMouseButtonEvent(.leftMouseUp, at: point)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard monitor.lastEmptyInputCheckLocation == point else {
            throw XCTSkip("The foreground application does not allow text gesture monitoring")
        }

        let dismissalPoint = NSPoint(x: point.x + 1, y: point.y + 1)
        monitor.onPhysicalMouseDown = { _, _, _ in .dismissedMenu }
        monitor.handleMouseButtonEvent(.leftMouseDown, at: dismissalPoint)
        monitor.handleMouseButtonEvent(.leftMouseUp, at: dismissalPoint)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(monitor.lastEmptyInputCheckLocation, point,
                       "The click that dismisses a menu must not reopen the paste popup on mouse-up")

        let nextPoint = NSPoint(x: point.x + 2, y: point.y + 2)
        monitor.onPhysicalMouseDown = { _, _, _ in .noMenu }
        monitor.handleMouseButtonEvent(.leftMouseDown, at: nextPoint)
        monitor.handleMouseButtonEvent(.leftMouseUp, at: nextPoint)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(monitor.lastEmptyInputCheckLocation, nextPoint,
                       "A later ordinary click must still be able to open a paste popup")
    }

    func testOutsideDismissalSurvivesEitherAppKitAndPhysicalMouseEventOrder() throws {
        for appKitFirst in [true, false] {
            let delegate = AppDelegate()
            let popup = PastePopupWindow()
            defer {
                delegate.setEnabled(false)
                popup.close()
            }
            delegate.presentPastePopup(popup, at: NSPoint(x: 400, y: 300))
            let event = try mouseEvent(.leftMouseDown, window: nil)
            let cgEvent = try XCTUnwrap(event.cgEvent)
            let point = try XCTUnwrap(AccessibilityManager.appKitScreenPoint(for: cgEvent.location))
            XCTAssertFalse(popup.frame.contains(point))

            if appKitFirst {
                delegate.handleMenuDismissEvent(event)
                XCTAssertTrue(popup.ignoresMouseEvents)
            }

            XCTAssertEqual(delegate.handlePhysicalMouseDownStarted(
                .leftMouseDown, at: point, timestamp: cgEvent.timestamp
            ), .dismissedMenu, "AppKit first: \(appKitFirst)")

            if !appKitFirst {
                delegate.handleMenuDismissEvent(event)
            }
            XCTAssertTrue(popup.ignoresMouseEvents)
        }
    }

    func testPhysicalSecondaryClicksInsidePopupDismissIt() {
        for type: CGEventType in [.rightMouseDown, .otherMouseDown] {
            let delegate = AppDelegate()
            let popup = PastePopupWindow()
            defer {
                delegate.setEnabled(false)
                popup.close()
            }
            delegate.presentPastePopup(popup, at: NSPoint(x: 400, y: 300))
            let point = popup.convertPoint(toScreen: NSPoint(x: 37, y: 16))

            XCTAssertEqual(delegate.handlePhysicalMouseDownStarted(
                type, at: point, timestamp: 1_000_000_000
            ), .dismissedMenu)
            XCTAssertTrue(popup.ignoresMouseEvents)
        }
    }

    func testPhysicalLeftClickInsidePopupKeepsPasteButtonUsable() throws {
        let delegate = AppDelegate()
        let popup = PastePopupWindow()
        defer {
            delegate.setEnabled(false)
            popup.close()
        }
        var pasteCount = 0
        popup.onPasteClicked = { pasteCount += 1 }
        delegate.presentPastePopup(popup, at: NSPoint(x: 400, y: 300))
        let point = popup.convertPoint(toScreen: NSPoint(x: 37, y: 16))

        XCTAssertEqual(delegate.handlePhysicalMouseDownStarted(
            .leftMouseDown, at: point, timestamp: 1_000_000_000
        ), .menuClick)
        XCTAssertFalse(popup.ignoresMouseEvents)
        let pasteButton = try XCTUnwrap(popup.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == "Paste".localized })
        pasteButton.performClick(nil)
        XCTAssertEqual(pasteCount, 1)
    }

    func testTypingShortcutsAndEscapeDismissMousePresentedMenusRegardlessOfEventWindow() throws {
        let ring = makeRing()
        let popup = PastePopupWindow()
        popup.show(at: NSPoint(x: 400, y: 300))
        defer {
            ring.hideMenu()
            popup.hidePopup()
        }

        for window: NSWindow? in [nil, ring, popup] {
            for (key, modifiers): (UInt16, NSEvent.ModifierFlags) in [(0, []), (51, []), (53, []), (9, [.command]), (124, [])] {
                let event = try keyEvent(key, window: window, modifiers: modifiers)
                XCTAssertTrue(shouldDismiss(event, ring: ring))
                XCTAssertTrue(shouldDismiss(event, popup: popup))
                XCTAssertTrue(shouldDismiss(event))
            }
        }
    }

    func testExplicitKeyboardNavigationStaysInRingButSourceKeysAndShortcutsDismiss() throws {
        let ring = makeRing(keyboardNavigation: true)
        defer { ring.hideMenu() }

        for (key, modifiers): (UInt16, NSEvent.ModifierFlags) in [(123, []), (124, []), (48, []), (48, [.shift]), (36, []), (49, [])] {
            XCTAssertFalse(shouldDismiss(try keyEvent(key, window: ring, modifiers: modifiers), ring: ring))
            XCTAssertTrue(shouldDismiss(try keyEvent(key, window: nil, modifiers: modifiers), ring: ring))
        }
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            XCTAssertTrue(shouldDismiss(try keyEvent(0, window: ring, modifiers: modifier), ring: ring))
        }
        for key: UInt16 in [0, 53] {
            let event = try keyEvent(key, window: ring)
            XCTAssertFalse(shouldDismiss(event, ring: ring), "The view owns ordinary dismissal keys in keyboard mode")
        }
    }

    func testModifierKeysAndSecondaryClicksDismissPastePopup() throws {
        let popup = PastePopupWindow()
        popup.show(at: NSPoint(x: 400, y: 300))
        defer { popup.hidePopup() }

        for type: NSEvent.EventType in [.rightMouseDown, .otherMouseDown] {
            XCTAssertTrue(shouldDismiss(try mouseEvent(type, window: popup, point: NSPoint(x: 37, y: 16)), popup: popup))
        }
        for modifiers: NSEvent.ModifierFlags in [.shift, .command, .control, .option, .capsLock, []] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 1,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 56
            ))
            XCTAssertTrue(shouldDismiss(event, popup: popup))
        }
        XCTAssertTrue(AppDelegate.menuDismissEventMask.contains(.flagsChanged))
        XCTAssertTrue(TextSelectionMonitor.emptyInputCancelEventMask.contains(.flagsChanged))
        XCTAssertTrue(TextSelectionMonitor.pendingInteractionCancelEventMask.contains(.otherMouseDown))
    }

    func testMouseMovementDoesNotDismissAndAllMouseButtonsAreMonitored() throws {
        XCTAssertFalse(shouldDismiss(try mouseEvent(.mouseMoved, window: nil)))
        for mask: NSEvent.EventTypeMask in [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel] {
            XCTAssertTrue(AppDelegate.menuDismissEventMask.contains(mask))
        }
    }

    private func makeRing(keyboardNavigation: Bool = false) -> RadialMenuWindow {
        let ring = RadialMenuWindow()
        ring.showMenu(at: NSPoint(x: 400, y: 300), items: [
            RadialMenuItem(title: "Copy", iconName: "doc.on.doc", action: .builtIn(.copy))
        ], selectedText: "hello", keyboardNavigation: keyboardNavigation)
        return ring
    }

    private func shouldDismiss(_ event: NSEvent, ring: RadialMenuWindow? = nil, popup: PastePopupWindow? = nil) -> Bool {
        AppDelegate.shouldDismissMenus(for: event, radialMenuWindow: ring, pastePopupWindow: popup)
    }

    private func mouseEvent(_ type: NSEvent.EventType, window: NSWindow?, point: NSPoint = .zero) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0
        ))
    }

    private func keyEvent(_ key: UInt16, window: NSWindow?, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: key
        ))
    }
}
