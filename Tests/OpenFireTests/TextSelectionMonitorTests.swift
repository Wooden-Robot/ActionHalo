import XCTest
@testable import OpenFire

final class TextSelectionMonitorTests: XCTestCase {
    func testNotificationName() {
        XCTAssertEqual(TextSelectionMonitor.textSelectedNotification.rawValue, "OpenFireTextSelected")
        XCTAssertEqual(TextSelectionMonitor.emptyTextInputClickedNotification.rawValue, "OpenFireEmptyTextInputClicked")
    }

    func testSingletonInstance() {
        let instance1 = TextSelectionMonitor.shared
        let instance2 = TextSelectionMonitor.shared
        XCTAssertTrue(instance1 === instance2)
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

    func testSelectionTriggerRequiresActualDragDistance() {
        XCTAssertFalse(TextSelectionMonitor.shouldTreatMouseInteractionAsSelectionTrigger(distance: 0, minimumDragDistance: 5))
        XCTAssertFalse(TextSelectionMonitor.shouldTreatMouseInteractionAsSelectionTrigger(distance: 4.99, minimumDragDistance: 5))
        XCTAssertTrue(TextSelectionMonitor.shouldTreatMouseInteractionAsSelectionTrigger(distance: 5, minimumDragDistance: 5))
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
}
