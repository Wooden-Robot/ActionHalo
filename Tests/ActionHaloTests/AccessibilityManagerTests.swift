import XCTest
@testable import ActionHalo

final class AccessibilityManagerTests: XCTestCase {
    @MainActor
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

    func testAppKitScreenPointRoundTripsCapturedCoreGraphicsEventLocation() throws {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: -1080, width: 1920, height: 1080)
        ]
        let originalPoint = NSPoint(x: 1_600, y: -120)
        let eventPoint = try XCTUnwrap(
            AccessibilityManager.coreGraphicsScreenPoint(
                for: originalPoint,
                screenFrames: screens
            )
        )
        let restoredPoint = try XCTUnwrap(
            AccessibilityManager.appKitScreenPoint(
                for: eventPoint,
                screenFrames: screens
            )
        )

        XCTAssertEqual(restoredPoint.x, originalPoint.x, accuracy: 0.001)
        XCTAssertEqual(restoredPoint.y, originalPoint.y, accuracy: 0.001)
    }

    @MainActor
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

    func testStructuralSelectionFocusRolesExcludeTelegramTextGroups() {
        XCTAssertTrue(AccessibilityManager.isStructuralSelectionFocusRole(kAXWindowRole))
        XCTAssertFalse(AccessibilityManager.isStructuralSelectionFocusRole(kAXApplicationRole))
        XCTAssertFalse(AccessibilityManager.isStructuralSelectionFocusRole("AXGroup"))
        XCTAssertFalse(AccessibilityManager.isStructuralSelectionFocusRole(kAXTextAreaRole))
        XCTAssertFalse(AccessibilityManager.isStructuralSelectionFocusRole(nil))
    }

    func testFocusedElementResolutionFallsBackToDirectApplicationLookupBoundToFrontmostPID() throws {
        let frontmostProcessIdentifier = pid_t(42)
        let expectedFocusedElement = AXUIElementCreateApplication(frontmostProcessIdentifier)

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            systemWideLookup: { nil },
            directApplicationLookup: { processIdentifier in
                processIdentifier == frontmostProcessIdentifier
                    ? expectedFocusedElement
                    : nil
            },
            candidateBelongsToProcess: { candidate, processIdentifier in
                processIdentifier == frontmostProcessIdentifier &&
                    AccessibilityManager.areSameAccessibilityElement(
                        candidate,
                        expectedFocusedElement
                    )
            },
            isProcessStillFrontmost: { $0 == frontmostProcessIdentifier }
        )

        XCTAssertTrue(AccessibilityManager.areSameAccessibilityElement(
            try XCTUnwrap(resolvedFocusedElement),
            expectedFocusedElement
        ))
    }

    func testFocusedElementResolutionRejectsResultWhenFrontmostPIDChanges() {
        let originalProcessIdentifier = pid_t(42)
        let focusedElement = AXUIElementCreateApplication(originalProcessIdentifier)
        var frontmostChecks = [true, false]

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: originalProcessIdentifier,
            systemWideLookup: { nil },
            directApplicationLookup: { _ in focusedElement },
            candidateBelongsToProcess: { _, _ in true },
            isProcessStillFrontmost: { processIdentifier in
                XCTAssertEqual(processIdentifier, originalProcessIdentifier)
                return frontmostChecks.removeFirst()
            }
        )

        XCTAssertNil(resolvedFocusedElement)
        XCTAssertTrue(frontmostChecks.isEmpty)
    }

    func testFocusedElementResolutionSkipsAXWhenProcessIsNoLongerFrontmost() {
        var lookupCount = 0

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: pid_t(42),
            systemWideLookup: {
                lookupCount += 1
                return AXUIElementCreateSystemWide()
            },
            directApplicationLookup: { _ in
                lookupCount += 1
                return AXUIElementCreateSystemWide()
            },
            candidateBelongsToProcess: { _, _ in
                lookupCount += 1
                return true
            },
            isProcessStillFrontmost: { _ in false }
        )

        XCTAssertNil(resolvedFocusedElement)
        XCTAssertEqual(lookupCount, 0)
    }

    func testFocusedElementResolutionPrefersSystemWideResultWithoutDirectLookup() throws {
        let frontmostProcessIdentifier = pid_t(42)
        let expectedFocusedElement = AXUIElementCreateApplication(frontmostProcessIdentifier)
        var directLookupCount = 0

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            systemWideLookup: { expectedFocusedElement },
            directApplicationLookup: { _ in
                directLookupCount += 1
                return nil
            },
            candidateBelongsToProcess: { candidate, processIdentifier in
                processIdentifier == frontmostProcessIdentifier &&
                    AccessibilityManager.areSameAccessibilityElement(
                        candidate,
                        expectedFocusedElement
                    )
            },
            isProcessStillFrontmost: { $0 == frontmostProcessIdentifier }
        )

        XCTAssertTrue(AccessibilityManager.areSameAccessibilityElement(
            try XCTUnwrap(resolvedFocusedElement),
            expectedFocusedElement
        ))
        XCTAssertEqual(directLookupCount, 0)
    }

    func testFocusedElementResolutionFailsClosedWithoutFrontmostPID() {
        var lookupCount = 0

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: nil,
            systemWideLookup: {
                lookupCount += 1
                return AXUIElementCreateSystemWide()
            },
            directApplicationLookup: { _ in
                lookupCount += 1
                return AXUIElementCreateSystemWide()
            },
            candidateBelongsToProcess: { _, _ in
                lookupCount += 1
                return true
            },
            isProcessStillFrontmost: { _ in true }
        )

        XCTAssertNil(resolvedFocusedElement)
        XCTAssertEqual(lookupCount, 0)
    }

    func testFocusedElementResolutionRejectsStaleSystemWideCandidateAndUsesDirectLookup() throws {
        let frontmostProcessIdentifier = pid_t(42)
        let staleFocusedElement = AXUIElementCreateApplication(99)
        let expectedFocusedElement = AXUIElementCreateApplication(frontmostProcessIdentifier)
        var directLookupCount = 0

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            systemWideLookup: { staleFocusedElement },
            directApplicationLookup: { _ in
                directLookupCount += 1
                return expectedFocusedElement
            },
            candidateBelongsToProcess: { candidate, processIdentifier in
                processIdentifier == frontmostProcessIdentifier &&
                    AccessibilityManager.areSameAccessibilityElement(
                        candidate,
                        expectedFocusedElement
                    )
            },
            isProcessStillFrontmost: { $0 == frontmostProcessIdentifier }
        )

        XCTAssertTrue(AccessibilityManager.areSameAccessibilityElement(
            try XCTUnwrap(resolvedFocusedElement),
            expectedFocusedElement
        ))
        XCTAssertEqual(directLookupCount, 1)
    }

    func testFocusedElementResolutionRejectsDirectCandidateFromWrongProcess() {
        let frontmostProcessIdentifier = pid_t(42)
        let wrongFocusedElement = AXUIElementCreateApplication(99)

        let resolvedFocusedElement = AccessibilityManager.resolveFocusedElement(
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            systemWideLookup: { nil },
            directApplicationLookup: { _ in wrongFocusedElement },
            candidateBelongsToProcess: { candidate, _ in
                !AccessibilityManager.areSameAccessibilityElement(
                    candidate,
                    wrongFocusedElement
                )
            },
            isProcessStillFrontmost: { $0 == frontmostProcessIdentifier }
        )

        XCTAssertNil(resolvedFocusedElement)
    }

    @MainActor
    func testFocusedElementRetryRecoversAfterTwoTransientFailures() async throws {
        let expectedFocusedElement = AXUIElementCreateApplication(pid_t(42))
        var lookupResults: [AXUIElement?] = [nil, nil, expectedFocusedElement]
        var observedDelays: [TimeInterval] = []

        let resolvedFocusedElement = await AccessibilityManager.resolveFocusedElementWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                lookupResults.removeFirst()
            },
            wait: { delay in
                observedDelays.append(delay)
                return true
            }
        )

        XCTAssertTrue(AccessibilityManager.areSameAccessibilityElement(
            try XCTUnwrap(resolvedFocusedElement),
            expectedFocusedElement
        ))
        XCTAssertEqual(observedDelays, [0.05, 0.1])
        XCTAssertTrue(lookupResults.isEmpty)
    }

    @MainActor
    func testFocusedElementRetryStopsImmediatelyAfterRecovery() async throws {
        let expectedFocusedElement = AXUIElementCreateApplication(pid_t(42))
        let unusedFocusedElement = AXUIElementCreateApplication(pid_t(99))
        var lookupResults: [AXUIElement?] = [
            nil,
            expectedFocusedElement,
            unusedFocusedElement
        ]
        var observedDelays: [TimeInterval] = []

        let resolvedFocusedElement = await AccessibilityManager.resolveFocusedElementWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                lookupResults.removeFirst()
            },
            wait: { delay in
                observedDelays.append(delay)
                return true
            }
        )

        XCTAssertTrue(AccessibilityManager.areSameAccessibilityElement(
            try XCTUnwrap(resolvedFocusedElement),
            expectedFocusedElement
        ))
        XCTAssertEqual(observedDelays, [0.05])
        XCTAssertEqual(lookupResults.count, 1)
        XCTAssertTrue(AccessibilityManager.areSameAccessibilityElement(
            try XCTUnwrap(lookupResults[0]),
            unusedFocusedElement
        ))
    }

    @MainActor
    func testFocusedElementRetryStopsAfterConfiguredAttemptsAreExhausted() async {
        var lookupCount = 0
        var observedDelays: [TimeInterval] = []

        let resolvedFocusedElement = await AccessibilityManager.resolveFocusedElementWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                lookupCount += 1
                return nil
            },
            wait: { delay in
                observedDelays.append(delay)
                return true
            }
        )

        XCTAssertNil(resolvedFocusedElement)
        XCTAssertEqual(lookupCount, 3)
        XCTAssertEqual(observedDelays, [0.05, 0.1])
    }

    @MainActor
    func testFocusedElementRetryStopsWhenWaitIsCancelled() async {
        var lookupCount = 0
        var waitCount = 0

        let resolvedFocusedElement = await AccessibilityManager.resolveFocusedElementWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                lookupCount += 1
                return nil
            },
            wait: { _ in
                waitCount += 1
                return false
            }
        )

        XCTAssertNil(resolvedFocusedElement)
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(waitCount, 1)
    }

    @MainActor
    func testFocusedElementRetrySkipsLookupWhenTaskIsAlreadyCancelled() async {
        var lookupCount = 0
        let task = Task { @MainActor in
            await AccessibilityManager.resolveCandidateWithRetry(
                retryDelays: [0.05, 0.1],
                lookup: {
                    lookupCount += 1
                    return 42
                },
                validate: { _ in .accept },
                wait: { _ in true }
            )
        }

        task.cancel()
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertEqual(lookupCount, 0)
    }

    @MainActor
    func testFocusedElementRetryRevalidatesRetainedCandidateWithoutRepeatingFocusLookup() async {
        var focusLookupCount = 0
        var validationCount = 0

        let result = await AccessibilityManager.resolveCandidateWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                focusLookupCount += 1
                return 42
            },
            validate: { candidate in
                validationCount += 1
                return validationCount == 1 ? .retry : .accept
            },
            wait: { _ in true }
        )

        XCTAssertEqual(result, 42)
        XCTAssertEqual(focusLookupCount, 1)
        XCTAssertEqual(validationCount, 2)
    }

    @MainActor
    func testFocusedElementRetryCanDiscardStaleCandidateAndLookupAgain() async {
        var candidates = [41, 42]
        var focusLookupCount = 0

        let result = await AccessibilityManager.resolveCandidateWithRetry(
            retryDelays: [0.05],
            lookup: {
                focusLookupCount += 1
                return candidates.removeFirst()
            },
            validate: { candidate in
                candidate == 42 ? .accept : .retryLookup
            },
            wait: { _ in true }
        )

        XCTAssertEqual(result, 42)
        XCTAssertEqual(focusLookupCount, 2)
    }

    func testSynchronousFocusedElementRetrySkipsStaleNonNilCandidate() {
        var candidates = [41, 42]
        var focusLookupCount = 0

        let result = AccessibilityManager.resolveSynchronousCandidateWithRetry(
            retryDelays: [0.05],
            lookup: {
                focusLookupCount += 1
                return candidates.removeFirst()
            },
            isAccepted: { $0 == 42 },
            shouldContinue: { true },
            wait: { _ in true }
        )

        XCTAssertEqual(result, 42)
        XCTAssertEqual(focusLookupCount, 2)
    }

    @MainActor
    func testFocusedElementRetryStopsImmediatelyOnExplicitContextMismatch() async {
        var lookupCount = 0
        var waitCount = 0

        let result = await AccessibilityManager.resolveCandidateWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                lookupCount += 1
                return 42
            },
            validate: { _ in .reject },
            wait: { _ in
                waitCount += 1
                return true
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(waitCount, 0)
    }

    @MainActor
    func testFocusedElementRetryDoesNotLookupAgainAfterCancellationDuringWait() async {
        var lookupCount = 0

        let result = await AccessibilityManager.resolveCandidateWithRetry(
            retryDelays: [0.05, 0.1],
            lookup: {
                lookupCount += 1
                return Optional<Int>.none
            },
            validate: { _ in .accept },
            wait: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return true
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(lookupCount, 1)
    }

    @MainActor
    func testFreshAssessmentRetryReplacesStaleFocusWithNewSelectionPair() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "old-sidebar", assessment: "no-selection"),
            (candidate: "notes-text-area", assessment: "selected-text"),
            (candidate: "notes-text-area", assessment: "selected-text")
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05, 0.1],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            wait: { _ in true }
        )

        XCTAssertEqual(result?.candidate, "notes-text-area")
        XCTAssertEqual(result?.assessment, "selected-text")
        XCTAssertTrue(attempts.isEmpty)
    }

    @MainActor
    func testFreshAssessmentRetryDoesNotReturnOldUsableSelectionEarly() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "old-control", assessment: "old-selection"),
            (candidate: "current-text-area", assessment: "current-selection")
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            wait: { _ in true }
        )

        XCTAssertEqual(result?.candidate, "current-text-area")
        XCTAssertEqual(result?.assessment, "current-selection")
    }

    @MainActor
    func testFreshAssessmentRetryFailsClosedWhenFinalPairIsUnavailable() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "old-control", assessment: "old-selection"),
            nil
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            wait: { _ in true }
        )

        XCTAssertNil(result)
    }

    @MainActor
    func testFreshAssessmentRetryRecoversWhenRequiredFinalSampleIsTransientlyUnavailable() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "old-control", assessment: "old-selection"),
            (candidate: "old-control", assessment: "old-selection"),
            nil,
            nil,
            (candidate: "current-text-area", assessment: "current-selection")
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05, 0.1],
            recoveryRetryDelays: [0.05, 0.1],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            wait: { _ in true }
        )

        XCTAssertEqual(result?.candidate, "current-text-area")
        XCTAssertEqual(result?.assessment, "current-selection")
        XCTAssertTrue(attempts.isEmpty)
    }

    @MainActor
    func testFreshAssessmentRetryRecoversFromIndeterminateFinalAssessment() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "text-area", assessment: "resolved"),
            (candidate: "text-area", assessment: "indeterminate"),
            (candidate: "text-area", assessment: "resolved")
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05],
            recoveryRetryDelays: [0.1],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            isRetryable: { $0 == "indeterminate" },
            wait: { _ in true }
        )

        XCTAssertEqual(result?.candidate, "text-area")
        XCTAssertEqual(result?.assessment, "resolved")
        XCTAssertTrue(attempts.isEmpty)
    }

    @MainActor
    func testFreshAssessmentRetryDoesNotReuseOldPairAfterRecoveryExhaustion() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "old-control", assessment: "old-selection"),
            nil,
            nil,
            nil
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05],
            recoveryRetryDelays: [0.05, 0.1],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            wait: { _ in true }
        )

        XCTAssertNil(result)
        XCTAssertTrue(attempts.isEmpty)
    }

    @MainActor
    func testFreshAssessmentRetryRefreshesAssessmentForSameCandidate() async {
        var attempts: [(candidate: String, assessment: String)?] = [
            (candidate: "same-text-area", assessment: "empty"),
            (candidate: "same-text-area", assessment: "selected")
        ]

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05],
            attempt: { attempts.removeFirst() },
            isTerminal: { _ in false },
            wait: { _ in true }
        )

        XCTAssertEqual(result?.candidate, "same-text-area")
        XCTAssertEqual(result?.assessment, "selected")
    }

    @MainActor
    func testFreshAssessmentRetryStopsForTerminalProtectedAssessment() async {
        var attemptCount = 0
        var waitCount = 0

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05, 0.1],
            attempt: {
                attemptCount += 1
                return (candidate: "secure-field", assessment: "protected")
            },
            isTerminal: { $0 == "protected" },
            wait: { _ in
                waitCount += 1
                return true
            }
        )

        XCTAssertEqual(result?.candidate, "secure-field")
        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(waitCount, 0)
    }

    @MainActor
    func testFreshAssessmentRetryStopsWhenRefreshWaitIsCancelled() async {
        var attemptCount = 0

        let result = await AccessibilityManager.resolveFreshAssessedCandidateWithRetry(
            retryDelays: [0.05],
            attempt: {
                attemptCount += 1
                return (candidate: "old-control", assessment: "old-selection")
            },
            isTerminal: { _ in false },
            wait: { _ in false }
        )

        XCTAssertNil(result)
        XCTAssertEqual(attemptCount, 1)
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

    func testShouldRestorePasteboardSnapshotAfterAnyCopyMutation() {
        XCTAssertTrue(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 11, string: "copied"),
            currentState: .init(changeCount: 11, string: "copied")
        ))
        XCTAssertTrue(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 11, string: nil),
            currentState: .init(changeCount: 11, string: nil)
        ))
        XCTAssertTrue(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 11, string: "   \n"),
            currentState: .init(changeCount: 11, string: "   \n")
        ))
    }

    func testShouldRestorePasteboardSnapshotDoesNotOverwriteLaterClipboardUpdate() {
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 11, string: nil),
            currentState: .init(changeCount: 12, string: "other app update")
        ))
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 11, string: "copied"),
            currentState: .init(changeCount: 11, string: "different text")
        ))
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 10, string: "before"),
            currentState: .init(changeCount: 10, string: "before")
        ))
    }

    func testShouldRestorePasteboardSnapshotRejectsMultipleClipboardGenerations() {
        XCTAssertFalse(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: .init(changeCount: 10, string: "before"),
            observedState: .init(changeCount: 12, string: "third-party rewrite"),
            currentState: .init(changeCount: 12, string: "third-party rewrite")
        ))
    }

    func testCancelledCopyFallbackStillRollsBackItsClipboardMutationWithoutDeliveringText() {
        let initialState = AccessibilityManager.PasteboardState(
            changeCount: 10,
            string: "before"
        )
        let copiedState = AccessibilityManager.PasteboardState(
            changeCount: 11,
            string: "temporary copied text"
        )

        XCTAssertTrue(AccessibilityManager.shouldRestorePasteboardSnapshot(
            initialState: initialState,
            observedState: copiedState,
            currentState: copiedState
        ))
        XCTAssertNil(AccessibilityManager.copyFallbackResult(
            copiedText: copiedState.string,
            hasFreshCopiedText: true,
            contextIsValid: false
        ))
    }

    func testCopyFallbackPreservesMeaningfulWhitespaceAndRejectsWhitespaceOnlyText() {
        XCTAssertEqual(
            AccessibilityManager.copyFallbackResult(
                copiedText: "  copied text\n",
                hasFreshCopiedText: true,
                contextIsValid: true
            ),
            "  copied text\n"
        )
        XCTAssertNil(AccessibilityManager.copyFallbackResult(
            copiedText: " \n\t ",
            hasFreshCopiedText: true,
            contextIsValid: true
        ))
    }

    func testStablePasteboardStateRetriesWhenClipboardChangesDuringRead() {
        var counts = [10, 11, 11, 11]
        var strings = ["stale", "copied"]

        let state = AccessibilityManager.stablePasteboardState(
            maximumAttempts: 2,
            readChangeCount: { counts.removeFirst() },
            readString: { strings.removeFirst() }
        )

        XCTAssertEqual(state, .init(changeCount: 11, string: "copied"))
    }

    func testStablePasteboardStateReturnsNilWhenEveryReadRaces() {
        var counts = [10, 11, 11, 12]
        var strings = ["stale", "also stale"]

        let state = AccessibilityManager.stablePasteboardState(
            maximumAttempts: 2,
            readChangeCount: { counts.removeFirst() },
            readString: { strings.removeFirst() }
        )

        XCTAssertNil(state)
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

    func testCopyFallbackRequiresAQuietPeriodBeforeAcceptingFreshClipboardText() {
        let initialState = AccessibilityManager.PasteboardState(
            changeCount: 10,
            string: "before"
        )
        let firstFreshState = AccessibilityManager.PasteboardState(
            changeCount: 11,
            string: "first candidate"
        )
        let replacementFreshState = AccessibilityManager.PasteboardState(
            changeCount: 12,
            string: "replacement candidate"
        )
        var candidate = AccessibilityManager.StableFreshPasteboardCandidate()

        XCTAssertFalse(candidate.observe(firstFreshState, relativeTo: initialState))
        XCTAssertFalse(candidate.observe(firstFreshState, relativeTo: initialState))
        XCTAssertFalse(candidate.observe(replacementFreshState, relativeTo: initialState))
        XCTAssertFalse(candidate.observe(replacementFreshState, relativeTo: initialState))
        XCTAssertTrue(candidate.observe(replacementFreshState, relativeTo: initialState))

        XCTAssertFalse(candidate.observe(initialState, relativeTo: initialState))
        XCTAssertFalse(candidate.observe(replacementFreshState, relativeTo: initialState))
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

    func testSelectionSnapshotPreservesMeaningfulTextWhitespaceForDelivery() {
        let meaningfulSnapshot = AccessibilityManager.SelectionSnapshot(
            text: "  selected text\n",
            rangeLocation: 0,
            rangeLength: 16,
            hasReadableSelectedTextAttribute: true
        )
        let whitespaceOnlySnapshot = AccessibilityManager.SelectionSnapshot(
            text: " \n\t ",
            rangeLocation: 0,
            rangeLength: 4,
            hasReadableSelectedTextAttribute: true
        )

        XCTAssertEqual(meaningfulSnapshot.usableText, "  selected text\n")
        XCTAssertNil(whitespaceOnlySnapshot.usableText)
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
            isSelectionSuppressed: false,
            focusedElementMatches: true
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: false,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            isSelectionSuppressed: false,
            focusedElementMatches: true
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: true,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 99,
            isSelectionSuppressed: false,
            focusedElementMatches: true
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: true,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            isSelectionSuppressed: true,
            focusedElementMatches: true
        ))
        XCTAssertFalse(AccessibilityManager.shouldContinueCopyFallback(
            requestIsActive: true,
            expectedProcessIdentifier: 42,
            currentProcessIdentifier: 42,
            isSelectionSuppressed: false,
            focusedElementMatches: false
        ))
    }

    func testCopyFallbackAllowsMissingFocusOnlyWhenCallerExplicitlyOptsIn() {
        XCTAssertTrue(AccessibilityManager.copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: false,
            focusedElementMatches: false,
            allowMissingFocusedElement: true
        ))
        XCTAssertFalse(AccessibilityManager.copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: false,
            focusedElementMatches: false,
            allowMissingFocusedElement: false
        ))
        XCTAssertFalse(AccessibilityManager.copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: true,
            focusedElementMatches: false,
            allowMissingFocusedElement: true
        ))
    }

    func testCopyFallbackRelaxesFocusOnlyForVerifiedAcquiredSelectionContext() {
        XCTAssertFalse(AccessibilityManager.copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: true,
            focusedElementMatches: false,
            allowMissingFocusedElement: false
        ))
        XCTAssertTrue(AccessibilityManager.copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: true,
            focusedElementMatches: false,
            allowMissingFocusedElement: false,
            acquiredSelectionContextMatches: true
        ))
        XCTAssertFalse(AccessibilityManager.copyFallbackFocusedElementMatches(
            expectedFocusedElementAvailable: true,
            focusedElementMatches: true,
            allowMissingFocusedElement: false,
            acquiredSelectionContextMatches: false
        ))
    }

    func testCopyFallbackRevalidatesContextAndPasteboardAfterSnapshot() {
        let initialState = AccessibilityManager.PasteboardState(
            changeCount: 10,
            string: "before"
        )

        XCTAssertTrue(AccessibilityManager.shouldPostCopyFallbackEvents(
            contextIsValidAfterSnapshot: true,
            initialPasteboardState: initialState,
            currentPasteboardState: initialState
        ))
        XCTAssertFalse(AccessibilityManager.shouldPostCopyFallbackEvents(
            contextIsValidAfterSnapshot: false,
            initialPasteboardState: initialState,
            currentPasteboardState: initialState
        ))
        XCTAssertFalse(AccessibilityManager.shouldPostCopyFallbackEvents(
            contextIsValidAfterSnapshot: true,
            initialPasteboardState: initialState,
            currentPasteboardState: .init(changeCount: 11, string: "changed")
        ))
    }

    func testIndeterminateOrAncestorProtectedAccessibilityStateSuppressesSelection() {
        XCTAssertTrue(AccessibilityManager.shouldSuppressSelectionPresentation(
            elementAssessment: .indeterminate,
            ancestorAssessments: [],
            secureEventInputEnabled: false
        ))
        XCTAssertTrue(AccessibilityManager.shouldSuppressSelectionPresentation(
            elementAssessment: .unprotected,
            ancestorAssessments: [.protectedContent],
            secureEventInputEnabled: false
        ))
        XCTAssertFalse(AccessibilityManager.shouldSuppressSelectionPresentation(
            elementAssessment: .unprotected,
            ancestorAssessments: [.unprotected],
            secureEventInputEnabled: false
        ))
    }

    func testCopyFallbackAllowsMissingFocusWithoutWeakeningProtectedTextChecks() {
        XCTAssertFalse(AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: nil,
            secureEventInputEnabled: false,
            accessibilityEnabled: true,
            allowMissingFocusedElement: true
        ))
        XCTAssertTrue(AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: nil,
            secureEventInputEnabled: false,
            accessibilityEnabled: true,
            allowMissingFocusedElement: false
        ))
        XCTAssertTrue(AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: nil,
            secureEventInputEnabled: true,
            accessibilityEnabled: true,
            allowMissingFocusedElement: true
        ))
        XCTAssertTrue(AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: .protectedContent,
            secureEventInputEnabled: false,
            accessibilityEnabled: true,
            allowMissingFocusedElement: true
        ))
        XCTAssertTrue(AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: .indeterminate,
            secureEventInputEnabled: false,
            accessibilityEnabled: true,
            allowMissingFocusedElement: true
        ))
        XCTAssertTrue(AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: nil,
            secureEventInputEnabled: false,
            accessibilityEnabled: false,
            allowMissingFocusedElement: true
        ))
    }

    func testPasteboardSnapshotRejectsDataBeyondConfiguredLimitWithoutMutation() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.actionhalo.tests.payload")
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.actionhalo.tests.payload")
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

    func testPasteboardSnapshotSpillsLargePayloadAndRestoresIt() throws {
        let source = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-Source-\(UUID().uuidString)"))
        source.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.actionhalo.tests.large-payload")
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
            name: NSPasteboard.Name("ActionHaloTests-Destination-\(UUID().uuidString)")
        )
        XCTAssertTrue(
            AccessibilityManager.restorePasteboardSnapshot(
                try XCTUnwrap(snapshot),
                to: destination
            )
        )

        snapshot?.discardTemporaryFiles()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: temporaryDirectoryURL.path),
            "The spill must stay available while the pasteboard owns its lazy data provider"
        )
        snapshot = nil
        XCTAssertEqual(destination.data(forType: type), payload)
    }

    func testRestoreDoesNotRequireSnapshottingOversizedTemporaryClipboard() throws {
        let source = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-Source-\(UUID().uuidString)"))
        source.clearContents()
        let sourceItem = NSPasteboardItem()
        sourceItem.setString("original clipboard", forType: .string)
        XCTAssertTrue(source.writeObjects([sourceItem]))
        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(
            from: source,
            maxBytes: 64,
            maxItems: 4,
            maxTypes: 4
        ))

        let destination = NSPasteboard(
            name: NSPasteboard.Name("ActionHaloTests-Destination-\(UUID().uuidString)")
        )
        destination.clearContents()
        let copiedItem = NSPasteboardItem()
        let copiedType = NSPasteboard.PasteboardType("com.actionhalo.tests.oversized-copy")
        copiedItem.setData(Data(repeating: 0x5A, count: 16), forType: copiedType)
        XCTAssertTrue(destination.writeObjects([copiedItem]))

        XCTAssertTrue(
            AccessibilityManager.restorePasteboardSnapshot(
                snapshot,
                to: destination,
                rollbackMaxBytes: 8
            )
        )
        XCTAssertEqual(destination.string(forType: .string), "original clipboard")
    }

    func testDiscardingPasteboardSnapshotRemovesTemporaryFiles() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.actionhalo.tests.discarded-payload")
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

    func testRestorePreflightsSpilledSnapshotBeforeClearingDestination() throws {
        let source = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-Source-\(UUID().uuidString)"))
        source.clearContents()
        let sourceItem = NSPasteboardItem()
        let spilledType = NSPasteboard.PasteboardType("com.actionhalo.tests.missing-spill")
        sourceItem.setData(Data(repeating: 0x41, count: 32), forType: spilledType)
        XCTAssertTrue(source.writeObjects([sourceItem]))

        let snapshot = try XCTUnwrap(AccessibilityManager.capturePasteboardSnapshot(
            from: source,
            maxBytes: 64,
            maxItems: 4,
            maxTypes: 4,
            maxInMemoryBytes: 0
        ))
        let temporaryDirectoryURL = try XCTUnwrap(snapshot.temporaryDirectoryURL)
        try FileManager.default.removeItem(at: temporaryDirectoryURL)

        let destination = NSPasteboard(name: NSPasteboard.Name("ActionHaloTests-Destination-\(UUID().uuidString)"))
        destination.clearContents()
        let destinationItem = NSPasteboardItem()
        destinationItem.setString("do not clear", forType: .string)
        XCTAssertTrue(destination.writeObjects([destinationItem]))

        XCTAssertFalse(AccessibilityManager.restorePasteboardSnapshot(snapshot, to: destination))
        XCTAssertEqual(destination.string(forType: .string), "do not clear")
    }
}
