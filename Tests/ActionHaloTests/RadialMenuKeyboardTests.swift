import AppKit
import XCTest
@testable import ActionHalo

@MainActor
final class RadialMenuKeyboardTests: XCTestCase {
    func testNavigationSkipsDisabledItemsWrapsAndExecutesOnlyOnce() throws {
        let view = makeView()
        var selections: [String] = []
        view.onItemSelected = { selections.append($0.title) }
        view.prepareForKeyboardNavigation()
        XCTAssertEqual(focusedLabel(in: view), "First")

        for (key, modifiers, expected): (UInt16, NSEvent.ModifierFlags, String) in [
            (124, [], "Last"), (125, [], "First"),
            (48, [.shift], "Last"), (126, [], "First"),
            (48, [], "Last"), (123, [], "First")
        ] {
            view.keyDown(with: try event(key, modifiers: modifiers))
            XCTAssertEqual(focusedLabel(in: view), expected)
        }

        view.keyDown(with: try event(36, isRepeat: true))
        XCTAssertTrue(selections.isEmpty)
        view.keyDown(with: try event(36))
        view.keyDown(with: try event(36))
        XCTAssertEqual(selections, ["First"])
    }

    func testKeyboardIsOptInAndEscapeDisablesOtherExecutionPaths() throws {
        let view = makeView()
        var selections = 0
        var dismissals = 0
        view.onItemSelected = { _ in selections += 1 }
        view.onDismissRequested = { dismissals += 1 }

        view.keyDown(with: try event(36))
        view.keyDown(with: try event(53))
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(dismissals, 0)

        view.prepareForKeyboardNavigation()
        view.keyDown(with: try event(53))
        view.keyDown(with: try event(53))
        XCTAssertFalse(view.activateItem(at: 0))
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(selections, 0)
    }

    func testMouseHoverKeepsAccessibilityFocusAndKeyboardExecutionInSync() throws {
        let view = makeView()
        var selections: [String] = []
        view.onItemSelected = { selections.append($0.title) }
        view.prepareForKeyboardNavigation()
        XCTAssertEqual(focusedLabel(in: view), "First")
        let pointer = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 100, y: 250), modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1,
            clickCount: 0, pressure: 0
        ))

        view.mouseMoved(with: pointer)
        XCTAssertEqual(focusedLabel(in: view), "Last")
        view.mouseExited(with: pointer)
        XCTAssertNil(focusedLabel(in: view))
        view.keyDown(with: try event(36))
        XCTAssertTrue(selections.isEmpty)

        view.mouseMoved(with: pointer)
        view.keyDown(with: try event(36))
        XCTAssertEqual(selections, ["Last"])
    }

    func testEmptyDisabledAndPagedMenusHaveSafeInitialKeyboardSelection() throws {
        let view = makeView()
        view.menuItems = []
        view.buildMenu()
        view.prepareForKeyboardNavigation()
        view.keyDown(with: try event(48))
        view.keyDown(with: try event(36))
        XCTAssertNil(focusedLabel(in: view))

        view.menuItems = [RadialMenuItem(title: "Disabled", iconName: "star", action: .builtIn(.copy), isExecutable: false)]
        view.buildMenu()
        view.prepareForKeyboardNavigation()
        view.keyDown(with: try event(123))
        XCTAssertNil(focusedLabel(in: view))
        XCTAssertFalse(view.activateItem(at: 0))

        view.menuItems = [
            RadialMenuItem(title: "Previous", iconName: "arrow.left", action: .pagePrev),
            RadialMenuItem(title: "Action", iconName: "star", action: .builtIn(.copy))
        ]
        view.buildMenu()
        view.beginInteractionSession()
        view.prepareForKeyboardNavigation()
        XCTAssertEqual(focusedLabel(in: view), "Action")
        view.keyDown(with: try event(48, modifiers: [.shift]))
        XCTAssertEqual(focusedLabel(in: view), "Previous")
    }

    private func makeView() -> RadialMenuView {
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.visualCenter = NSPoint(x: 200, y: 200)
        view.trackingCenter = view.visualCenter
        view.menuItems = [
            RadialMenuItem(title: "First", iconName: "star", action: .builtIn(.copy)),
            RadialMenuItem(title: "Disabled", iconName: "star", action: .builtIn(.cut), isExecutable: false),
            RadialMenuItem(title: "Last", iconName: "star", action: .builtIn(.search))
        ]
        view.buildMenu()
        return view
    }

    private func focusedLabel(in view: RadialMenuView) -> String? {
        (view.accessibilityChildren() as? [NSAccessibilityElement])?
            .first(where: { $0.isAccessibilityFocused() })?.accessibilityLabel()
    }

    private func event(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat,
            keyCode: keyCode
        ))
    }
}
