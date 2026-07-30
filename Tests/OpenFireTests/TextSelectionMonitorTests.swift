import XCTest
@testable import OpenFire

final class TextSelectionMonitorTests: XCTestCase {
    func testNotificationName() {
        XCTAssertEqual(TextSelectionMonitor.textSelectedNotification.rawValue, "OpenFireTextSelected")
        XCTAssertEqual(TextSelectionMonitor.emptyTextInputClickedNotification.rawValue, "OpenFireEmptyTextInputClicked")
    }

    @MainActor
    func testNotificationPayloadsKeepVerifiedFocusedElementAndProcessIdentifier() throws {
        let focusedElement = AXUIElementCreateApplication(getpid())
        let location = NSPoint(x: 120, y: 240)
        let textSelectedUserInfo = TextSelectionMonitor.textSelectedNotificationUserInfo(
            text: "selected",
            location: location,
            processIdentifier: 42,
            focusedElement: focusedElement
        )
        let emptyInputUserInfo = TextSelectionMonitor.emptyTextInputClickedNotificationUserInfo(
            location: location,
            processIdentifier: 42,
            focusedElement: focusedElement
        )

        XCTAssertEqual(textSelectedUserInfo["text"] as? String, "selected")
        for userInfo in [textSelectedUserInfo, emptyInputUserInfo] {
            XCTAssertEqual(userInfo["processIdentifier"] as? NSNumber, NSNumber(value: 42))
            let deliveredElement = try XCTUnwrap(userInfo["focusedElement"])
            XCTAssertEqual(CFGetTypeID(deliveredElement as CFTypeRef), AXUIElementGetTypeID())
            XCTAssertTrue(CFEqual(deliveredElement as CFTypeRef, focusedElement))
        }
    }

    @MainActor
    func testSingletonInstance() {
        let instance1 = TextSelectionMonitor.shared
        let instance2 = TextSelectionMonitor.shared
        XCTAssertTrue(instance1 === instance2)
    }

    func testMonitoringStartFailureExplainsPermissionAndEventTapFailures() {
        XCTAssertEqual(
            TextSelectionMonitor.monitoringStartFailure(accessibilityEnabled: false, eventTapCreated: false),
            .accessibilityPermissionMissing
        )
        XCTAssertEqual(
            TextSelectionMonitor.monitoringStartFailure(accessibilityEnabled: true, eventTapCreated: false),
            .eventTapCreationFailed
        )
        XCTAssertNil(TextSelectionMonitor.monitoringStartFailure(accessibilityEnabled: true, eventTapCreated: true))
    }

    func testHasUsableClipboardTextTreatsWhitespaceOnlyAsEmpty() {
        XCTAssertFalse(TextSelectionMonitor.hasUsableClipboardText(nil))
        XCTAssertFalse(TextSelectionMonitor.hasUsableClipboardText(""))
        XCTAssertFalse(TextSelectionMonitor.hasUsableClipboardText("   \n\t"))
        XCTAssertTrue(TextSelectionMonitor.hasUsableClipboardText("hello"))
    }

    func testShouldSuppressForFileDragPasteboardDetectsDraggedFiles() {
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFileDragPasteboard(
            typeIdentifiers: [NSPasteboard.PasteboardType.fileURL.rawValue]
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFileDragPasteboard(
            typeIdentifiers: ["NSFilenamesPboardType"]
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldSuppressForFileDragPasteboard(
            typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
        ))
    }

    func testIsFileDragInProgressRequiresPasteboardChangeDuringGesture() {
        XCTAssertTrue(TextSelectionMonitor.isFileDragInProgress(
            dragPasteboardChangeCountAtMouseDown: 1,
            currentDragPasteboardChangeCount: 2,
            typeIdentifiers: [NSPasteboard.PasteboardType.fileURL.rawValue]
        ))
        XCTAssertFalse(TextSelectionMonitor.isFileDragInProgress(
            dragPasteboardChangeCountAtMouseDown: 2,
            currentDragPasteboardChangeCount: 2,
            typeIdentifiers: [NSPasteboard.PasteboardType.fileURL.rawValue]
        ))
        XCTAssertFalse(TextSelectionMonitor.isFileDragInProgress(
            dragPasteboardChangeCountAtMouseDown: 1,
            currentDragPasteboardChangeCount: 2,
            typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
        ))
    }

    func testDidFrontmostWindowMoveDetectsWindowDragByFrameChange() {
        let before = TextSelectionMonitor.FrontmostWindowSnapshot(
            ownerPID: 42,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let afterMoved = TextSelectionMonitor.FrontmostWindowSnapshot(
            ownerPID: 42,
            bounds: CGRect(x: 160, y: 140, width: 800, height: 600)
        )
        let afterSame = TextSelectionMonitor.FrontmostWindowSnapshot(
            ownerPID: 42,
            bounds: CGRect(x: 101, y: 100, width: 800, height: 600)
        )

        XCTAssertTrue(TextSelectionMonitor.didFrontmostWindowMove(from: before, to: afterMoved))
        XCTAssertFalse(TextSelectionMonitor.didFrontmostWindowMove(from: before, to: afterSame))
        XCTAssertFalse(TextSelectionMonitor.didFrontmostWindowMove(from: before, to: nil))
    }

    func testMouseGestureContextRequiresSameProcessAndWindowButAllowsFocusToChange() {
        let window = TextSelectionMonitor.FrontmostWindowSnapshot(
            windowID: 7,
            ownerPID: 42,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        XCTAssertTrue(TextSelectionMonitor.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            windowAtMouseDown: window,
            windowAtMouseUp: window
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: 42,
            currentProcessIdentifier: 99,
            windowAtMouseDown: window,
            windowAtMouseUp: window
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            windowAtMouseDown: window,
            windowAtMouseUp: window
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            windowAtMouseDown: window,
            windowAtMouseUp: nil
        ))
    }

    func testMouseGestureContextRejectsMovedOrReplacedWindow() {
        let before = TextSelectionMonitor.FrontmostWindowSnapshot(
            windowID: 7,
            ownerPID: 42,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let moved = TextSelectionMonitor.FrontmostWindowSnapshot(
            windowID: 7,
            ownerPID: 42,
            bounds: CGRect(x: 120, y: 100, width: 800, height: 600)
        )
        let replaced = TextSelectionMonitor.FrontmostWindowSnapshot(
            windowID: 8,
            ownerPID: 42,
            bounds: before.bounds
        )

        XCTAssertFalse(TextSelectionMonitor.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            windowAtMouseDown: before,
            windowAtMouseUp: moved
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            windowAtMouseDown: before,
            windowAtMouseUp: replaced
        ))
    }

    func testFrontmostWindowSnapshotCanUseMouseHitWindowInsteadOfFirstWindow() {
        let windows = [
            makeWindowInfo(windowID: 1, ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
            makeWindowInfo(windowID: 2, ownerPID: 42, bounds: CGRect(x: 400, y: 0, width: 300, height: 300))
        ]

        let snapshot = TextSelectionMonitor.currentFrontmostWindowSnapshot(
            frontmostProcessID: 42,
            windowInfoList: windows,
            containing: CGPoint(x: 450, y: 120)
        )

        XCTAssertEqual(snapshot?.windowID, 2)
        XCTAssertEqual(snapshot?.bounds, CGRect(x: 400, y: 0, width: 300, height: 300))
    }

    func testFrontmostWindowSnapshotCanMatchOriginalWindowIDAfterReorder() {
        let windows = [
            makeWindowInfo(windowID: 1, ownerPID: 42, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
            makeWindowInfo(windowID: 2, ownerPID: 42, bounds: CGRect(x: 460, y: 20, width: 300, height: 300))
        ]

        let snapshot = TextSelectionMonitor.currentFrontmostWindowSnapshot(
            frontmostProcessID: 42,
            windowInfoList: windows,
            matching: 2
        )

        XCTAssertEqual(snapshot?.windowID, 2)
        XCTAssertEqual(snapshot?.bounds, CGRect(x: 460, y: 20, width: 300, height: 300))
    }

    func testSelectionTriggerRequiresActualDragDistance() {
        XCTAssertFalse(TextSelectionMonitor.shouldTreatMouseInteractionAsSelectionTrigger(distance: 0, minimumDragDistance: 5))
        XCTAssertFalse(TextSelectionMonitor.shouldTreatMouseInteractionAsSelectionTrigger(distance: 4.99, minimumDragDistance: 5))
        XCTAssertTrue(TextSelectionMonitor.shouldTreatMouseInteractionAsSelectionTrigger(distance: 5, minimumDragDistance: 5))
    }

    func testObserverTimeoutLeavesRoomForCopyFallbackWorstCase() {
        let worstCaseCopyFallbackCompletion =
            TextSelectionMonitor.accessibilityPollingDelay +
            TextSelectionMonitor.copyFallbackStartDelay +
            AccessibilityManager.copyFallbackWorstCaseDuration

        XCTAssertGreaterThan(TextSelectionMonitor.observerTimeout, worstCaseCopyFallbackCompletion)
    }

    func testObserverTimeoutDoesNotCancelSelectionWhileCopyFallbackIsRunning() {
        XCTAssertFalse(
            TextSelectionMonitor.shouldCancelSelectionTaskOnObserverTimeout(
                copyFallbackInFlight: true
            )
        )
        XCTAssertTrue(
            TextSelectionMonitor.shouldCancelSelectionTaskOnObserverTimeout(
                copyFallbackInFlight: false
            )
        )
    }

    func testShouldHandleAccessibilityDragSelectionRequiresReadableChangedSelection() {
        let snapshotAtMouseDown = AccessibilityManager.SelectionSnapshot(
            text: nil,
            rangeLocation: 0,
            rangeLength: 0,
            hasReadableSelectedRangeAttribute: true
        )
        let changedSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "selected",
            rangeLocation: 4,
            rangeLength: 8,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )
        let unchangedSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "selected",
            rangeLocation: 4,
            rangeLength: 8,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )
        let unreadableSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "selected",
            rangeLocation: 4,
            rangeLength: 8
        )

        XCTAssertTrue(TextSelectionMonitor.shouldHandleAccessibilityDragSelection(
            snapshotAtMouseDown: snapshotAtMouseDown,
            currentSnapshot: changedSnapshot
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleAccessibilityDragSelection(
            snapshotAtMouseDown: changedSnapshot,
            currentSnapshot: unchangedSnapshot
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleAccessibilityDragSelection(
            snapshotAtMouseDown: snapshotAtMouseDown,
            currentSnapshot: unreadableSnapshot
        ))
    }

    func testShouldHandleCopiedDragSelectionPreservesTelegramFallbackWhenAccessibilityIsUnreadable() {
        let unreadableSnapshot = AccessibilityManager.SelectionSnapshot(
            text: nil,
            rangeLocation: nil,
            rangeLength: nil
        )
        let changedRangeSnapshot = AccessibilityManager.SelectionSnapshot(
            text: nil,
            rangeLocation: 4,
            rangeLength: 8,
            hasReadableSelectedRangeAttribute: true
        )

        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: nil,
            startedInTextContext: true,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: nil,
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: changedRangeSnapshot,
            frontmostBundleID: nil,
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "   \n",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: changedRangeSnapshot,
            frontmostBundleID: nil,
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "ru.keepcoder.Telegram",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "ru.keepcoder.Telegram",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false,
            previouslyAcquiredText: "selected"
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "ru.keepcoder.Telegram",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: true,
            endedInsideFocusedElementBounds: true
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "com.google.Chrome",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "company.thebrowser.Browser",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "com.apple.TextEdit",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: true,
            endedInsideFocusedElementBounds: true
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "com.example.browser",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: unreadableSnapshot,
            currentSnapshot: nil,
            frontmostBundleID: "com.microsoft.remotedesktop",
            startedInTextContext: false,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: false,
            endedInsideFocusedElementBounds: false
        ))
    }

    func testShouldHandleCopiedDragSelectionRejectsStaleCopiedTextWhenAccessibilityWasReadable() {
        let readableSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "selected",
            rangeLocation: 4,
            rangeLength: 8,
            hasReadableSelectedTextAttribute: true,
            hasReadableSelectedRangeAttribute: true
        )

        XCTAssertFalse(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "selected",
            snapshotAtMouseDown: readableSnapshot,
            currentSnapshot: readableSnapshot,
            frontmostBundleID: "ru.keepcoder.Telegram",
            startedInTextContext: true,
            endedInTextContext: true,
            startedInsideFocusedElementBounds: true,
            endedInsideFocusedElementBounds: true
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldHandleCopiedDragSelection(
            copiedText: "new selection",
            snapshotAtMouseDown: readableSnapshot,
            currentSnapshot: readableSnapshot,
            frontmostBundleID: "ru.keepcoder.Telegram",
            startedInTextContext: true,
            endedInTextContext: false,
            startedInsideFocusedElementBounds: true,
            endedInsideFocusedElementBounds: true
        ))
    }

    func testShouldSuppressForFrontmostAppSuppressesOpenFireItself() {
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.openfire.app",
            localizedName: "OpenFire"
        ))
    }

    func testShouldSuppressForFrontmostAppSuppressesKnownScreenCaptureTools() {
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.screencaptureui",
            localizedName: "Screenshot"
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.snipaste.macos",
            localizedName: "Snipaste"
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "pl.maketheweb.CleanShotX",
            localizedName: "CleanShot X"
        ))
    }

    func testShouldSuppressForFrontmostAppSuppressesFinderAndDesktopContexts() {
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.finder",
            localizedName: "Finder"
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.WindowManager",
            localizedName: "Desktop"
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.dock",
            localizedName: "Dock"
        ))
    }

    func testShouldSuppressForFrontmostAppKeepsRegularEditorsEnabled() {
        XCTAssertFalse(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.TextEdit",
            localizedName: "TextEdit"
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.microsoft.VSCode",
            localizedName: "Visual Studio Code"
        ))
    }

    func testShouldSuppressForFrontmostAppDoesNotSuppressAppsJustBecauseNameContainsDesktop() {
        XCTAssertFalse(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "ru.keepcoder.Telegram",
            localizedName: "Telegram Desktop"
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.microsoft.rdc.macos",
            localizedName: "Remote Desktop"
        ))
    }

    func testShouldSuppressForFrontmostAppAllowsEditableTextEvenInFinderContext() {
        XCTAssertFalse(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.finder",
            localizedName: "Finder",
            isFocusedSelectionEditable: true
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.finder",
            localizedName: "Finder",
            isFocusedSelectionEditable: false
        ))
    }

    func testCriticalAppSuppressionCannotBeBypassedByEditableElement() {
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.openfire.app",
            localizedName: "OpenFire",
            isFocusedSelectionEditable: true
        ))
        XCTAssertTrue(TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: "com.apple.screencaptureui",
            localizedName: "Screenshot",
            isFocusedSelectionEditable: true
        ))
    }

    func testEmptyTextInputCheckRespectsSuppressedAndExcludedApps() {
        XCTAssertTrue(TextSelectionMonitor.shouldAllowEmptyTextInputCheck(
            bundleID: "com.apple.Safari",
            localizedName: "Safari"
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldAllowEmptyTextInputCheck(
            bundleID: "com.apple.finder",
            localizedName: "Finder"
        ))
        XCTAssertFalse(TextSelectionMonitor.shouldAllowEmptyTextInputCheck(
            bundleID: "com.microsoft.Word",
            localizedName: "Microsoft Word",
            isAppExcluded: { $0 == "com.microsoft.Word" }
        ))
    }

    private func makeWindowInfo(windowID: CGWindowID, ownerPID: pid_t, bounds: CGRect, layer: Int = 0) -> [String: Any] {
        let boundsDictionary = bounds.dictionaryRepresentation
        return [
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: boundsDictionary
        ]
    }
}
