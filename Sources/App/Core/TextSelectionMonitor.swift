import Cocoa

/// Monitors global mouse events to detect text selection
@MainActor
final class TextSelectionMonitor {
    struct FrontmostWindowSnapshot: Equatable {
        let windowID: CGWindowID?
        let ownerPID: pid_t
        let bounds: CGRect

        init(windowID: CGWindowID? = nil, ownerPID: pid_t, bounds: CGRect) {
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.bounds = bounds
        }
    }

    enum MonitoringStartFailure: Equatable {
        case accessibilityPermissionMissing
        case eventTapCreationFailed
    }

    nonisolated private static let suppressedFrontmostBundleIDs: Set<String> = [
        "comactionhaloapp",
        "comappledock",
        "comapplefinder",
        "comapplewindowmanager"
    ]
    nonisolated private static let suppressedFrontmostNames: Set<String> = [
        "actionhalo",
        "finder",
        "dock",
        "desktop"
    ]
    nonisolated private static let screenCaptureHints = [
        "comapplescreencaptureui",
        "comapplescreenshot",
        "comapplegrab",
        "snipaste",
        "cleanshot",
        "shottr",
        "xnapper",
        "snagit",
        "pixpin",
        "ishot",
        "screenshot",
        "screenrecord",
        "screenrecorder",
        "screencapture",
        "snippingtool"
    ]
    
    static let shared = TextSelectionMonitor()
    
    /// Notification posted when text is selected. UserInfo contains the text,
    /// location, target PID, and the focused element verified for this selection.
    nonisolated static let textSelectedNotification = Notification.Name("ActionHaloTextSelected")

    nonisolated static func hasUsableClipboardText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func textSelectedNotificationUserInfo(
        text: String,
        location: NSPoint,
        processIdentifier: pid_t,
        focusedElement: AXUIElement?,
        windowID: CGWindowID? = nil,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment? = nil
    ) -> [String: Any] {
        var userInfo: [String: Any] = [
            "text": text,
            "mouseLocation": NSValue(point: location),
            "processIdentifier": NSNumber(value: processIdentifier)
        ]
        if let focusedElement {
            userInfo["focusedElement"] = focusedElement
        }
        if let windowID {
            userInfo["windowID"] = NSNumber(value: windowID)
        }
        if let focusedElementAssessment {
            userInfo["focusedElementAssessment"] = focusedElementAssessment
        }
        return userInfo
    }

    static func emptyTextInputClickedNotificationUserInfo(
        location: NSPoint,
        processIdentifier: pid_t,
        focusedElement: AXUIElement
    ) -> [String: Any] {
        [
            "mouseLocation": NSValue(point: location),
            "processIdentifier": NSNumber(value: processIdentifier),
            "focusedElement": focusedElement
        ]
    }

    nonisolated static func shouldSuppressForFileDragPasteboard(typeIdentifiers: [String]) -> Bool {
        let normalizedTypes = Set(typeIdentifiers.map { $0.lowercased() })
        let fileDragTypeHints: Set<String> = [
            NSPasteboard.PasteboardType.fileURL.rawValue.lowercased(),
            "nsfilenamespboardtype",
            "com.apple.pasteboard.promised-file-url"
        ]

        return !normalizedTypes.intersection(fileDragTypeHints).isEmpty
    }

    nonisolated static func shouldSuppressForFrontmostApp(
        bundleID: String?,
        localizedName: String?
    ) -> Bool {
        let normalizedBundleID = normalizeFrontmostAppIdentifier(bundleID)
        let normalizedName = normalizeFrontmostAppIdentifier(localizedName)

        if suppressedFrontmostBundleIDs.contains(normalizedBundleID) || suppressedFrontmostNames.contains(normalizedName) {
            return true
        }

        return screenCaptureHints.contains { hint in
            normalizedBundleID.contains(hint) || normalizedName.contains(hint)
        }
    }

    nonisolated private static func shouldAlwaysSuppressForFrontmostApp(
        bundleID: String?,
        localizedName: String?
    ) -> Bool {
        let normalizedBundleID = normalizeFrontmostAppIdentifier(bundleID)
        let normalizedName = normalizeFrontmostAppIdentifier(localizedName)
        if normalizedBundleID == "comactionhaloapp" ||
            normalizedName == "actionhalo" {
            return true
        }

        return screenCaptureHints.contains { hint in
            normalizedBundleID.contains(hint) || normalizedName.contains(hint)
        }
    }

    nonisolated static func shouldSuppressForFrontmostApp(
        bundleID: String?,
        localizedName: String?,
        isFocusedSelectionEditable: Bool
    ) -> Bool {
        if shouldAlwaysSuppressForFrontmostApp(bundleID: bundleID, localizedName: localizedName) {
            return true
        }
        if isFocusedSelectionEditable {
            return false
        }

        return shouldSuppressForFrontmostApp(bundleID: bundleID, localizedName: localizedName)
    }

    nonisolated static func shouldAllowEmptyTextInputCheck(
        bundleID: String?,
        localizedName: String?,
        isAppExcluded: (String) -> Bool = { AppExclusionStore.isExcluded($0) }
    ) -> Bool {
        if shouldSuppressForFrontmostApp(bundleID: bundleID, localizedName: localizedName) {
            return false
        }

        if let bundleID, isAppExcluded(bundleID) {
            return false
        }

        return true
    }

    nonisolated static func isFileDragInProgress(
        dragPasteboardChangeCountAtMouseDown: Int,
        currentDragPasteboardChangeCount: Int,
        typeIdentifiers: [String]
    ) -> Bool {
        guard currentDragPasteboardChangeCount != dragPasteboardChangeCountAtMouseDown else {
            return false
        }

        return shouldSuppressForFileDragPasteboard(typeIdentifiers: typeIdentifiers)
    }

    static func currentFrontmostWindowSnapshot(
        frontmostApplication: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
        windowInfoList: [[String: Any]]? = nil,
        containing point: CGPoint? = nil,
        matching matchingWindowID: CGWindowID? = nil
    ) -> FrontmostWindowSnapshot? {
        currentFrontmostWindowSnapshot(
            frontmostProcessID: frontmostApplication?.processIdentifier,
            windowInfoList: windowInfoList,
            containing: point,
            matching: matchingWindowID
        )
    }

    nonisolated static func currentFrontmostWindowSnapshot(
        frontmostProcessID: pid_t?,
        windowInfoList: [[String: Any]]? = nil,
        containing point: CGPoint? = nil,
        matching matchingWindowID: CGWindowID? = nil
    ) -> FrontmostWindowSnapshot? {
        guard let frontmostProcessID else { return nil }
        let windows = windowInfoList ?? ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostProcessID else {
                continue
            }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            guard bounds.width > 40, bounds.height > 40 else { continue }

            let currentWindowID = windowID(from: window)
            if let matchingWindowID {
                guard currentWindowID == matchingWindowID else { continue }
            } else if let point {
                guard bounds.contains(point) else { continue }
            }

            return FrontmostWindowSnapshot(windowID: currentWindowID, ownerPID: ownerPID, bounds: bounds)
        }

        return nil
    }

    nonisolated private static func windowID(from windowInfo: [String: Any]) -> CGWindowID? {
        if let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID {
            return windowID
        }
        if let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber {
            return CGWindowID(windowNumber.uint32Value)
        }
        return nil
    }

    nonisolated static func didFrontmostWindowMove(
        from previous: FrontmostWindowSnapshot?,
        to current: FrontmostWindowSnapshot?,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard let previous, let current, previous.ownerPID == current.ownerPID else {
            return false
        }

        return abs(previous.bounds.minX - current.bounds.minX) > tolerance ||
            abs(previous.bounds.minY - current.bounds.minY) > tolerance ||
            abs(previous.bounds.width - current.bounds.width) > tolerance ||
            abs(previous.bounds.height - current.bounds.height) > tolerance
    }

    nonisolated static func accessibilityWindowFrameMatchesCapturedWindow(
        _ accessibilityFrame: CGRect?,
        capturedBounds: CGRect?,
        tolerance: CGFloat = 12
    ) -> Bool {
        guard let accessibilityFrame,
              let capturedBounds,
              tolerance >= 0,
              accessibilityFrame.width > 0,
              accessibilityFrame.height > 0,
              capturedBounds.width > 0,
              capturedBounds.height > 0 else {
            return false
        }

        return abs(accessibilityFrame.minX - capturedBounds.minX) <= tolerance &&
            abs(accessibilityFrame.minY - capturedBounds.minY) <= tolerance &&
            abs(accessibilityFrame.width - capturedBounds.width) <= tolerance &&
            abs(accessibilityFrame.height - capturedBounds.height) <= tolerance
    }

    nonisolated static func focusedWindowRetryDisposition(
        capturedWindow: FrontmostWindowSnapshot,
        currentTopmostWindow: FrontmostWindowSnapshot?,
        accessibilityWindowMatches: Bool?
    ) -> AccessibilityManager.RetryDisposition {
        guard let currentTopmostWindow else { return .retry }
        guard let capturedWindowID = capturedWindow.windowID,
              let currentWindowID = currentTopmostWindow.windowID else {
            return .retry
        }
        guard capturedWindow.ownerPID == currentTopmostWindow.ownerPID,
              capturedWindowID == currentWindowID,
              !didFrontmostWindowMove(
                from: capturedWindow,
                to: currentTopmostWindow
              ) else {
            return .reject
        }
        guard let accessibilityWindowMatches else { return .retry }
        return accessibilityWindowMatches ? .accept : .retryLookup
    }

    nonisolated static func shouldContinueMouseGesture(
        mouseDownProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        windowAtMouseDown: FrontmostWindowSnapshot?,
        windowAtMouseUp: FrontmostWindowSnapshot?
    ) -> Bool {
        guard let mouseDownProcessIdentifier,
              mouseDownProcessIdentifier == currentProcessIdentifier,
              let windowAtMouseDown,
              let windowAtMouseUp,
              windowAtMouseDown.ownerPID == mouseDownProcessIdentifier,
              windowAtMouseUp.ownerPID == mouseDownProcessIdentifier,
              windowAtMouseDown.windowID == windowAtMouseUp.windowID else {
            return false
        }

        return !didFrontmostWindowMove(from: windowAtMouseDown, to: windowAtMouseUp)
    }
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private(set) var lastMonitoringStartFailure: MonitoringStartFailure?
    var onPhysicalMouseDown: (() -> Void)?
    private var mouseDownLocation: NSPoint?
    private var mouseDownDragPasteboardChangeCount: Int?
    private var mouseDownWindowSnapshot: FrontmostWindowSnapshot?
    private var mouseDownProcessIdentifier: pid_t?
    private var mouseDownSelectionSnapshot: AccessibilityManager.SelectionSnapshot?
    private var mouseDownSelectionWindow: AXUIElement?
    private var mouseDownStartedInTextContext = false
    private var mouseDownInsideFocusedElementBounds = false
    private var mouseDownPreviouslyAcquiredText: String?
    private var mouseDownPreviousAcquisitionAge: TimeInterval?
    private var mouseDownFocusTask: Task<Void, Never>?
    private var mouseDownGestureID: UUID?
    private var pendingSelectionBaselineSnapshot: AccessibilityManager.SelectionSnapshot?
    private var pendingSelectionStartedInTextContext = false
    private var pendingSelectionEndedInTextContext = false
    private var pendingSelectionStartedInsideFocusedElementBounds = false
    private var pendingSelectionEndedInsideFocusedElementBounds = false
    private var pendingSelectionPreviouslyAcquiredText: String?
    private var pendingSelectionPreviousAcquisitionAge: TimeInterval?
    private var pendingSelectionProcessIdentifier: pid_t?
    private var pendingSelectionFocusedElement: AXUIElement?
    private var pendingSelectionFocusedElementAssessment:
        AccessibilityManager.FocusedElementAssessment?
    private var pendingSelectionExpectedWindow: AXUIElement?
    private var pendingSelectionBundleID: String?
    private var pendingSelectionWindowID: CGWindowID?
    private var pendingSelectionWindowSnapshot: FrontmostWindowSnapshot?
    private var pendingFocusedElementResolutionTask: Task<Void, Never>?
    private var pendingAssessmentRefreshTask: Task<Void, Never>?
    
    // AXObserver state for robust text selection detection
    private var currentObserver: AXObserver?
    private var observerRunLoopSource: CFRunLoopSource?
    private var observedElement: AXUIElement?
    private var observationTimeout: DispatchWorkItem?
    
    // Polling fallback state for non-standard apps (e.g. Telegram, Electron apps)
    private var pendingSelectionTaskID: UUID?
    private var pendingCopyFallbackRequestID: UUID?
    private var isCopyFallbackInFlight = false
    private var pendingPresentationWorkItem: DispatchWorkItem?
    private var pendingPresentationRequestID: UUID?
    private var presentationCancelMonitor: Any?
    private var pendingEmptyInputCheckID: UUID?
    private(set) var lastEmptyInputCheckLocation: NSPoint?
    
    // Minimum drag distance (in points) to consider as text selection
    private let minimumDragDistance: CGFloat = 5.0
    private let mouseSelectionPresentationDelay: TimeInterval = 0.16
    nonisolated static let selectionSettleDelay: TimeInterval = 0.05
    nonisolated static let accessibilityPollingDelay: TimeInterval = 0.1
    nonisolated static let copyFallbackStartDelay: TimeInterval = 0.05
    nonisolated static let observerTimeout: TimeInterval = 0.8
    nonisolated static let duplicateCopyFallbackSuppressionInterval: TimeInterval = 1
    
    private init() {}

    nonisolated private static func normalizeFrontmostAppIdentifier(_ value: String?) -> String {
        guard let value else { return "" }
        let lowered = value.lowercased()
        return lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    nonisolated static func monitoringStartFailure(
        accessibilityEnabled: Bool,
        eventTapCreated: Bool
    ) -> MonitoringStartFailure? {
        guard accessibilityEnabled else { return .accessibilityPermissionMissing }
        guard eventTapCreated else { return .eventTapCreationFailed }
        return nil
    }
    
    // MARK: - Start / Stop
    
    @discardableResult
    func startMonitoring() -> Bool {
        guard !isMonitoring else {
            lastMonitoringStartFailure = nil
            return true
        }
        guard AccessibilityManager.shared.isAccessibilityEnabled else {
            lastMonitoringStartFailure = .accessibilityPermissionMissing
            NSLog("[ActionHalo] Cannot start monitoring: accessibility permission not granted")
            return false
        }
        
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                      (1 << CGEventType.leftMouseUp.rawValue)
        
        // Create event tap callback
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitorAddress = UInt(bitPattern: refcon)
            let eventType = type
            let eventLocation = event.location
            if type == .tapDisabledByTimeout ||
                type == .tapDisabledByUserInput ||
                type == .leftMouseDown ||
                type == .leftMouseUp {
                // Preserve callback order and the event's own coordinates.
                // Reading NSEvent.mouseLocation after an asynchronous hop can
                // collapse a fast drag into two identical, stale positions.
                DispatchQueue.main.async {
                    guard let pointer = UnsafeRawPointer(bitPattern: monitorAddress) else { return }
                    let monitor = Unmanaged<TextSelectionMonitor>
                        .fromOpaque(pointer)
                        .takeUnretainedValue()

                    // Event-tap callbacks are not guaranteed to execute on the
                    // main actor. Keep all monitor state on the main actor,
                    // including tap recovery and gesture handling.
                    guard monitor.isMonitoring else { return }
                    if eventType == .tapDisabledByTimeout ||
                        eventType == .tapDisabledByUserInput {
                        if let tap = monitor.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    } else {
                        guard let mouseLocation = AccessibilityManager.appKitScreenPoint(
                            for: eventLocation
                        ) else {
                            return
                        }
                        if eventType == .leftMouseDown {
                            monitor.handleMouseDown(at: mouseLocation)
                        } else {
                            monitor.handleMouseUp(at: mouseLocation)
                        }
                    }
                }
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPointer
        )
        
        guard let eventTap = eventTap else {
            lastMonitoringStartFailure = .eventTapCreationFailed
            NSLog("[ActionHalo] Failed to create event tap. Ensure accessibility permission is granted.")
            return false
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        lastMonitoringStartFailure = nil
        NSLog("[ActionHalo] Text selection monitoring started")
        return true
    }
    
    func stopMonitoring() {
        lastMonitoringStartFailure = nil
        guard isMonitoring else { return }
        
        cleanupPendingTask()
        cancelPendingSelectionPresentation()
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isMonitoring = false
        resetMouseDownState()
        pendingSelectionBaselineSnapshot = nil
        pendingSelectionStartedInTextContext = false
        pendingSelectionEndedInTextContext = false
        pendingSelectionStartedInsideFocusedElementBounds = false
        pendingSelectionEndedInsideFocusedElementBounds = false
        pendingSelectionPreviouslyAcquiredText = nil
        pendingSelectionProcessIdentifier = nil
        pendingSelectionBundleID = nil
        pendingEmptyInputCheckID = nil
        
        NSLog("[ActionHalo] Text selection monitoring stopped")
    }
    
    // MARK: - Event Handling
    
    /// Notification posted when an empty text input is clicked
    nonisolated static let emptyTextInputClickedNotification =
        Notification.Name("ActionHaloEmptyTextInputClicked")

    nonisolated static func shouldTreatMouseInteractionAsSelectionTrigger(
        distance: CGFloat,
        minimumDragDistance: CGFloat
    ) -> Bool {
        distance >= minimumDragDistance
    }

    static func isTextSelectionContext(
        at point: NSPoint,
        focusedElement: AXUIElement
    ) -> Bool {
        AccessibilityManager.shared.isTextElement(at: point) ||
        AccessibilityManager.shared.isFocusedTextSelectionContext(
            at: point,
            focusedElement: focusedElement
        )
    }

    nonisolated static func shouldHandleAccessibilityDragSelection(
        snapshotAtMouseDown: AccessibilityManager.SelectionSnapshot?,
        currentSnapshot: AccessibilityManager.SelectionSnapshot?,
        startedInTextContext: Bool = false,
        endedInTextContext: Bool = false
    ) -> Bool {
        guard let currentSnapshot,
              currentSnapshot.canReadSelectedTextViaAccessibility,
              currentSnapshot.usableText != nil else { return false }
        guard snapshotAtMouseDown != nil ||
                (startedInTextContext && endedInTextContext) else {
            return false
        }
        return AccessibilityManager.didSelectionChange(from: snapshotAtMouseDown, to: currentSnapshot)
    }

    nonisolated static func shouldCancelSelectionTaskOnObserverTimeout(
        copyFallbackInFlight: Bool
    ) -> Bool {
        !copyFallbackInFlight
    }

    nonisolated static func shouldContinueSelectionContext(
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        bundleID: String?,
        expectedFocusedElementAvailable: Bool,
        currentFocusedElementAvailable: Bool,
        focusedElementMatches: Bool
    ) -> Bool {
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ) else {
            return false
        }
        if expectedFocusedElementAvailable {
            return currentFocusedElementAvailable && focusedElementMatches
        }
        return AccessibilityManager.shouldAllowContextlessBlindCopyFallback(bundleID: bundleID)
    }

    nonisolated static func shouldContinueAcquiredSelectionPresentation(
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        bundleID: String?,
        expectedFocusedElementAvailable: Bool,
        currentFocusedElementAvailable: Bool,
        focusedElementMatches: Bool,
        currentFocusedElementIsStructural: Bool,
        focusedWindowMatches: Bool,
        expectedWindowID: CGWindowID?,
        currentWindowID: CGWindowID?
    ) -> Bool {
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ) else {
            return false
        }

        if let expectedWindowID, expectedWindowID != currentWindowID {
            return false
        }

        if expectedFocusedElementAvailable {
            if currentFocusedElementAvailable && focusedElementMatches {
                return true
            }

            guard bundleID?.lowercased() == "ru.keepcoder.telegram",
                  currentFocusedElementAvailable,
                  currentFocusedElementIsStructural,
                  focusedWindowMatches,
                  let expectedWindowID,
                  expectedWindowID == currentWindowID else {
                return false
            }
            return true
        }

        guard AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
            bundleID: bundleID
        ), let expectedWindowID,
           expectedWindowID == currentWindowID else {
            return false
        }
        return true
    }

    nonisolated static func shouldHandleCopiedDragSelection(
        copiedText: String?,
        snapshotAtMouseDown: AccessibilityManager.SelectionSnapshot?,
        currentSnapshot: AccessibilityManager.SelectionSnapshot?,
        frontmostBundleID: String?,
        startedInTextContext: Bool,
        endedInTextContext: Bool,
        startedInsideFocusedElementBounds: Bool,
        endedInsideFocusedElementBounds: Bool,
        previouslyAcquiredText: String? = nil,
        previousAcquisitionAge: TimeInterval? = nil
    ) -> Bool {
        guard let copiedText else { return false }
        let trimmed = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hasTextContext = startedInTextContext || endedInTextContext
        let hasFocusedBoundsContext =
            AccessibilityManager.isLikelyRichTextSelectionHost(bundleID: frontmostBundleID) &&
            (startedInsideFocusedElementBounds || endedInsideFocusedElementBounds)
        let hasSelectionSignal =
            (snapshotAtMouseDown?.isReadable == true || currentSnapshot?.isReadable == true) &&
            AccessibilityManager.didSelectionChange(from: snapshotAtMouseDown, to: currentSnapshot)
        let hasContextSignal = hasTextContext || hasSelectionSignal || hasFocusedBoundsContext
        let hasBlindCopyFallbackHost = hasContextSignal
            ? AccessibilityManager.shouldAllowBlindCopyFallback(bundleID: frontmostBundleID)
            : AccessibilityManager.shouldAllowContextlessBlindCopyFallback(bundleID: frontmostBundleID)
        guard hasContextSignal || hasBlindCopyFallbackHost else { return false }
        if !hasContextSignal,
           previouslyAcquiredText?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
           (previousAcquisitionAge ?? 0) <= duplicateCopyFallbackSuppressionInterval {
            return false
        }
        if let snapshotAtMouseDown, snapshotAtMouseDown.canReadSelectedTextViaAccessibility {
            if let currentSnapshot, currentSnapshot.canReadSelectedTextViaAccessibility {
                return snapshotAtMouseDown.normalizedText != trimmed
            }

            return hasSelectionSignal || hasFocusedBoundsContext || hasBlindCopyFallbackHost
        }

        return true
    }

    private func handleMouseDown(at mouseLocation: NSPoint) {
        // A new physical gesture supersedes all delayed work from the previous one.
        onPhysicalMouseDown?()
        cancelPendingInteraction()

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return }
        guard !Self.shouldAlwaysSuppressForFrontmostApp(
            bundleID: frontmostApp.bundleIdentifier,
            localizedName: frontmostApp.localizedName
        ) else {
            return
        }
        if let bundleID = frontmostApp.bundleIdentifier,
           AppExclusionStore.isExcluded(bundleID) {
            return
        }
        let processIdentifier = frontmostApp.processIdentifier
        guard let windowSnapshot = Self.currentFrontmostWindowSnapshot(
            frontmostProcessID: processIdentifier,
            containing: AccessibilityManager.coreGraphicsScreenPoint(for: mouseLocation)
        ) else {
            return
        }

        mouseDownLocation = mouseLocation
        mouseDownDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        mouseDownWindowSnapshot = windowSnapshot
        mouseDownProcessIdentifier = processIdentifier
        if let windowID = windowSnapshot.windowID {
            let gestureID = UUID()
            mouseDownGestureID = gestureID
            mouseDownFocusTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let assessedFocusedElement = await AccessibilityManager.shared
                    .resolveAssessedFocusedElementWithRetry(
                        expectedProcessIdentifier: processIdentifier,
                        windowConstraint: AccessibilityManager.FocusedWindowConstraint(
                            windowID: windowID,
                            ownerPID: windowSnapshot.ownerPID,
                            bounds: windowSnapshot.bounds
                        ),
                        bundleID: frontmostApp.bundleIdentifier,
                        points: [mouseLocation]
                    )
                guard !Task.isCancelled,
                      self.mouseDownGestureID == gestureID,
                      let assessedFocusedElement else {
                    return
                }
                self.mouseDownFocusTask = nil
                // AX focus/attributes may resolve only after the drag has
                // already created its final selection on macOS 15. Treating
                // that late value as the mouse-down baseline would make the
                // final selection look unchanged and suppress the menu.
                self.mouseDownSelectionSnapshot = nil
                self.mouseDownSelectionWindow = assessedFocusedElement.selectionWindow
                self.mouseDownStartedInTextContext =
                    assessedFocusedElement.assessment.pointAssessments.first?
                        .isTextSelectionContext ?? false
                self.mouseDownInsideFocusedElementBounds =
                    assessedFocusedElement.assessment.pointAssessments.first?
                        .isInsideFocusedElementBounds ?? false
            }
        }
        mouseDownPreviouslyAcquiredText = AccessibilityManager.shared.lastSelectionAcquiredText
        mouseDownPreviousAcquisitionAge = AccessibilityManager.shared.lastSelectionAcquisitionStatus.map {
            Date().timeIntervalSince($0.timestamp)
        }
    }

    private func resetMouseDownState() {
        mouseDownFocusTask?.cancel()
        mouseDownFocusTask = nil
        mouseDownGestureID = nil
        mouseDownLocation = nil
        mouseDownDragPasteboardChangeCount = nil
        mouseDownWindowSnapshot = nil
        mouseDownProcessIdentifier = nil
        mouseDownSelectionSnapshot = nil
        mouseDownSelectionWindow = nil
        mouseDownStartedInTextContext = false
        mouseDownInsideFocusedElementBounds = false
        mouseDownPreviouslyAcquiredText = nil
        mouseDownPreviousAcquisitionAge = nil
    }

    func cancelPendingInteraction() {
        cleanupPendingTask()
        cancelPendingSelectionPresentation()
        resetMouseDownState()
    }

    private func handleMouseUp(at upLocation: NSPoint) {
        guard let downLocation = mouseDownLocation else { return }
        cancelPendingSelectionPresentation()

        let dragPasteboard = NSPasteboard(name: .drag)
        let dragPasteboardTypes = dragPasteboard.types?.map(\.rawValue) ?? []
        let dragPasteboardChangeCountAtMouseDown = mouseDownDragPasteboardChangeCount ?? dragPasteboard.changeCount
        let windowSnapshotAtMouseDown = mouseDownWindowSnapshot
        let processIdentifierAtMouseDown = mouseDownProcessIdentifier
        let selectionWindowAtMouseDown = mouseDownSelectionWindow

        if Self.isFileDragInProgress(
            dragPasteboardChangeCountAtMouseDown: dragPasteboardChangeCountAtMouseDown,
            currentDragPasteboardChangeCount: dragPasteboard.changeCount,
            typeIdentifiers: dragPasteboardTypes
        ) {
            resetMouseDownState()
            return
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            resetMouseDownState()
            return
        }
        let selectionProcessIdentifier = processIdentifierAtMouseDown
        let selectionBundleID = frontmostApp.bundleIdentifier
        let windowSnapshotAtMouseUp = Self.currentFrontmostWindowSnapshot(
            frontmostProcessID: frontmostApp.processIdentifier
        )
        guard Self.shouldContinueMouseGesture(
            mouseDownProcessIdentifier: processIdentifierAtMouseDown,
            currentProcessIdentifier: frontmostApp.processIdentifier,
            windowAtMouseDown: windowSnapshotAtMouseDown,
            windowAtMouseUp: windowSnapshotAtMouseUp
        ) else {
            resetMouseDownState()
            return
        }
        let selectionWindowID = windowSnapshotAtMouseUp?.windowID
        
        // Check blacklist
        if let bundleId = frontmostApp.bundleIdentifier {
            if AppExclusionStore.isExcluded(bundleId) {
                resetMouseDownState()
                return
            }
        }
        
        // Prevent recursive spawning: If the Radial Menu is currently open, 
        // ignore all global text selection events so drag-clicks don't spawn a new menu.
        if NSApplication.shared.windows.contains(where: { $0 is RadialMenuWindow && $0.isVisible }) {
            resetMouseDownState()
            return
        }

        let startedInTextContext = mouseDownStartedInTextContext
        let endedInTextContext = false
        let startedInsideFocusedElementBounds = mouseDownInsideFocusedElementBounds
        let endedInsideFocusedElementBounds = false
        let previouslyAcquiredText = mouseDownPreviouslyAcquiredText
        let previousAcquisitionAge = mouseDownPreviousAcquisitionAge
        
        let dx = upLocation.x - downLocation.x
        let dy = upLocation.y - downLocation.y
        let distance = sqrt(dx * dx + dy * dy)
        let snapshotAtMouseDown = mouseDownSelectionSnapshot
        
        resetMouseDownState()
        
        // Clean up any pending observers or active tasks
        cleanupPendingTask()
        
        let isDrag = Self.shouldTreatMouseInteractionAsSelectionTrigger(
            distance: distance,
            minimumDragDistance: minimumDragDistance
        )
        
        // Only real drag-selection should open the radial menu.
        if isDrag {
            let taskID = UUID()
            self.pendingSelectionTaskID = taskID
            self.pendingSelectionBaselineSnapshot = snapshotAtMouseDown
            self.pendingSelectionStartedInTextContext = startedInTextContext
            self.pendingSelectionEndedInTextContext = endedInTextContext
            self.pendingSelectionStartedInsideFocusedElementBounds = startedInsideFocusedElementBounds
            self.pendingSelectionEndedInsideFocusedElementBounds = endedInsideFocusedElementBounds
            self.pendingSelectionPreviouslyAcquiredText = previouslyAcquiredText
            self.pendingSelectionPreviousAcquisitionAge = previousAcquisitionAge
            self.pendingSelectionProcessIdentifier = selectionProcessIdentifier
            self.pendingSelectionFocusedElement = nil
            self.pendingSelectionFocusedElementAssessment = nil
            self.pendingSelectionExpectedWindow = selectionWindowAtMouseDown
            self.pendingSelectionBundleID = selectionBundleID
            self.pendingSelectionWindowID = selectionWindowID
            self.pendingSelectionWindowSnapshot = windowSnapshotAtMouseUp
            
            // Wait a tiny bit then do a hybrid check: Observer + Polling
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionSettleDelay) { [weak self] in
                guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                self.pendingFocusedElementResolutionTask?.cancel()
                self.pendingFocusedElementResolutionTask = Task { @MainActor [weak self] in
                    guard let self, self.pendingSelectionTaskID == taskID else { return }
                    let allowMissingFocusedElement =
                        AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                            bundleID: self.pendingSelectionBundleID
                        )
                    guard self.pendingSelectionProcessIsCurrent() else {
                        self.cleanupPendingTask()
                        return
                    }
                    guard let capturedWindow = self.pendingSelectionWindowSnapshot,
                          let capturedWindowID = capturedWindow.windowID else {
                        self.cleanupPendingTask()
                        return
                    }
                    // Notes on macOS 15 can publish AX focus after mouse-up in
                    // multiple phases. Resolve focus and its AXWindow as one
                    // bounded operation, while keeping the original PID and
                    // topmost CGWindow identity fixed for every attempt.
                    let assessedFocusedElement = await AccessibilityManager.shared
                        .resolveAssessedFocusedElementWithRetry(
                            expectedProcessIdentifier: self.pendingSelectionProcessIdentifier,
                            windowConstraint: AccessibilityManager.FocusedWindowConstraint(
                                windowID: capturedWindowID,
                                ownerPID: capturedWindow.ownerPID,
                                bounds: capturedWindow.bounds,
                                expectedSelectionWindow:
                                    self.pendingSelectionExpectedWindow
                            ),
                            bundleID: self.pendingSelectionBundleID,
                            points: [downLocation, upLocation],
                            requireUsableSelection: true
                        )
                    let rawFocusedElement =
                        assessedFocusedElement?.focusedElement
                    guard !Task.isCancelled,
                          self.pendingSelectionTaskID == taskID else {
                        return
                    }
                    self.pendingFocusedElementResolutionTask = nil
                    guard rawFocusedElement != nil || allowMissingFocusedElement else {
                        AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
                        self.cleanupPendingTask()
                        return
                    }
                    guard !Self.shouldSuppressForFrontmostApp(
                        bundleID: self.pendingSelectionBundleID,
                        localizedName:
                            NSWorkspace.shared.frontmostApplication?.localizedName,
                        isFocusedSelectionEditable:
                            assessedFocusedElement?.assessment
                                .isSelectionEditable ?? false
                    ) else {
                        self.cleanupPendingTask()
                        return
                    }
                    if let assessedFocusedElement {
                        let pointAssessments =
                            assessedFocusedElement.assessment.pointAssessments
                        self.pendingSelectionStartedInTextContext =
                            self.pendingSelectionStartedInTextContext ||
                            (pointAssessments.first?.isTextSelectionContext ?? false)
                        self.pendingSelectionEndedInTextContext =
                            self.pendingSelectionEndedInTextContext ||
                            (pointAssessments.dropFirst().first?
                                .isTextSelectionContext ?? false)
                        self.pendingSelectionStartedInsideFocusedElementBounds =
                            self.pendingSelectionStartedInsideFocusedElementBounds ||
                            (pointAssessments.first?
                                .isInsideFocusedElementBounds ?? false)
                        self.pendingSelectionEndedInsideFocusedElementBounds =
                            self.pendingSelectionEndedInsideFocusedElementBounds ||
                            (pointAssessments.dropFirst().first?
                                .isInsideFocusedElementBounds ?? false)
                    }
                    guard !AccessibilityManager.shouldSuppressCopyFallback(
                        focusedElementAssessment:
                            assessedFocusedElement?.assessment.protection,
                        secureEventInputEnabled:
                            AccessibilityManager.shared.isSecureEventInputEnabled(),
                        accessibilityEnabled:
                            AccessibilityManager.shared.isAccessibilityEnabled,
                        allowMissingFocusedElement: allowMissingFocusedElement
                    ) else {
                        self.cleanupPendingTask()
                        return
                    }
                    // Preserve the exact verified target for the rest of this
                    // synchronous acquisition step; do not immediately re-query.
                    self.pendingSelectionFocusedElement = rawFocusedElement
                    self.pendingSelectionFocusedElementAssessment =
                        assessedFocusedElement?.assessment

                    let currentSnapshot =
                        assessedFocusedElement?.assessment.selectionSnapshot

                    if Self.shouldHandleAccessibilityDragSelection(
                        snapshotAtMouseDown: snapshotAtMouseDown,
                        currentSnapshot: currentSnapshot,
                        startedInTextContext: self.pendingSelectionStartedInTextContext,
                        endedInTextContext: self.pendingSelectionEndedInTextContext
                    ), let text = currentSnapshot?.usableText {
                        AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
                        self.handleSelectionFound(text: text, location: upLocation, taskID: taskID)
                    } else {
                        AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
                        let observerStarted = self.startObserver(taskID: taskID)

                        self.schedulePolling(
                            at: upLocation,
                            taskID: taskID,
                            allowCopyFallback: true,
                            observerStarted: observerStarted
                        )
                    }
                }
            }
        } else {
            // It was just a click. Check if it's inside a text input field.
            let emptyInputCheckID = UUID()
            pendingEmptyInputCheckID = emptyInputCheckID
            // We still need a tiny delay here for the system to focus the new element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self,
                      self.pendingEmptyInputCheckID == emptyInputCheckID else {
                    return
                }
                self.checkForEmptyTextInputClick(
                    at: upLocation,
                    expectedProcessIdentifier: selectionProcessIdentifier,
                    requestID: emptyInputCheckID
                )
            }
        }
    }
    
    // MARK: - Hybrid Detection Logic
    
    private func startObserver(taskID: UUID) -> Bool {
        guard let pid = pendingSelectionProcessIdentifier,
              let focusedElement = pendingSelectionFocusedElement,
              pendingSelectionContextIsCurrent(
                resolvedFocusedElement: focusedElement
              ) else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
            return false
        }
        
        var observerRaw: AXObserver?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        let error = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let monitorAddress = UInt(bitPattern: refcon)
            Task { @MainActor in
                guard let pointer = UnsafeRawPointer(bitPattern: monitorAddress) else { return }
                let monitor = Unmanaged<TextSelectionMonitor>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                monitor.handleSelectionChangedNotification()
            }
        }, &observerRaw)
        
        guard error == .success, let observer = observerRaw else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.observerSetupFailed)
            return false
        }
        
        let addNotificationError = AXObserverAddNotification(
            observer,
            focusedElement,
            kAXSelectedTextChangedNotification as CFString,
            selfPointer
        )
        guard addNotificationError == .success else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.observerSetupFailed)
            return false
        }
        
        self.currentObserver = observer
        self.observerRunLoopSource = AXObserverGetRunLoopSource(observer)
        self.observedElement = focusedElement
        
        if let source = self.observerRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        // Timeout
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.pendingSelectionTaskID == taskID else { return }
            AccessibilityManager.shared.recordSelectionAttemptFailure(.observerTimedOut)
            if Self.shouldCancelSelectionTaskOnObserverTimeout(copyFallbackInFlight: self.isCopyFallbackInFlight) {
                self.cleanupPendingTask()
            } else {
                self.stopSelectionObserver()
            }
        }
        self.observationTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.observerTimeout, execute: workItem)
        return true
    }
    
    private func refreshPendingFocusedElementAssessment(
        requireUsableSelection: Bool
    ) async -> AccessibilityManager.FocusedElementAssessment? {
        guard let processIdentifier = pendingSelectionProcessIdentifier,
              let capturedWindow = pendingSelectionWindowSnapshot,
              let capturedWindowID = capturedWindow.windowID else {
            return nil
        }
        guard let assessedFocusedElement = await AccessibilityManager.shared
            .resolveAssessedFocusedElementWithRetry(
                expectedProcessIdentifier: processIdentifier,
                windowConstraint: AccessibilityManager.FocusedWindowConstraint(
                    windowID: capturedWindowID,
                    ownerPID: capturedWindow.ownerPID,
                    bounds: capturedWindow.bounds,
                    expectedSelectionWindow: pendingSelectionExpectedWindow
                ),
                bundleID: pendingSelectionBundleID,
                requireUsableSelection: requireUsableSelection
            ) else {
            return nil
        }
        // Candidate and assessment are published together so downstream
        // observer/copy gates never combine a newly focused element with an
        // assessment captured from the stale proxy it replaced.
        pendingSelectionFocusedElement = assessedFocusedElement.focusedElement
        pendingSelectionFocusedElementAssessment =
            assessedFocusedElement.assessment
        return assessedFocusedElement.assessment
    }

    private func schedulePolling(
        at mouseLocation: NSPoint,
        taskID: UUID,
        allowCopyFallback: Bool,
        observerStarted: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.accessibilityPollingDelay) { [weak self] in
            guard let self = self, self.pendingSelectionTaskID == taskID else { return }
            self.pendingAssessmentRefreshTask?.cancel()
            self.pendingAssessmentRefreshTask = Task { @MainActor [weak self] in
                guard let self, self.pendingSelectionTaskID == taskID else { return }
                let assessment = await self.refreshPendingFocusedElementAssessment(
                    requireUsableSelection: true
                )
                guard !Task.isCancelled,
                      self.pendingSelectionTaskID == taskID else {
                    return
                }
                self.pendingAssessmentRefreshTask = nil
                guard assessment != nil || self.pendingSelectionFocusedElement == nil,
                      self.pendingSelectionContextIsCurrent(
                        resolvedFocusedElement: self.pendingSelectionFocusedElement
                      ) else {
                    self.cleanupPendingTask()
                    return
                }

                let currentSnapshot = assessment?.selectionSnapshot
                if Self.shouldHandleAccessibilityDragSelection(
                    snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                    currentSnapshot: currentSnapshot,
                    startedInTextContext: self.pendingSelectionStartedInTextContext,
                    endedInTextContext: self.pendingSelectionEndedInTextContext
                ), let text = currentSnapshot?.usableText {
                    AccessibilityManager.shared.recordSelectionAcquisition(
                        source: .accessibility,
                        text: text
                    )
                    self.handleSelectionFound(
                        text: text,
                        location: mouseLocation,
                        taskID: taskID
                    )
                } else if allowCopyFallback {
                    AccessibilityManager.shared.recordSelectionAttemptFailure(
                        .accessibilityEmptySelection
                    )
                    self.scheduleCopyFallback(
                        at: mouseLocation,
                        taskID: taskID
                    )
                } else if !observerStarted {
                    self.cleanupPendingTask()
                }
            }
        }
    }

    private func scheduleCopyFallback(at mouseLocation: NSPoint, taskID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyFallbackStartDelay) { [weak self] in
            guard let self, self.pendingSelectionTaskID == taskID else { return }
            guard self.pendingSelectionContextIsCurrent(
                resolvedFocusedElement: self.pendingSelectionFocusedElement
            ) else {
                self.cleanupPendingTask()
                return
            }

            self.isCopyFallbackInFlight = true
            self.stopSelectionObserver()
            let allowMissingFocusedElement =
                AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                    bundleID: self.pendingSelectionBundleID
                )
            self.pendingCopyFallbackRequestID = AccessibilityManager.shared
                .getSelectedTextViaCopy(
                    expectedProcessIdentifier: self.pendingSelectionProcessIdentifier,
                    expectedFocusedElement: self.pendingSelectionFocusedElement,
                    expectedFocusedElementAssessment:
                        self.pendingSelectionFocusedElementAssessment?.protection,
                    allowMissingFocusedElement: allowMissingFocusedElement,
                    expectedBundleID: self.pendingSelectionBundleID,
                    expectedWindowID: self.pendingSelectionWindowID,
                    allowsAcquiredSelectionFocusFallback: true
                ) { [weak self] copiedText in
                    guard let self, self.pendingSelectionTaskID == taskID else { return }
                    self.pendingCopyFallbackRequestID = nil
                    self.isCopyFallbackInFlight = false
                    guard let copiedText,
                          !copiedText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                          ).isEmpty,
                          self.pendingAcquiredSelectionContextIsCurrent(
                            resolvedFocusedElement: self.pendingSelectionFocusedElement
                          ) else {
                        AccessibilityManager.shared.recordSelectionAttemptFailure(
                            .copyFallbackEmptySelection
                        )
                        self.cleanupPendingTask()
                        return
                    }
                    let copiedTextAllowed = Self.shouldHandleCopiedDragSelection(
                        copiedText: copiedText,
                        snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                        currentSnapshot:
                            self.pendingSelectionFocusedElementAssessment?
                                .selectionSnapshot,
                        frontmostBundleID: self.pendingSelectionBundleID,
                        startedInTextContext: self.pendingSelectionStartedInTextContext,
                        endedInTextContext: self.pendingSelectionEndedInTextContext,
                        startedInsideFocusedElementBounds:
                            self.pendingSelectionStartedInsideFocusedElementBounds,
                        endedInsideFocusedElementBounds:
                            self.pendingSelectionEndedInsideFocusedElementBounds,
                        previouslyAcquiredText: self.pendingSelectionPreviouslyAcquiredText,
                        previousAcquisitionAge: self.pendingSelectionPreviousAcquisitionAge
                    )
                    if copiedTextAllowed {
                        AccessibilityManager.shared.recordSelectionAcquisition(
                            source: .copyFallback,
                            text: copiedText
                        )
                        self.handleSelectionFound(
                            text: copiedText,
                            location: mouseLocation,
                            taskID: taskID
                        )
                    } else {
                        AccessibilityManager.shared.recordSelectionAttemptFailure(
                            .copyFallbackEmptySelection
                        )
                        self.cleanupPendingTask()
                    }
                }
        }
    }
    
    private func handleSelectionChangedNotification() {
        guard let taskID = pendingSelectionTaskID else { return }
        pendingAssessmentRefreshTask?.cancel()
        pendingAssessmentRefreshTask = Task { @MainActor [weak self] in
            guard let self, self.pendingSelectionTaskID == taskID else { return }
            let assessment = await self.refreshPendingFocusedElementAssessment(
                requireUsableSelection: true
            )
            guard !Task.isCancelled,
                  self.pendingSelectionTaskID == taskID else {
                return
            }
            self.pendingAssessmentRefreshTask = nil
            let allowMissingFocusedElement =
                AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                    bundleID: self.pendingSelectionBundleID
                )
            guard self.pendingSelectionContextIsCurrent(
                resolvedFocusedElement: self.pendingSelectionFocusedElement
            ), !AccessibilityManager.shouldSuppressCopyFallback(
                focusedElementAssessment: assessment?.protection,
                secureEventInputEnabled:
                    AccessibilityManager.shared.isSecureEventInputEnabled(),
                accessibilityEnabled:
                    AccessibilityManager.shared.isAccessibilityEnabled,
                allowMissingFocusedElement: allowMissingFocusedElement
            ) else {
                self.cleanupPendingTask()
                return
            }

            let currentSnapshot = assessment?.selectionSnapshot
            if Self.shouldHandleAccessibilityDragSelection(
                snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                currentSnapshot: currentSnapshot,
                startedInTextContext: self.pendingSelectionStartedInTextContext,
                endedInTextContext: self.pendingSelectionEndedInTextContext
            ), let text = currentSnapshot?.usableText {
                let location = NSEvent.mouseLocation
                AccessibilityManager.shared.recordSelectionAcquisition(
                    source: .accessibility,
                    text: text
                )
                self.handleSelectionFound(
                    text: text,
                    location: location,
                    taskID: taskID
                )
            }
        }
    }
    
    private func handleSelectionFound(text: String, location: NSPoint, taskID: UUID?) {
        // Stop all other tracking for this selection drop
        if let taskID = taskID, pendingSelectionTaskID != taskID { return } // Already handled
        guard pendingAcquiredSelectionContextIsCurrent(
            resolvedFocusedElement: pendingSelectionFocusedElement
        ),
              let processIdentifier = pendingSelectionProcessIdentifier else {
            cleanupPendingTask()
            return
        }
        let focusedElement = pendingSelectionFocusedElement
        let focusedElementAssessment = pendingSelectionFocusedElementAssessment
        let bundleID = pendingSelectionBundleID
        let windowID = pendingSelectionWindowID
        cleanupPendingTask()

        scheduleSelectionPresentation(
            text: text,
            location: location,
            processIdentifier: processIdentifier,
            focusedElement: focusedElement,
            focusedElementAssessment: focusedElementAssessment,
            bundleID: bundleID,
            windowID: windowID
        )
    }

    private func pendingSelectionContextIsCurrent(
        resolvedFocusedElement: AXUIElement? = nil
    ) -> Bool {
        let currentFocusedElement = resolvedFocusedElement ??
            AccessibilityManager.shared.getFocusedElement(
                expectedProcessIdentifier: pendingSelectionProcessIdentifier
            )
        return Self.shouldContinueSelectionContext(
            expectedProcessIdentifier: pendingSelectionProcessIdentifier,
            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            bundleID: pendingSelectionBundleID,
            expectedFocusedElementAvailable: pendingSelectionFocusedElement != nil,
            currentFocusedElementAvailable: currentFocusedElement != nil,
            focusedElementMatches: AccessibilityManager.areSameAccessibilityElement(
                pendingSelectionFocusedElement,
                currentFocusedElement
            )
        )
    }

    private func pendingAcquiredSelectionContextIsCurrent(
        resolvedFocusedElement: AXUIElement? = nil
    ) -> Bool {
        let currentProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentFocusedElement = resolvedFocusedElement ??
            AccessibilityManager.shared.getFocusedElement(
                expectedProcessIdentifier: pendingSelectionProcessIdentifier
            )
        let currentWindowID = Self.currentFrontmostWindowSnapshot(
            frontmostProcessID: currentProcessIdentifier
        )?.windowID
        let focusedElementMatches = AccessibilityManager.areSameAccessibilityElement(
            pendingSelectionFocusedElement,
            currentFocusedElement
        )
        let needsStructuralFocusFallback =
            pendingSelectionFocusedElement != nil && !focusedElementMatches
        let currentFocusedElementIsStructural = needsStructuralFocusFallback &&
            AccessibilityManager.shared.isStructuralSelectionFocus(
                currentFocusedElement
            )
        let focusedWindowMatches: Bool
        if needsStructuralFocusFallback {
            focusedWindowMatches = AccessibilityManager.areSameAccessibilityElement(
                AccessibilityManager.shared.selectionWindow(
                    for: pendingSelectionFocusedElement
                ),
                AccessibilityManager.shared.selectionWindow(
                    for: currentFocusedElement
                )
            )
        } else {
            focusedWindowMatches = focusedElementMatches
        }
        return Self.shouldContinueAcquiredSelectionPresentation(
            expectedProcessIdentifier: pendingSelectionProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            bundleID: pendingSelectionBundleID,
            expectedFocusedElementAvailable: pendingSelectionFocusedElement != nil,
            currentFocusedElementAvailable: currentFocusedElement != nil,
            focusedElementMatches: focusedElementMatches,
            currentFocusedElementIsStructural: currentFocusedElementIsStructural,
            focusedWindowMatches: focusedWindowMatches,
            expectedWindowID: pendingSelectionWindowID,
            currentWindowID: currentWindowID
        )
    }

    private func pendingSelectionProcessIsCurrent() -> Bool {
        AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: pendingSelectionProcessIdentifier,
            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }
    
    private func cleanupPendingTask() {
        pendingFocusedElementResolutionTask?.cancel()
        pendingFocusedElementResolutionTask = nil
        pendingAssessmentRefreshTask?.cancel()
        pendingAssessmentRefreshTask = nil
        if let requestID = pendingCopyFallbackRequestID {
            AccessibilityManager.shared.cancelSelectedTextViaCopy(requestID)
        }
        pendingCopyFallbackRequestID = nil
        isCopyFallbackInFlight = false
        pendingSelectionTaskID = nil
        pendingSelectionBaselineSnapshot = nil
        pendingSelectionStartedInTextContext = false
        pendingSelectionEndedInTextContext = false
        pendingSelectionStartedInsideFocusedElementBounds = false
        pendingSelectionEndedInsideFocusedElementBounds = false
        pendingSelectionPreviouslyAcquiredText = nil
        pendingSelectionPreviousAcquisitionAge = nil
        pendingSelectionProcessIdentifier = nil
        pendingSelectionFocusedElement = nil
        pendingSelectionFocusedElementAssessment = nil
        pendingSelectionExpectedWindow = nil
        pendingSelectionBundleID = nil
        pendingSelectionWindowID = nil
        pendingSelectionWindowSnapshot = nil
        pendingEmptyInputCheckID = nil
        
        stopSelectionObserver()
    }

    private func stopSelectionObserver() {
        observationTimeout?.cancel()
        observationTimeout = nil

        guard let observer = currentObserver else { return }
        if let element = observedElement {
            AXObserverRemoveNotification(observer, element, kAXSelectedTextChangedNotification as CFString)
        }
        if let source = observerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        currentObserver = nil
        observedElement = nil
        observerRunLoopSource = nil
    }
    
    private func postTextSelectedNotification(
        text: String,
        location: NSPoint,
        processIdentifier: pid_t,
        focusedElement: AXUIElement?,
        windowID: CGWindowID?,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment?
    ) {
        NotificationCenter.default.post(
            name: TextSelectionMonitor.textSelectedNotification,
            object: self,
            userInfo: Self.textSelectedNotificationUserInfo(
                text: text,
                location: location,
                processIdentifier: processIdentifier,
                focusedElement: focusedElement,
                windowID: windowID,
                focusedElementAssessment: focusedElementAssessment
            )
        )
    }

    private func scheduleSelectionPresentation(
        text: String,
        location: NSPoint,
        processIdentifier: pid_t,
        focusedElement: AXUIElement?,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment?,
        bundleID: String?,
        windowID: CGWindowID?
    ) {
        cancelPendingSelectionPresentation()
        let presentationRequestID = UUID()
        pendingPresentationRequestID = presentationRequestID

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingPresentationRequestID == presentationRequestID else {
                return
            }
            self.pendingPresentationWorkItem = nil
            let currentProcessIdentifier =
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            let currentWindowID = Self.currentFrontmostWindowSnapshot(
                frontmostProcessID: currentProcessIdentifier
            )?.windowID
            guard Self.shouldContinueAcquiredSelectionPresentation(
                expectedProcessIdentifier: processIdentifier,
                currentProcessIdentifier: currentProcessIdentifier,
                bundleID: bundleID,
                expectedFocusedElementAvailable: focusedElement != nil,
                currentFocusedElementAvailable: focusedElement != nil,
                focusedElementMatches: focusedElement != nil,
                currentFocusedElementIsStructural: false,
                focusedWindowMatches: true,
                expectedWindowID: windowID,
                currentWindowID: currentWindowID
            ), !AccessibilityManager.shouldSuppressCopyFallback(
                focusedElementAssessment: focusedElementAssessment?.protection,
                secureEventInputEnabled:
                    AccessibilityManager.shared.isSecureEventInputEnabled(),
                accessibilityEnabled:
                    AccessibilityManager.shared.isAccessibilityEnabled,
                allowMissingFocusedElement:
                    AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                        bundleID: bundleID
                    )
            ) else {
                self.finishPendingSelectionPresentation(
                    requestID: presentationRequestID
                )
                return
            }
            self.finishPendingSelectionPresentation(
                requestID: presentationRequestID
            )
            self.postTextSelectedNotification(
                text: text,
                location: location,
                processIdentifier: processIdentifier,
                focusedElement: focusedElement,
                windowID: windowID,
                focusedElementAssessment: focusedElementAssessment
            )
        }

        pendingPresentationWorkItem = workItem
        presentationCancelMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.cancelPendingSelectionPresentation()
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + mouseSelectionPresentationDelay,
            execute: workItem
        )
    }

    private func cancelPendingSelectionPresentation() {
        pendingPresentationWorkItem?.cancel()
        pendingPresentationWorkItem = nil
        pendingPresentationRequestID = nil

        if let monitor = presentationCancelMonitor {
            NSEvent.removeMonitor(monitor)
            presentationCancelMonitor = nil
        }
    }

    private func finishPendingSelectionPresentation(requestID: UUID) {
        guard pendingPresentationRequestID == requestID else { return }
        pendingPresentationWorkItem = nil
        pendingPresentationRequestID = nil
        if let monitor = presentationCancelMonitor {
            NSEvent.removeMonitor(monitor)
            presentationCancelMonitor = nil
        }
    }
    
    private func checkForEmptyTextInputClick(
        at mouseLocation: NSPoint,
        expectedProcessIdentifier: pid_t?,
        requestID: UUID
    ) {
        lastEmptyInputCheckLocation = mouseLocation

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: frontmostApp?.processIdentifier
        ), Self.shouldAllowEmptyTextInputCheck(
            bundleID: frontmostApp?.bundleIdentifier,
            localizedName: frontmostApp?.localizedName
        ) else {
            pendingEmptyInputCheckID = nil
            return
        }

        // Quick check: If pasteboard is empty, don't even bother checking accessibility
        guard Self.hasUsableClipboardText(NSPasteboard.general.string(forType: .string)) else {
            pendingEmptyInputCheckID = nil
            return
        }

        // This method is invoked on the main queue. Keep AppKit access and the bounded AX
        // queries on that queue, while reusing one focused-element lookup.
        guard let focusedElement = AccessibilityManager.shared.getFocusedElement(
            expectedProcessIdentifier: expectedProcessIdentifier
        ) else {
            pendingEmptyInputCheckID = nil
            return
        }
        let selectedText = AccessibilityManager.shared.selectedText(from: focusedElement)
        let isTextInput = AccessibilityManager.shared.isTextInputElement(
            at: mouseLocation,
            focusedElement: focusedElement
        )

        guard pendingEmptyInputCheckID == requestID else { return }
        pendingEmptyInputCheckID = nil
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ), AccessibilityManager.areSameAccessibilityElement(
            focusedElement,
            AccessibilityManager.shared.getFocusedElement(
                expectedProcessIdentifier: expectedProcessIdentifier
            )
        ), selectedText == nil, isTextInput,
              let expectedProcessIdentifier else {
            return
        }

        NotificationCenter.default.post(
            name: TextSelectionMonitor.emptyTextInputClickedNotification,
            object: self,
            userInfo: Self.emptyTextInputClickedNotificationUserInfo(
                location: mouseLocation,
                processIdentifier: expectedProcessIdentifier,
                focusedElement: focusedElement
            )
        )
    }
}
