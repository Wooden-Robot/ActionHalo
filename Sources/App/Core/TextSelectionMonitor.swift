import Cocoa

/// Monitors global mouse events to detect text selection
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

    private static let suppressedFrontmostBundleIDs: Set<String> = [
        "comopenfireapp",
        "comappledock",
        "comapplefinder",
        "comapplewindowmanager"
    ]
    private static let suppressedFrontmostNames: Set<String> = [
        "openfire",
        "finder",
        "dock",
        "desktop"
    ]
    
    static let shared = TextSelectionMonitor()
    
    /// Notification posted when text is selected. UserInfo contains "text" and "mouseLocation"
    static let textSelectedNotification = Notification.Name("OpenFireTextSelected")

    static func hasUsableClipboardText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldSuppressForFileDragPasteboard(typeIdentifiers: [String]) -> Bool {
        let normalizedTypes = Set(typeIdentifiers.map { $0.lowercased() })
        let fileDragTypeHints: Set<String> = [
            NSPasteboard.PasteboardType.fileURL.rawValue.lowercased(),
            "nsfilenamespboardtype",
            "com.apple.pasteboard.promised-file-url"
        ]

        return !normalizedTypes.intersection(fileDragTypeHints).isEmpty
    }

    static func shouldSuppressForFrontmostApp(bundleID: String?, localizedName: String?) -> Bool {
        let normalizedBundleID = normalizeFrontmostAppIdentifier(bundleID)
        let normalizedName = normalizeFrontmostAppIdentifier(localizedName)

        if suppressedFrontmostBundleIDs.contains(normalizedBundleID) || suppressedFrontmostNames.contains(normalizedName) {
            return true
        }

        let knownScreenCaptureHints = [
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

        return knownScreenCaptureHints.contains { hint in
            normalizedBundleID.contains(hint) || normalizedName.contains(hint)
        }
    }

    static func shouldSuppressForFrontmostApp(
        bundleID: String?,
        localizedName: String?,
        isFocusedSelectionEditable: Bool
    ) -> Bool {
        if isFocusedSelectionEditable {
            return false
        }

        return shouldSuppressForFrontmostApp(bundleID: bundleID, localizedName: localizedName)
    }

    static func shouldAllowEmptyTextInputCheck(
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

    static func isFileDragInProgress(
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

    static func currentFrontmostWindowSnapshot(
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

    private static func windowID(from windowInfo: [String: Any]) -> CGWindowID? {
        if let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID {
            return windowID
        }
        if let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber {
            return CGWindowID(windowNumber.uint32Value)
        }
        return nil
    }

    static func didFrontmostWindowMove(
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
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private(set) var lastMonitoringStartFailure: MonitoringStartFailure?
    private var mouseDownLocation: NSPoint?
    private var mouseDownDragPasteboardChangeCount: Int?
    private var mouseDownWindowSnapshot: FrontmostWindowSnapshot?
    private var mouseDownSelectionSnapshot: AccessibilityManager.SelectionSnapshot?
    private var mouseDownStartedInTextContext = false
    private var mouseDownInsideFocusedElementBounds = false
    private var mouseDownPreviouslyAcquiredText: String?
    private var pendingSelectionBaselineSnapshot: AccessibilityManager.SelectionSnapshot?
    private var pendingSelectionStartedInTextContext = false
    private var pendingSelectionEndedInTextContext = false
    private var pendingSelectionStartedInsideFocusedElementBounds = false
    private var pendingSelectionEndedInsideFocusedElementBounds = false
    private var pendingSelectionPreviouslyAcquiredText: String?
    private var pendingSelectionProcessIdentifier: pid_t?
    private var pendingSelectionBundleID: String?
    
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
    static let selectionSettleDelay: TimeInterval = 0.05
    static let accessibilityPollingDelay: TimeInterval = 0.1
    static let copyFallbackStartDelay: TimeInterval = 0.05
    static let observerTimeout: TimeInterval = 0.8
    
    private init() {}

    private static func normalizeFrontmostAppIdentifier(_ value: String?) -> String {
        guard let value else { return "" }
        let lowered = value.lowercased()
        return lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func monitoringStartFailure(accessibilityEnabled: Bool, eventTapCreated: Bool) -> MonitoringStartFailure? {
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
            NSLog("[OpenFire] Cannot start monitoring: accessibility permission not granted")
            return false
        }
        
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                      (1 << CGEventType.leftMouseUp.rawValue)
        
        // Create event tap callback
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<TextSelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
            
            // Re-enable tap if disabled by system
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            if type == .leftMouseDown || type == .leftMouseUp {
                let mouseLocation = NSEvent.mouseLocation
                DispatchQueue.main.async {
                    guard monitor.isMonitoring else { return }
                    if type == .leftMouseDown {
                        monitor.handleMouseDown(at: mouseLocation)
                    } else {
                        monitor.handleMouseUp(at: mouseLocation)
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
            NSLog("[OpenFire] Failed to create event tap. Ensure accessibility permission is granted.")
            return false
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        lastMonitoringStartFailure = nil
        NSLog("[OpenFire] Text selection monitoring started")
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
        
        NSLog("[OpenFire] Text selection monitoring stopped")
    }
    
    // MARK: - Event Handling
    
    /// Notification posted when an empty text input is clicked
    static let emptyTextInputClickedNotification = Notification.Name("OpenFireEmptyTextInputClicked")

    static func shouldTreatMouseInteractionAsSelectionTrigger(distance: CGFloat, minimumDragDistance: CGFloat) -> Bool {
        distance >= minimumDragDistance
    }

    static func isTextSelectionContext(at point: NSPoint) -> Bool {
        AccessibilityManager.shared.isTextElement(at: point) ||
        AccessibilityManager.shared.isTextInputElement(at: point) ||
        AccessibilityManager.shared.isFocusedTextSelectionContext(at: point)
    }

    static func shouldHandleAccessibilityDragSelection(
        snapshotAtMouseDown: AccessibilityManager.SelectionSnapshot?,
        currentSnapshot: AccessibilityManager.SelectionSnapshot?
    ) -> Bool {
        guard let currentSnapshot,
              currentSnapshot.canReadSelectedTextViaAccessibility,
              currentSnapshot.normalizedText != nil else { return false }
        return AccessibilityManager.didSelectionChange(from: snapshotAtMouseDown, to: currentSnapshot)
    }

    static func shouldCancelSelectionTaskOnObserverTimeout(copyFallbackInFlight: Bool) -> Bool {
        !copyFallbackInFlight
    }

    static func shouldHandleCopiedDragSelection(
        copiedText: String?,
        snapshotAtMouseDown: AccessibilityManager.SelectionSnapshot?,
        currentSnapshot: AccessibilityManager.SelectionSnapshot?,
        frontmostBundleID: String?,
        startedInTextContext: Bool,
        endedInTextContext: Bool,
        startedInsideFocusedElementBounds: Bool,
        endedInsideFocusedElementBounds: Bool,
        previouslyAcquiredText: String? = nil
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
           previouslyAcquiredText?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
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
        mouseDownLocation = mouseLocation
        mouseDownDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        mouseDownWindowSnapshot = Self.currentFrontmostWindowSnapshot(
            containing: AccessibilityManager.coreGraphicsScreenPoint(for: mouseLocation)
        )
        mouseDownSelectionSnapshot = AccessibilityManager.shared.currentSelectionSnapshot()
        mouseDownStartedInTextContext = Self.isTextSelectionContext(at: mouseLocation)
        mouseDownInsideFocusedElementBounds =
            AccessibilityManager.shared.isPointInsideFocusedElementBounds(at: mouseLocation)
        mouseDownPreviouslyAcquiredText = AccessibilityManager.shared.lastSelectionAcquiredText
    }

    private func resetMouseDownState() {
        mouseDownLocation = nil
        mouseDownDragPasteboardChangeCount = nil
        mouseDownWindowSnapshot = nil
        mouseDownSelectionSnapshot = nil
        mouseDownStartedInTextContext = false
        mouseDownInsideFocusedElementBounds = false
        mouseDownPreviouslyAcquiredText = nil
    }

    private func handleMouseUp(at upLocation: NSPoint) {
        guard let downLocation = mouseDownLocation else { return }
        cancelPendingSelectionPresentation()

        let dragPasteboard = NSPasteboard(name: .drag)
        let dragPasteboardTypes = dragPasteboard.types?.map(\.rawValue) ?? []
        let dragPasteboardChangeCountAtMouseDown = mouseDownDragPasteboardChangeCount ?? dragPasteboard.changeCount
        let windowSnapshotAtMouseDown = mouseDownWindowSnapshot

        if Self.isFileDragInProgress(
            dragPasteboardChangeCountAtMouseDown: dragPasteboardChangeCountAtMouseDown,
            currentDragPasteboardChangeCount: dragPasteboard.changeCount,
            typeIdentifiers: dragPasteboardTypes
        ) {
            resetMouseDownState()
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let selectionProcessIdentifier = frontmostApp?.processIdentifier
        let selectionBundleID = frontmostApp?.bundleIdentifier
        if Self.shouldSuppressForFrontmostApp(
            bundleID: frontmostApp?.bundleIdentifier,
            localizedName: frontmostApp?.localizedName,
            isFocusedSelectionEditable: AccessibilityManager.shared.isFocusedSelectionEditable()
        ) {
            resetMouseDownState()
            return
        }
        
        // Check blacklist
        if let bundleId = frontmostApp?.bundleIdentifier {
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

        if Self.didFrontmostWindowMove(
            from: windowSnapshotAtMouseDown,
            to: Self.currentFrontmostWindowSnapshot(
                frontmostApplication: frontmostApp,
                matching: windowSnapshotAtMouseDown?.windowID
            )
        ) {
            resetMouseDownState()
            return
        }
        
        let startedInTextContext = mouseDownStartedInTextContext
        let endedInTextContext = Self.isTextSelectionContext(at: upLocation)
        let startedInsideFocusedElementBounds = mouseDownInsideFocusedElementBounds
        let endedInsideFocusedElementBounds = AccessibilityManager.shared.isPointInsideFocusedElementBounds(at: upLocation)
        let previouslyAcquiredText = mouseDownPreviouslyAcquiredText
        
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
            self.pendingSelectionProcessIdentifier = selectionProcessIdentifier
            self.pendingSelectionBundleID = selectionBundleID
            
            // Wait a tiny bit then do a hybrid check: Observer + Polling
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionSettleDelay) { [weak self] in
                guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                guard self.pendingSelectionProcessIsCurrent(),
                      !AccessibilityManager.shared.shouldSuppressSelectionPresentation() else {
                    self.cleanupPendingTask()
                    return
                }

                let currentSnapshot = AccessibilityManager.shared.currentSelectionSnapshot()

                if Self.shouldHandleAccessibilityDragSelection(
                    snapshotAtMouseDown: snapshotAtMouseDown,
                    currentSnapshot: currentSnapshot
                ), let text = currentSnapshot?.normalizedText {
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
            NSLog("[OpenFire-Debug] Detected single click, checking for text input...")
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
              AccessibilityManager.isExpectedCopyFallbackProcess(
                expectedProcessIdentifier: pid,
                currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
              ) else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
            return false
        }
        
        var observerRaw: AXObserver?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        let error = AXObserverCreate(pid, { observer, element, notification, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<TextSelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleSelectionChangedNotification(element: element)
        }, &observerRaw)
        
        guard error == .success, let observer = observerRaw, let focusedElement = AccessibilityManager.shared.getFocusedElement() else {
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
            NSLog("[OpenFire-Debug] Failed to register AX selection observer: \(addNotificationError.rawValue)")
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
            NSLog("[OpenFire-Debug] AXObserver timeout: No text selection detected within %.2fs.", Self.observerTimeout)
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
            guard self.pendingSelectionProcessIsCurrent() else {
                self.cleanupPendingTask()
                return
            }

            let currentSnapshot = AccessibilityManager.shared.currentSelectionSnapshot()

            if Self.shouldHandleAccessibilityDragSelection(
                snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                currentSnapshot: currentSnapshot
            ), let text = currentSnapshot?.normalizedText {
                NSLog("[OpenFire-Debug] Text found via Polling Fallback at 0.1s.")
                AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
                self.handleSelectionFound(text: text, location: mouseLocation, taskID: taskID)
            } else if allowCopyFallback {
                AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
                // If native polling fails, immediately fire the Cmd+C fallback for Electron/Qt apps (e.g., Telegram).
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyFallbackStartDelay) { [weak self] in
                    guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                    guard self.pendingSelectionProcessIsCurrent() else {
                        self.cleanupPendingTask()
                        return
                    }

                    self.isCopyFallbackInFlight = true
                    self.stopSelectionObserver()
                    self.pendingCopyFallbackRequestID = AccessibilityManager.shared.getSelectedTextViaCopy(
                        expectedProcessIdentifier: self.pendingSelectionProcessIdentifier
                    ) { [weak self] copiedText in
                        guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                        self.pendingCopyFallbackRequestID = nil
                        self.isCopyFallbackInFlight = false
                        guard AccessibilityManager.isExpectedCopyFallbackProcess(
                            expectedProcessIdentifier: self.pendingSelectionProcessIdentifier,
                            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
                        ) else {
                            AccessibilityManager.shared.recordSelectionAttemptFailure(.copyFallbackEmptySelection)
                            self.cleanupPendingTask()
                            return
                        }
                        let copiedTextAllowed = Self.shouldHandleCopiedDragSelection(
                            copiedText: copiedText,
                            snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                            currentSnapshot: AccessibilityManager.shared.currentSelectionSnapshot(),
                            frontmostBundleID: self.pendingSelectionBundleID,
                            startedInTextContext: self.pendingSelectionStartedInTextContext,
                            endedInTextContext: self.pendingSelectionEndedInTextContext,
                            startedInsideFocusedElementBounds: self.pendingSelectionStartedInsideFocusedElementBounds,
                            endedInsideFocusedElementBounds: self.pendingSelectionEndedInsideFocusedElementBounds,
                            previouslyAcquiredText: self.pendingSelectionPreviouslyAcquiredText
                        )
                        if copiedTextAllowed, let text = copiedText, !text.isEmpty {
                            NSLog("[OpenFire-Debug] Text found via Cmd+C Fallback after 0.15s.")
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
    
    private func handleSelectionChangedNotification(element _: AXUIElement) {
        let taskID = self.pendingSelectionTaskID

        guard pendingSelectionProcessIsCurrent(),
              !AccessibilityManager.shared.shouldSuppressSelectionPresentation() else {
            cleanupPendingTask()
            return
        }

        let currentSnapshot = AccessibilityManager.shared.currentSelectionSnapshot()
        if Self.shouldHandleAccessibilityDragSelection(
            snapshotAtMouseDown: pendingSelectionBaselineSnapshot,
            currentSnapshot: currentSnapshot
        ), let text = currentSnapshot?.normalizedText {
            let location = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
            handleSelectionFound(text: text, location: location, taskID: taskID)
        }
    }
    
    private func handleSelectionFound(text: String, location: NSPoint, taskID: UUID?) {
        // Stop all other tracking for this selection drop
        if let taskID = taskID, pendingSelectionTaskID != taskID { return } // Already handled
        guard pendingSelectionProcessIsCurrent(),
              let processIdentifier = pendingSelectionProcessIdentifier else {
            cleanupPendingTask()
            return
        }
        
        cleanupPendingTask()

        scheduleSelectionPresentation(
            text: text,
            location: location,
            processIdentifier: processIdentifier
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
        pendingSelectionProcessIdentifier = nil
        pendingSelectionBundleID = nil
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
        processIdentifier: pid_t
    ) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: TextSelectionMonitor.textSelectedNotification,
                object: self,
                userInfo: [
                    "text": text,
                    "mouseLocation": NSValue(point: location),
                    "processIdentifier": NSNumber(value: processIdentifier)
                ]
            )
        }
    }

    private func scheduleSelectionPresentation(
        text: String,
        location: NSPoint,
        processIdentifier: pid_t
    ) {
        cancelPendingSelectionPresentation()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.cancelPendingSelectionPresentation()
            guard AccessibilityManager.isExpectedCopyFallbackProcess(
                expectedProcessIdentifier: processIdentifier,
                currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ), !AccessibilityManager.shared.shouldSuppressSelectionPresentation() else {
                return
            }
            self.postTextSelectedNotification(
                text: text,
                location: location,
                processIdentifier: processIdentifier
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
            NSLog("[OpenFire-Debug] Suppressing empty text input check for frontmost app: \(frontmostApp?.localizedName ?? frontmostApp?.bundleIdentifier ?? "unknown")")
            pendingEmptyInputCheckID = nil
            return
        }

        // Quick check: If pasteboard is empty, don't even bother checking accessibility
        guard Self.hasUsableClipboardText(NSPasteboard.general.string(forType: .string)) else {
            NSLog("[OpenFire-Debug] Pasteboard is empty, skipping empty text input check.")
            pendingEmptyInputCheckID = nil
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Only trigger if no text is actually selected, but we ARE in a text field
            let selectedText = AccessibilityManager.shared.getSelectedText()
            let isTextInput = AccessibilityManager.shared.isTextInputElement(at: mouseLocation)
            let selectedTextStatus = selectedText.map { "length=\($0.count)" } ?? "nil"
            
            NSLog("[OpenFire-Debug] checkForEmpty: selectedText=\(selectedTextStatus), isInput=\(isTextInput)")

            DispatchQueue.main.async {
                guard let self,
                      self.pendingEmptyInputCheckID == requestID else {
                    return
                }
                self.pendingEmptyInputCheckID = nil
                guard AccessibilityManager.isExpectedCopyFallbackProcess(
                    expectedProcessIdentifier: expectedProcessIdentifier,
                    currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
                ), selectedText == nil, isTextInput,
                      let expectedProcessIdentifier else {
                    return
                }

                NSLog("[OpenFire-Debug] Posting empty text input clicked notification!")
                NotificationCenter.default.post(
                    name: TextSelectionMonitor.emptyTextInputClickedNotification,
                    object: self,
                    userInfo: [
                        "mouseLocation": NSValue(point: mouseLocation),
                        "processIdentifier": NSNumber(value: expectedProcessIdentifier)
                    ]
                )
            }
        }
    }
}
