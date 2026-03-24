import Cocoa

/// Monitors global mouse events to detect text selection
final class TextSelectionMonitor {
    struct FrontmostWindowSnapshot: Equatable {
        let ownerPID: pid_t
        let bounds: CGRect
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
        windowInfoList: [[String: Any]]? = nil
    ) -> FrontmostWindowSnapshot? {
        guard let frontmostApplication else { return nil }
        let windows = windowInfoList ?? ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostApplication.processIdentifier else {
                continue
            }

            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }

            guard bounds.width > 40, bounds.height > 40 else { continue }

            return FrontmostWindowSnapshot(ownerPID: ownerPID, bounds: bounds)
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
    private var mouseDownLocation: NSPoint?
    private var mouseDownDragPasteboardChangeCount: Int?
    private var mouseDownWindowSnapshot: FrontmostWindowSnapshot?
    private var mouseDownSelectionSnapshot: AccessibilityManager.SelectionSnapshot?
    private var mouseDownStartedInTextContext = false
    private var mouseDownInsideFocusedElementBounds = false
    private var pendingSelectionBaselineSnapshot: AccessibilityManager.SelectionSnapshot?
    private var pendingSelectionStartedInTextContext = false
    private var pendingSelectionEndedInTextContext = false
    private var pendingSelectionStartedInsideFocusedElementBounds = false
    private var pendingSelectionEndedInsideFocusedElementBounds = false
    
    // AXObserver state for robust text selection detection
    private var currentObserver: AXObserver?
    private var observerRunLoopSource: CFRunLoopSource?
    private var observedElement: AXUIElement?
    private var observationTimeout: DispatchWorkItem?
    
    // Polling fallback state for non-standard apps (e.g. Telegram, Electron apps)
    private var pendingSelectionTaskID: UUID?
    private var pendingPresentationWorkItem: DispatchWorkItem?
    private var presentationCancelMonitor: Any?
    private(set) var lastEmptyInputCheckLocation: NSPoint?
    
    // Minimum drag distance (in points) to consider as text selection
    private let minimumDragDistance: CGFloat = 5.0
    private let mouseSelectionPresentationDelay: TimeInterval = 0.16
    
    private init() {}

    private static func normalizeFrontmostAppIdentifier(_ value: String?) -> String {
        guard let value else { return "" }
        let lowered = value.lowercased()
        return lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    
    // MARK: - Start / Stop
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        guard AccessibilityManager.shared.isAccessibilityEnabled else {
            NSLog("[OpenFire] Cannot start monitoring: accessibility permission not granted")
            return
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
            
            if type == .leftMouseDown {
                let mouseLocation = NSEvent.mouseLocation
                monitor.mouseDownLocation = mouseLocation
                monitor.mouseDownDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
                monitor.mouseDownWindowSnapshot = TextSelectionMonitor.currentFrontmostWindowSnapshot()
                monitor.mouseDownSelectionSnapshot = AccessibilityManager.shared.currentSelectionSnapshot()
                monitor.mouseDownStartedInTextContext = TextSelectionMonitor.isTextSelectionContext(at: mouseLocation)
                monitor.mouseDownInsideFocusedElementBounds = AccessibilityManager.shared.isPointInsideFocusedElementBounds(at: mouseLocation)
            } else if type == .leftMouseUp {
                monitor.handleMouseUp()
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
            NSLog("[OpenFire] Failed to create event tap. Ensure accessibility permission is granted.")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        isMonitoring = true
        NSLog("[OpenFire] Text selection monitoring started")
    }
    
    func stopMonitoring() {
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
        mouseDownLocation = nil
        mouseDownDragPasteboardChangeCount = nil
        mouseDownWindowSnapshot = nil
        mouseDownSelectionSnapshot = nil
        mouseDownStartedInTextContext = false
        mouseDownInsideFocusedElementBounds = false
        pendingSelectionBaselineSnapshot = nil
        pendingSelectionStartedInTextContext = false
        pendingSelectionEndedInTextContext = false
        pendingSelectionStartedInsideFocusedElementBounds = false
        pendingSelectionEndedInsideFocusedElementBounds = false
        
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

    static func shouldHandleCopiedDragSelection(
        copiedText: String?,
        snapshotAtMouseDown: AccessibilityManager.SelectionSnapshot?,
        currentSnapshot: AccessibilityManager.SelectionSnapshot?,
        frontmostBundleID: String?,
        startedInTextContext: Bool,
        endedInTextContext: Bool,
        startedInsideFocusedElementBounds: Bool,
        endedInsideFocusedElementBounds: Bool
    ) -> Bool {
        guard let copiedText else { return false }
        let trimmed = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hasTextContext = startedInTextContext || endedInTextContext
        let hasFocusedBoundsContext =
            AccessibilityManager.isLikelyRichTextSelectionHost(bundleID: frontmostBundleID) &&
            (startedInsideFocusedElementBounds || endedInsideFocusedElementBounds)
        let hasTelegramBlindFallback = frontmostBundleID?.lowercased().contains("telegram") == true
        let hasSelectionSignal =
            (snapshotAtMouseDown?.isReadable == true || currentSnapshot?.isReadable == true) &&
            AccessibilityManager.didSelectionChange(from: snapshotAtMouseDown, to: currentSnapshot)
        guard hasTextContext || hasSelectionSignal || hasFocusedBoundsContext || hasTelegramBlindFallback else { return false }
        if let snapshotAtMouseDown, snapshotAtMouseDown.canReadSelectedTextViaAccessibility {
            if let currentSnapshot, currentSnapshot.canReadSelectedTextViaAccessibility {
                return snapshotAtMouseDown.normalizedText != trimmed
            }

            return hasSelectionSignal || hasFocusedBoundsContext || hasTelegramBlindFallback
        }

        return true
    }
    
    private func handleMouseUp() {
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
            mouseDownLocation = nil
            mouseDownDragPasteboardChangeCount = nil
            mouseDownWindowSnapshot = nil
            mouseDownSelectionSnapshot = nil
            mouseDownStartedInTextContext = false
            mouseDownInsideFocusedElementBounds = false
            return
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if Self.shouldSuppressForFrontmostApp(
            bundleID: frontmostApp?.bundleIdentifier,
            localizedName: frontmostApp?.localizedName,
            isFocusedSelectionEditable: AccessibilityManager.shared.isFocusedSelectionEditable()
        ) {
            mouseDownLocation = nil
            mouseDownDragPasteboardChangeCount = nil
            mouseDownWindowSnapshot = nil
            mouseDownSelectionSnapshot = nil
            mouseDownStartedInTextContext = false
            mouseDownInsideFocusedElementBounds = false
            return
        }
        
        // Check blacklist
        if let bundleId = frontmostApp?.bundleIdentifier {
            let excluded = UserDefaults.standard.stringArray(forKey: "ExcludedApps") ?? []
            if excluded.contains(bundleId) {
                mouseDownLocation = nil
                mouseDownDragPasteboardChangeCount = nil
                mouseDownWindowSnapshot = nil
                mouseDownSelectionSnapshot = nil
                mouseDownStartedInTextContext = false
                mouseDownInsideFocusedElementBounds = false
                return
            }
        }
        
        // Prevent recursive spawning: If the Radial Menu is currently open, 
        // ignore all global text selection events so drag-clicks don't spawn a new menu.
        if NSApplication.shared.windows.contains(where: { $0 is RadialMenuWindow && $0.isVisible }) {
            mouseDownLocation = nil
            mouseDownDragPasteboardChangeCount = nil
            mouseDownWindowSnapshot = nil
            mouseDownSelectionSnapshot = nil
            mouseDownStartedInTextContext = false
            mouseDownInsideFocusedElementBounds = false
            return
        }

        if Self.didFrontmostWindowMove(
            from: windowSnapshotAtMouseDown,
            to: Self.currentFrontmostWindowSnapshot(frontmostApplication: frontmostApp)
        ) {
            mouseDownLocation = nil
            mouseDownDragPasteboardChangeCount = nil
            mouseDownWindowSnapshot = nil
            mouseDownSelectionSnapshot = nil
            mouseDownStartedInTextContext = false
            mouseDownInsideFocusedElementBounds = false
            return
        }
        
        let upLocation = NSEvent.mouseLocation
        let startedInTextContext = mouseDownStartedInTextContext
        let endedInTextContext = Self.isTextSelectionContext(at: upLocation)
        let startedInsideFocusedElementBounds = mouseDownInsideFocusedElementBounds
        let endedInsideFocusedElementBounds = AccessibilityManager.shared.isPointInsideFocusedElementBounds(at: upLocation)
        
        let dx = upLocation.x - downLocation.x
        let dy = upLocation.y - downLocation.y
        let distance = sqrt(dx * dx + dy * dy)
        let snapshotAtMouseDown = mouseDownSelectionSnapshot
        
        mouseDownLocation = nil
        mouseDownDragPasteboardChangeCount = nil
        mouseDownWindowSnapshot = nil
        mouseDownSelectionSnapshot = nil
        mouseDownStartedInTextContext = false
        mouseDownInsideFocusedElementBounds = false
        
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
            
            // Wait a tiny bit then do a hybrid check: Observer + Polling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                guard !AccessibilityManager.shared.shouldSuppressSelectionPresentation() else {
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
            // We still need a tiny delay here for the system to focus the new element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.checkForEmptyTextInputClick(at: upLocation)
            }
        }
    }
    
    // MARK: - Hybrid Detection Logic
    
    private func startObserver(taskID: UUID) -> Bool {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
            return false
        }
        let pid = focusedApp.processIdentifier
        
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
            NSLog("[OpenFire-Debug] AXObserver timeout: No text selection detected within 0.4s.")
            AccessibilityManager.shared.recordSelectionAttemptFailure(.observerTimedOut)
            self.cleanupPendingTask()
        }
        self.observationTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
        return true
    }
    
    private func schedulePolling(
        at mouseLocation: NSPoint,
        taskID: UUID,
        allowCopyFallback: Bool,
        observerStarted: Bool
    ) {
        // Try native accessibility polling once at 0.1s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.pendingSelectionTaskID == taskID else { return }

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
                // If native polling fails at 0.1s, immediately fire the Cmd+C fallback for Electron/Qt apps (e.g., Telegram)
                // This eliminates the previous 0.4s waiting penalty.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                    
                    AccessibilityManager.shared.getSelectedTextViaCopy { [weak self] copiedText in
                        guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                        let copiedTextAllowed = Self.shouldHandleCopiedDragSelection(
                            copiedText: copiedText,
                            snapshotAtMouseDown: self.pendingSelectionBaselineSnapshot,
                            currentSnapshot: AccessibilityManager.shared.currentSelectionSnapshot(),
                            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                            startedInTextContext: self.pendingSelectionStartedInTextContext,
                            endedInTextContext: self.pendingSelectionEndedInTextContext,
                            startedInsideFocusedElementBounds: self.pendingSelectionStartedInsideFocusedElementBounds,
                            endedInsideFocusedElementBounds: self.pendingSelectionEndedInsideFocusedElementBounds
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

        guard !AccessibilityManager.shared.shouldSuppressSelectionPresentation() else {
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
        
        cleanupPendingTask()

        scheduleSelectionPresentation(text: text, location: location)
    }
    
    private func cleanupPendingTask() {
        pendingSelectionTaskID = nil
        pendingSelectionBaselineSnapshot = nil
        pendingSelectionStartedInTextContext = false
        pendingSelectionEndedInTextContext = false
        pendingSelectionStartedInsideFocusedElementBounds = false
        pendingSelectionEndedInsideFocusedElementBounds = false
        
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
    
    private func postTextSelectedNotification(text: String, location: NSPoint) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: TextSelectionMonitor.textSelectedNotification,
                object: self,
                userInfo: ["text": text, "mouseLocation": NSValue(point: location)]
            )
        }
    }

    private func scheduleSelectionPresentation(text: String, location: NSPoint) {
        cancelPendingSelectionPresentation()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.cancelPendingSelectionPresentation()
            self.postTextSelectedNotification(text: text, location: location)
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
    
    private func checkForEmptyTextInputClick(at mouseLocation: NSPoint) {
        lastEmptyInputCheckLocation = mouseLocation

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if Self.shouldSuppressForFrontmostApp(
            bundleID: frontmostApp?.bundleIdentifier,
            localizedName: frontmostApp?.localizedName
        ) {
            NSLog("[OpenFire-Debug] Suppressing empty text input check for frontmost app: \(frontmostApp?.localizedName ?? frontmostApp?.bundleIdentifier ?? "unknown")")
            return
        }

        // Quick check: If pasteboard is empty, don't even bother checking accessibility
        guard Self.hasUsableClipboardText(NSPasteboard.general.string(forType: .string)) else {
            NSLog("[OpenFire-Debug] Pasteboard is empty, skipping empty text input check.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Only trigger if no text is actually selected, but we ARE in a text field
            let selectedText = AccessibilityManager.shared.getSelectedText()
            let isTextInput = AccessibilityManager.shared.isTextInputElement(at: mouseLocation)
            
            NSLog("[OpenFire-Debug] checkForEmpty: text='\(selectedText ?? "nil")', isInput=\(isTextInput)")
            
            if selectedText == nil {
                if isTextInput {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        NSLog("[OpenFire-Debug] Posting empty text input clicked notification!")
                        NotificationCenter.default.post(
                            name: TextSelectionMonitor.emptyTextInputClickedNotification,
                            object: self,
                            userInfo: ["mouseLocation": NSValue(point: mouseLocation)]
                        )
                    }
                }
            }
        }
    }
}
