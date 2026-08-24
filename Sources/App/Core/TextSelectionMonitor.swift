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
        windowID: CGWindowID? = nil
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
    private var mouseDownLocation: NSPoint?
    private var mouseDownDragPasteboardChangeCount: Int?
    private var mouseDownWindowSnapshot: FrontmostWindowSnapshot?
    private var mouseDownProcessIdentifier: pid_t?
    private var mouseDownSelectionSnapshot: AccessibilityManager.SelectionSnapshot?
    private var mouseDownStartedInTextContext = false
    private var mouseDownInsideFocusedElementBounds = false
    private var mouseDownPreviouslyAcquiredText: String?
    private var mouseDownPreviousAcquisitionAge: TimeInterval?
    private var pendingSelectionBaselineSnapshot: AccessibilityManager.SelectionSnapshot?
    private var pendingSelectionStartedInTextContext = false
    private var pendingSelectionEndedInTextContext = false
    private var pendingSelectionStartedInsideFocusedElementBounds = false
    private var pendingSelectionEndedInsideFocusedElementBounds = false
    private var pendingSelectionPreviouslyAcquiredText: String?
    private var pendingSelectionPreviousAcquisitionAge: TimeInterval?
    private var pendingSelectionProcessIdentifier: pid_t?
    private var pendingSelectionFocusedElement: AXUIElement?
    private var pendingSelectionBundleID: String?
    private var pendingSelectionWindowID: CGWindowID?
    
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
        currentSnapshot: AccessibilityManager.SelectionSnapshot?
    ) -> Bool {
        guard let currentSnapshot,
              currentSnapshot.canReadSelectedTextViaAccessibility,
              currentSnapshot.usableText != nil else { return false }
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

        return AccessibilityManager.shouldAllowContextlessBlindCopyFallback(bundleID: bundleID)
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
        cleanupPendingTask()
        cancelPendingSelectionPresentation()
        resetMouseDownState()

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
        if let focusedElement = AccessibilityManager.shared.getFocusedElement() {
            mouseDownSelectionSnapshot = AccessibilityManager.shared.currentSelectionSnapshot(
                for: focusedElement
            )
            mouseDownStartedInTextContext = Self.isTextSelectionContext(
                at: mouseLocation,
                focusedElement: focusedElement
            )
            mouseDownInsideFocusedElementBounds =
                AccessibilityManager.shared.isPointInsideFocusedElementBounds(
                    at: mouseLocation,
                    focusedElement: focusedElement
                )
        }
        mouseDownPreviouslyAcquiredText = AccessibilityManager.shared.lastSelectionAcquiredText
        mouseDownPreviousAcquisitionAge = AccessibilityManager.shared.lastSelectionAcquisitionStatus.map {
            Date().timeIntervalSince($0.timestamp)
        }
    }

    private func resetMouseDownState() {
        mouseDownLocation = nil
        mouseDownDragPasteboardChangeCount = nil
        mouseDownWindowSnapshot = nil
        mouseDownProcessIdentifier = nil
        mouseDownSelectionSnapshot = nil
        mouseDownStartedInTextContext = false
        mouseDownInsideFocusedElementBounds = false
        mouseDownPreviouslyAcquiredText = nil
        mouseDownPreviousAcquisitionAge = nil
    }

    private func handleMouseUp(at upLocation: NSPoint) {
        guard let downLocation = mouseDownLocation else { return }
        cancelPendingSelectionPresentation()

        let dragPasteboard = NSPasteboard(name: .drag)
        let dragPasteboardTypes = dragPasteboard.types?.map(\.rawValue) ?? []
        let dragPasteboardChangeCountAtMouseDown = mouseDownDragPasteboardChangeCount ?? dragPasteboard.changeCount
        let windowSnapshotAtMouseDown = mouseDownWindowSnapshot
        let processIdentifierAtMouseDown = mouseDownProcessIdentifier

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
        let focusedElementAtMouseUp = AccessibilityManager.shared.getFocusedElement()
        guard focusedElementAtMouseUp != nil ||
                AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                    bundleID: frontmostApp.bundleIdentifier
                ) else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
            resetMouseDownState()
            return
        }
        let selectionProcessIdentifier = processIdentifierAtMouseDown
        let selectionBundleID = frontmostApp.bundleIdentifier
        let windowSnapshotAtMouseUp = Self.currentFrontmostWindowSnapshot(
            frontmostProcessID: frontmostApp.processIdentifier,
            matching: windowSnapshotAtMouseDown?.windowID
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

        if Self.shouldSuppressForFrontmostApp(
            bundleID: frontmostApp.bundleIdentifier,
            localizedName: frontmostApp.localizedName,
            isFocusedSelectionEditable: focusedElementAtMouseUp.map {
                AccessibilityManager.shared.isSelectionEditable($0)
            } ?? false
        ) {
            resetMouseDownState()
            return
        }
        
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
        let endedInTextContext = focusedElementAtMouseUp.map {
            Self.isTextSelectionContext(at: upLocation, focusedElement: $0)
        } ?? false
        let startedInsideFocusedElementBounds = mouseDownInsideFocusedElementBounds
        let endedInsideFocusedElementBounds = focusedElementAtMouseUp.map {
            AccessibilityManager.shared.isPointInsideFocusedElementBounds(
                at: upLocation,
                focusedElement: $0
            )
        } ?? false
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
            self.pendingSelectionBundleID = selectionBundleID
            self.pendingSelectionWindowID = selectionWindowID
            
            // Wait a tiny bit then do a hybrid check: Observer + Polling
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionSettleDelay) { [weak self] in
                guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                let allowMissingFocusedElement =
                    AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                        bundleID: self.pendingSelectionBundleID
                    )
                guard self.pendingSelectionProcessIsCurrent(),
                      !AccessibilityManager.shared.shouldSuppressSelectionPresentation(
                        allowMissingFocusedElement: allowMissingFocusedElement
                      ) else {
                    self.cleanupPendingTask()
                    return
                }
                // Focus may legitimately move from the previously focused
                // control into the control where this gesture began. Bind the
                // request only after the post-mouse-up settling interval.
                let rawFocusedElement = AccessibilityManager.shared.getFocusedElement()
                guard rawFocusedElement != nil || allowMissingFocusedElement else {
                    AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
                    self.cleanupPendingTask()
                    return
                }
                // Preserve the actual AX target, including Telegram's AXWindow.
                // Treating a structural focus as nil would discard the window
                // identity and turn subsequent Cmd+C checks into a PID-only gate.
                self.pendingSelectionFocusedElement = rawFocusedElement

                let currentSnapshot = rawFocusedElement.flatMap {
                    AccessibilityManager.shared.currentSelectionSnapshot(for: $0)
                }

                if Self.shouldHandleAccessibilityDragSelection(
                    snapshotAtMouseDown: snapshotAtMouseDown,
                    currentSnapshot: currentSnapshot
                ), let text = currentSnapshot?.usableText {
                    AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
                    self.handleSelectionFound(text: text, location: upLocation, taskID: taskID)
                } else {
                    AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
                    // Try to attach an observer
                    let observerStarted = self.startObserver(taskID: taskID)
                    
                    // Concurrently start polling. If native AX has not yielded selected text yet,
                    // still allow Cmd+C fallback for browsers / webviews / Chromium apps.
                    self.schedulePolling(
                        at: upLocation,
                        taskID: taskID,
                        allowCopyFallback: true,
                        observerStarted: observerStarted
                    )
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
              pendingSelectionContextIsCurrent() else {
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
    
    private func schedulePolling(
        at mouseLocation: NSPoint,
        taskID: UUID,
        allowCopyFallback: Bool,
        observerStarted: Bool
    ) {
        // Try native accessibility polling once before falling back to copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.accessibilityPollingDelay) { [weak self] in
            guard let self = self, self.pendingSelectionTaskID == taskID else { return }
            guard self.pendingSelectionContextIsCurrent() else {
                self.cleanupPendingTask()
                return
            }

            let currentSnapshot = self.pendingSelectionFocusedElement.flatMap {
                AccessibilityManager.shared.currentSelectionSnapshot(for: $0)
            }

            if Self.shouldHandleAccessibilityDragSelection(
                snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                currentSnapshot: currentSnapshot
            ), let text = currentSnapshot?.usableText {
                AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
                self.handleSelectionFound(text: text, location: mouseLocation, taskID: taskID)
            } else if allowCopyFallback {
                AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
                // If native polling fails, immediately fire the Cmd+C fallback for Electron/Qt apps (e.g., Telegram).
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyFallbackStartDelay) { [weak self] in
                    guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                    guard self.pendingSelectionContextIsCurrent() else {
                        self.cleanupPendingTask()
                        return
                    }

                    self.isCopyFallbackInFlight = true
                    self.stopSelectionObserver()
                    let allowMissingFocusedElement =
                        AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                            bundleID: self.pendingSelectionBundleID
                        )
                    self.pendingCopyFallbackRequestID = AccessibilityManager.shared.getSelectedTextViaCopy(
                        expectedProcessIdentifier: self.pendingSelectionProcessIdentifier,
                        expectedFocusedElement: self.pendingSelectionFocusedElement,
                        allowMissingFocusedElement: allowMissingFocusedElement,
                        expectedBundleID: self.pendingSelectionBundleID,
                        expectedWindowID: self.pendingSelectionWindowID,
                        allowsAcquiredSelectionFocusFallback: true
                    ) { [weak self] copiedText in
                        guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                        self.pendingCopyFallbackRequestID = nil
                        self.isCopyFallbackInFlight = false
                        guard let copiedText,
                              !copiedText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                              ).isEmpty,
                              self.pendingAcquiredSelectionContextIsCurrent() else {
                            AccessibilityManager.shared.recordSelectionAttemptFailure(.copyFallbackEmptySelection)
                            self.cleanupPendingTask()
                            return
                        }
                        let copiedTextAllowed = Self.shouldHandleCopiedDragSelection(
                            copiedText: copiedText,
                            snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                            currentSnapshot: self.pendingSelectionFocusedElement.flatMap {
                                AccessibilityManager.shared.currentSelectionSnapshot(for: $0)
                            },
                            frontmostBundleID: self.pendingSelectionBundleID,
                            startedInTextContext: self.pendingSelectionStartedInTextContext,
                            endedInTextContext: self.pendingSelectionEndedInTextContext,
                            startedInsideFocusedElementBounds: self.pendingSelectionStartedInsideFocusedElementBounds,
                            endedInsideFocusedElementBounds: self.pendingSelectionEndedInsideFocusedElementBounds,
                            previouslyAcquiredText: self.pendingSelectionPreviouslyAcquiredText,
                            previousAcquisitionAge: self.pendingSelectionPreviousAcquisitionAge
                        )
                        if copiedTextAllowed {
                            let text = copiedText
                            AccessibilityManager.shared.recordSelectionAcquisition(source: .copyFallback, text: text)
                            self.handleSelectionFound(text: text, location: mouseLocation, taskID: taskID)
                        } else {
                            AccessibilityManager.shared.recordSelectionAttemptFailure(.copyFallbackEmptySelection)
                            self.cleanupPendingTask()
                        }
                    }
                }
            } else if !observerStarted {
                self.cleanupPendingTask()
            }
        }
    }
    
    private func handleSelectionChangedNotification() {
        let taskID = self.pendingSelectionTaskID
        let allowMissingFocusedElement =
            AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                bundleID: pendingSelectionBundleID
            )

        guard pendingSelectionContextIsCurrent(),
              !AccessibilityManager.shared.shouldSuppressSelectionPresentation(
                allowMissingFocusedElement: allowMissingFocusedElement
              ) else {
            cleanupPendingTask()
            return
        }

        let currentSnapshot = pendingSelectionFocusedElement.flatMap {
            AccessibilityManager.shared.currentSelectionSnapshot(for: $0)
        }
        if Self.shouldHandleAccessibilityDragSelection(
            snapshotAtMouseDown: pendingSelectionBaselineSnapshot,
            currentSnapshot: currentSnapshot
        ), let text = currentSnapshot?.usableText {
            let location = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
            handleSelectionFound(text: text, location: location, taskID: taskID)
        }
    }
    
    private func handleSelectionFound(text: String, location: NSPoint, taskID: UUID?) {
        // Stop all other tracking for this selection drop
        if let taskID = taskID, pendingSelectionTaskID != taskID { return } // Already handled
        guard pendingAcquiredSelectionContextIsCurrent(),
              let processIdentifier = pendingSelectionProcessIdentifier else {
            cleanupPendingTask()
            return
        }
        let focusedElement = pendingSelectionFocusedElement
        let bundleID = pendingSelectionBundleID
        let windowID = pendingSelectionWindowID
        cleanupPendingTask()

        scheduleSelectionPresentation(
            text: text,
            location: location,
            processIdentifier: processIdentifier,
            focusedElement: focusedElement,
            bundleID: bundleID,
            windowID: windowID
        )
    }

    private func pendingSelectionContextIsCurrent() -> Bool {
        let currentFocusedElement = AccessibilityManager.shared.getFocusedElement()
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

    private func pendingAcquiredSelectionContextIsCurrent() -> Bool {
        let currentProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentFocusedElement = AccessibilityManager.shared.getFocusedElement()
        let currentWindowID = Self.currentFrontmostWindowSnapshot(
            frontmostProcessID: currentProcessIdentifier,
            matching: pendingSelectionWindowID
        )?.windowID
        let expectedSelectionWindow = AccessibilityManager.shared.selectionWindow(
            for: pendingSelectionFocusedElement
        )
        let currentSelectionWindow = AccessibilityManager.shared.selectionWindow(
            for: currentFocusedElement
        )
        return Self.shouldContinueAcquiredSelectionPresentation(
            expectedProcessIdentifier: pendingSelectionProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            bundleID: pendingSelectionBundleID,
            expectedFocusedElementAvailable: pendingSelectionFocusedElement != nil,
            currentFocusedElementAvailable: currentFocusedElement != nil,
            focusedElementMatches: AccessibilityManager.areSameAccessibilityElement(
                pendingSelectionFocusedElement,
                currentFocusedElement
            ),
            currentFocusedElementIsStructural:
                AccessibilityManager.shared.isStructuralSelectionFocus(currentFocusedElement),
            focusedWindowMatches: AccessibilityManager.areSameAccessibilityElement(
                expectedSelectionWindow,
                currentSelectionWindow
            ),
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
        pendingSelectionBundleID = nil
        pendingSelectionWindowID = nil
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
        windowID: CGWindowID?
    ) {
        NotificationCenter.default.post(
            name: TextSelectionMonitor.textSelectedNotification,
            object: self,
            userInfo: Self.textSelectedNotificationUserInfo(
                text: text,
                location: location,
                processIdentifier: processIdentifier,
                focusedElement: focusedElement,
                windowID: windowID
            )
        )
    }

    private func scheduleSelectionPresentation(
        text: String,
        location: NSPoint,
        processIdentifier: pid_t,
        focusedElement: AXUIElement?,
        bundleID: String?,
        windowID: CGWindowID?
    ) {
        cancelPendingSelectionPresentation()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.cancelPendingSelectionPresentation()
            let currentProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let currentFocusedElement = AccessibilityManager.shared.getFocusedElement()
            let currentWindowID = Self.currentFrontmostWindowSnapshot(
                frontmostProcessID: currentProcessIdentifier,
                matching: windowID
            )?.windowID
            let expectedSelectionWindow = AccessibilityManager.shared.selectionWindow(
                for: focusedElement
            )
            let currentSelectionWindow = AccessibilityManager.shared.selectionWindow(
                for: currentFocusedElement
            )
            guard Self.shouldContinueAcquiredSelectionPresentation(
                expectedProcessIdentifier: processIdentifier,
                currentProcessIdentifier: currentProcessIdentifier,
                bundleID: bundleID,
                expectedFocusedElementAvailable: focusedElement != nil,
                currentFocusedElementAvailable: currentFocusedElement != nil,
                focusedElementMatches: AccessibilityManager.areSameAccessibilityElement(
                    focusedElement,
                    currentFocusedElement
                ),
                currentFocusedElementIsStructural:
                    AccessibilityManager.shared.isStructuralSelectionFocus(currentFocusedElement),
                focusedWindowMatches: AccessibilityManager.areSameAccessibilityElement(
                    expectedSelectionWindow,
                    currentSelectionWindow
                ),
                expectedWindowID: windowID,
                currentWindowID: currentWindowID
            ), !AccessibilityManager.shared.shouldSuppressSelectionPresentation(
                allowMissingFocusedElement:
                    AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                        bundleID: bundleID
                    )
            ) else {
                return
            }
            self.postTextSelectedNotification(
                text: text,
                location: location,
                processIdentifier: processIdentifier,
                focusedElement: focusedElement,
                windowID: windowID
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
        guard let focusedElement = AccessibilityManager.shared.getFocusedElement() else {
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
            AccessibilityManager.shared.getFocusedElement()
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
