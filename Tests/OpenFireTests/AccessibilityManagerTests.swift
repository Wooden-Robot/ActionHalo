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

    func testShouldTreatElementAsTextAllowsPageTextInsideAXBrowserWithoutAppWhitelist() {
        let result = AccessibilityManager.shouldTreatElementAsText(
            role: kAXStaticTextRole,
            ancestorRoles: ["AXGroup", "AXBrowser", "AXScrollArea"],
            bundleID: "com.example.webviewhost",
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

    func testShouldTreatElementAsTextAllowsGenericAXGroupInsideWebContent() {
        let result = AccessibilityManager.shouldTreatElementAsText(
            role: "AXGroup",
            ancestorRoles: ["AXWebArea", "AXBrowser", "AXScrollArea"],
            bundleID: "com.example.codexlikeapp",
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

    func testShouldTreatFocusedRoleAsTextSelectionContextAllowsTelegramStyleAXGroup() {
        let result = AccessibilityManager.shouldTreatFocusedRoleAsTextSelectionContext(
            role: "AXGroup",
            ancestorRoles: ["AXScrollArea", "AXWindow"],
            bundleID: "ru.keepcoder.Telegram"
        )

        XCTAssertTrue(result)
    }

    func testIsLikelyRichTextSelectionHostUsesPreciseBundleMatching() {
        XCTAssertTrue(AccessibilityManager.isLikelyRichTextSelectionHost(bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(AccessibilityManager.isLikelyRichTextSelectionHost(bundleID: "com.openai.codex"))
        XCTAssertFalse(AccessibilityManager.isLikelyRichTextSelectionHost(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(AccessibilityManager.isLikelyRichTextSelectionHost(bundleID: "com.microsoft.remotedesktop"))
    }

    func testShouldTreatFocusedRoleAsTextSelectionContextRejectsBroadCodeHeuristicMatches() {
        let result = AccessibilityManager.shouldTreatFocusedRoleAsTextSelectionContext(
            role: "AXGroup",
            ancestorRoles: ["AXScrollArea", "AXWindow"],
            bundleID: "com.apple.dt.Xcode"
        )

        XCTAssertFalse(result)
    }

    func testShouldTreatElementAsTextRejectsGenericAXGroupInsideStructuralContainers() {
        let result = AccessibilityManager.shouldTreatElementAsText(
            role: "AXGroup",
            ancestorRoles: ["AXWebArea", kAXRowRole, kAXOutlineRole],
            bundleID: "com.example.sidebar",
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

    func testShouldRestorePasteboardSnapshotOnlyAfterFreshCopiedTextArrives() {
        XCTAssertTrue(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialChangeCount: 10,
            observedChangeCount: 11,
            copiedText: "copied"
        ))
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialChangeCount: 10,
            observedChangeCount: 10,
            copiedText: "copied"
        ))
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialChangeCount: 10,
            observedChangeCount: 11,
            copiedText: "   \n"
        ))
    }

    func testShouldTreatCopiedTextAsFreshWhenStringChangesWithoutChangeCount() {
        XCTAssertTrue(AccessibilityManager.shouldTreatCopiedTextAsFresh(
            initialChangeCount: 10,
            observedChangeCount: 10,
            initialString: "before",
            observedString: "after"
        ))
        XCTAssertFalse(AccessibilityManager.shouldTreatCopiedTextAsFresh(
            initialChangeCount: 10,
            observedChangeCount: 10,
            initialString: "before",
            observedString: "before"
        ))
    }

    func testShouldAssumeFocusedTextInputContainsClickWhenBoundsUnavailableIsConservative() {
        XCTAssertFalse(AccessibilityManager.shouldAssumeFocusedTextInputContainsClickWhenBoundsUnavailable())
    }

    func testSelectionSnapshotTracksWhetherAccessibilitySelectionStateIsReadable() {
        let unreadableSnapshot = AccessibilityManager.SelectionSnapshot(
            text: nil,
            rangeLocation: nil,
            rangeLength: nil
        )
        let textReadableSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "selected",
            rangeLocation: nil,
            rangeLength: nil,
            hasReadableSelectedTextAttribute: true
        )
        let rangeReadableSnapshot = AccessibilityManager.SelectionSnapshot(
            text: nil,
            rangeLocation: 4,
            rangeLength: 8,
            hasReadableSelectedRangeAttribute: true
        )

        XCTAssertFalse(unreadableSnapshot.isReadable)
        XCTAssertTrue(textReadableSnapshot.isReadable)
        XCTAssertTrue(rangeReadableSnapshot.isReadable)
        XCTAssertFalse(unreadableSnapshot.canReadSelectedTextViaAccessibility)
        XCTAssertTrue(textReadableSnapshot.canReadSelectedTextViaAccessibility)
        XCTAssertFalse(rangeReadableSnapshot.canReadSelectedTextViaAccessibility)
    }

    func testDidSelectionChangeDetectsTextAndRangeUpdates() {
        let previousSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "before",
            rangeLocation: 0,
            rangeLength: 6,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )
        let changedTextSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "after",
            rangeLocation: 0,
            rangeLength: 5,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )
        let changedRangeSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "before",
            rangeLocation: 3,
            rangeLength: 6,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )
        let unchangedSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "before",
            rangeLocation: 0,
            rangeLength: 6,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )

        XCTAssertTrue(AccessibilityManager.didSelectionChange(from: previousSnapshot, to: changedTextSnapshot))
        XCTAssertTrue(AccessibilityManager.didSelectionChange(from: previousSnapshot, to: changedRangeSnapshot))
        XCTAssertFalse(AccessibilityManager.didSelectionChange(from: previousSnapshot, to: unchangedSnapshot))
    }
}
