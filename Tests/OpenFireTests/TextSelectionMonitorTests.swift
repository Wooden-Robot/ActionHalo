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
}
