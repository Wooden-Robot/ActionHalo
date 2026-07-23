import XCTest
@testable import OpenFire

final class AccessibilityManagerTests: XCTestCase {
    func testAccessibilityScreenPointUsesPrimaryGlobalCoordinates() throws {
        guard let primaryScreen = NSScreen.screens.first else {
            throw XCTSkip("No main screen available")
        }

        let point = NSPoint(x: primaryScreen.frame.midX, y: primaryScreen.frame.midY)
        let converted = try XCTUnwrap(AccessibilityManager.shared.accessibilityScreenPoint(for: point))

        XCTAssertEqual(converted.x, point.x, accuracy: 0.001)
        XCTAssertEqual(converted.y, primaryScreen.frame.maxY - point.y, accuracy: 0.001)
    }

    func testCoreGraphicsScreenPointUsesPrimaryDisplayOriginForDisplayBelow() {
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

    func testCoreGraphicsScreenPointKeepsPrimaryOriginWhenDisplayIsAbove() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 0, y: 900, width: 1920, height: 1080)
        ]
        let point = NSPoint(x: 500, y: 1_000)

        let converted = AccessibilityManager.coreGraphicsScreenPoint(for: point, screenFrames: screens)

        XCTAssertEqual(converted?.x ?? .zero, 500, accuracy: 0.001)
        XCTAssertEqual(converted?.y ?? .zero, -100, accuracy: 0.001)
    }

    func testAccessibilityAndCoreGraphicsConversionsUseSameGlobalSpace() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: -1080, width: 1920, height: 1080)
        ]
        let point = NSPoint(x: 1_600, y: -120)

        let accessibilityPoint = AccessibilityManager.shared.accessibilityScreenPoint(
            for: point,
            screenFrames: screens
        )
        let coreGraphicsPoint = AccessibilityManager.coreGraphicsScreenPoint(
            for: point,
            screenFrames: screens
        )

        XCTAssertEqual(accessibilityPoint, coreGraphicsPoint)
        XCTAssertEqual(accessibilityPoint?.y ?? .zero, 1_020, accuracy: 0.001)
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

    func testShouldAllowBlindCopyFallbackCoversBrowsersWithoutMatchingRemoteDesktop() {
        XCTAssertTrue(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "com.google.Chrome"))
        XCTAssertTrue(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "com.brave.Browser"))
        XCTAssertTrue(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "com.openai.codex"))
        XCTAssertTrue(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "ru.keepcoder.Telegram"))
        XCTAssertFalse(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: "com.microsoft.remotedesktop"))
    }

    func testContextlessBlindCopyFallbackRequiresExactKnownApp() {
        XCTAssertTrue(AccessibilityManager.shouldAllowContextlessBlindCopyFallback(bundleID: "com.google.Chrome"))
        XCTAssertTrue(AccessibilityManager.shouldAllowContextlessBlindCopyFallback(bundleID: "org.mozilla.firefox"))
        XCTAssertFalse(AccessibilityManager.shouldAllowContextlessBlindCopyFallback(bundleID: "com.example.browser"))
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

    func testShouldRestorePasteboardSnapshotRequiresClipboardToStillContainObservedCopy() {
        XCTAssertTrue(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialChangeCount: 10,
            observedChangeCount: 11,
            copiedText: "copied",
            initialString: "before",
            currentChangeCount: 11,
            currentString: "copied"
        ))
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialChangeCount: 10,
            observedChangeCount: 11,
            copiedText: "copied",
            initialString: "before",
            currentChangeCount: 12,
            currentString: "other app update"
        ))
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialChangeCount: 10,
            observedChangeCount: 11,
            copiedText: "copied",
            initialString: "before",
            currentChangeCount: 11,
            currentString: "different text"
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

    func testCopyFallbackWorstCaseIncludesLatePollingWindow() {
        let expected =
            AccessibilityManager.copyFallbackPreflightDelay +
            AccessibilityManager.copyFallbackKeyGap +
            Double(
                AccessibilityManager.copyFallbackPollAttempts +
                AccessibilityManager.copyFallbackLatePollAttempts
            ) * AccessibilityManager.copyFallbackPollInterval

        XCTAssertEqual(AccessibilityManager.copyFallbackWorstCaseDuration, expected, accuracy: 0.0001)
        XCTAssertGreaterThan(AccessibilityManager.copyFallbackLatePollAttempts, 0)
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

    func testCopyFallbackCoordinatorOnlyKeepsNewestRequestActive() {
        let coordinator = CopyFallbackRequestCoordinator()
        let firstRequest = coordinator.beginRequest()
        let secondRequest = coordinator.beginRequest()

        XCTAssertFalse(coordinator.isRequestActive(firstRequest))
        XCTAssertTrue(coordinator.isRequestActive(secondRequest))

        coordinator.cancelRequest(firstRequest)
        XCTAssertTrue(coordinator.isRequestActive(secondRequest))

        XCTAssertFalse(coordinator.completeRequestIfActive(firstRequest))
        XCTAssertTrue(coordinator.isRequestActive(secondRequest))
        XCTAssertTrue(coordinator.completeRequestIfActive(secondRequest))
        XCTAssertFalse(coordinator.isRequestActive(secondRequest))

        let thirdRequest = coordinator.beginRequest()
        coordinator.cancelActiveRequest()
        XCTAssertFalse(coordinator.isRequestActive(thirdRequest))
    }

    func testCopyFallbackContextRequiresOriginalApplicationAndSafeInput() {
        XCTAssertTrue(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: true,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            isSelectionSuppressed: false
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: false,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            isSelectionSuppressed: false
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: true,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 99,
            isSelectionSuppressed: false
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: true,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            isSelectionSuppressed: true
        ))
    }

    func testPasteboardSnapshotRejectsDataBeyondConfiguredLimitWithoutMutation() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenFireTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.openfire.tests.payload")
        let payload = Data(repeating: 0x41, count: 16)
        item.setData(payload, forType: type)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = AccessibilityManager.capturePasteboardSnapshot(
            from: pasteboard,
            maxBytes: 8,
            maxItems: 4,
            maxTypes: 4
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(pasteboard.data(forType: type), payload)
    }

    func testPasteboardSnapshotCapturesSmallPayloadWithinLimits() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenFireTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.openfire.tests.payload")
        item.setData(Data("small".utf8), forType: type)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = AccessibilityManager.capturePasteboardSnapshot(
            from: pasteboard,
            maxBytes: 32,
            maxItems: 4,
            maxTypes: 4
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.totalBytes, 5)
        XCTAssertNil(snapshot?.temporaryDirectoryURL)
    }

    func testPasteboardSnapshotSpillsLargePayloadAndRestoresItLazily() throws {
        let source = NSPasteboard(name: NSPasteboard.Name("OpenFireTests-Source-\(UUID().uuidString)"))
        source.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.openfire.tests.large-payload")
        let payload = Data(repeating: 0x5A, count: 32)
        item.setData(payload, forType: type)
        XCTAssertTrue(source.writeObjects([item]))

        var snapshot = AccessibilityManager.capturePasteboardSnapshot(
            from: source,
            maxBytes: 64,
            maxItems: 4,
            maxTypes: 4,
            maxInMemoryBytes: 8
        )
        let temporaryDirectoryURL = try XCTUnwrap(snapshot?.temporaryDirectoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))

        let destination = NSPasteboard(
            name: NSPasteboard.Name("OpenFireTests-Destination-\(UUID().uuidString)")
        )
        XCTAssertTrue(
            AccessibilityManager.restorePasteboardSnapshot(
                try XCTUnwrap(snapshot),
                to: destination
            )
        )

        snapshot = nil
        XCTAssertEqual(destination.data(forType: type), payload)
    }

    func testDiscardingPasteboardSnapshotRemovesTemporaryFiles() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenFireTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.openfire.tests.discarded-payload")
        item.setData(Data(repeating: 0x41, count: 16), forType: type)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(
            from: pasteboard,
            maxBytes: 32,
            maxItems: 4,
            maxTypes: 4,
            maxInMemoryBytes: 0
        ))
        let temporaryDirectoryURL = try XCTUnwrap(snapshot.temporaryDirectoryURL)

        snapshot.discardTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectoryURL.path))
    }
}
