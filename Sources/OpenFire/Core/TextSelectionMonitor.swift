import Cocoa

/// Monitors global mouse events to detect text selection
final class TextSelectionMonitor {
    
    static let shared = TextSelectionMonitor()
    
    /// Notification posted when text is selected. UserInfo contains "text" and "mouseLocation"
    static let textSelectedNotification = Notification.Name("OpenFireTextSelected")
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private var mouseDownLocation: NSPoint?
    private var clickCount: Int = 1
    
    // AXObserver state for robust text selection detection
    private var currentObserver: AXObserver?
    private var observerRunLoopSource: CFRunLoopSource?
    private var observedElement: AXUIElement?
    private var observationTimeout: DispatchWorkItem?
    
    // Polling fallback state for non-standard apps (e.g. Telegram, Electron apps)
    private var pendingSelectionTaskID: UUID?
    
    // Minimum drag distance (in points) to consider as text selection
    private let minimumDragDistance: CGFloat = 5.0
    
    private init() {}
    
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
                monitor.mouseDownLocation = NSEvent.mouseLocation
                monitor.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
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
        
        NSLog("[OpenFire] Text selection monitoring stopped")
    }
    
    // MARK: - Event Handling
    
    /// Notification posted when an empty text input is clicked
    static let emptyTextInputClickedNotification = Notification.Name("OpenFireEmptyTextInputClicked")
    
    private func handleMouseUp() {
        guard let downLocation = mouseDownLocation else { return }
        
        // Check blacklist
        if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            let excluded = UserDefaults.standard.stringArray(forKey: "ExcludedApps") ?? []
            if excluded.contains(bundleId) {
                mouseDownLocation = nil
                return
            }
        }
        
        // Prevent recursive spawning: If the Radial Menu is currently open, 
        // ignore all global text selection events so drag-clicks don't spawn a new menu.
        if NSApplication.shared.windows.contains(where: { $0 is RadialMenuWindow && $0.isVisible }) {
            mouseDownLocation = nil
            return
        }
        
        let upLocation = NSEvent.mouseLocation
        
        let dx = upLocation.x - downLocation.x
        let dy = upLocation.y - downLocation.y
        let distance = sqrt(dx * dx + dy * dy)
        
        mouseDownLocation = nil
        
        // Clean up any pending observers or active tasks
        cleanupPendingTask()
        
        let localClickCount = self.clickCount
        let isDrag = distance >= minimumDragDistance
        let isTextElement = AccessibilityManager.shared.isTextElement(at: downLocation)
        
        // If it was a meaningful drag, OR a double/triple click specifically on a text element
        if isDrag || (localClickCount >= 2 && isTextElement) {
            let taskID = UUID()
            self.pendingSelectionTaskID = taskID
            
            // Wait a tiny bit then do a hybrid check: Observer + Polling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                
                // Immediately check if text is already selected
                if let text = AccessibilityManager.shared.getSelectedText(), !text.isEmpty {
                    self.handleSelectionFound(text: text, location: upLocation, taskID: taskID)
                } else {
                    // Try to attach an observer
                    self.startObserver(at: upLocation, taskID: taskID)
                    
                    // Concurrently start polling (for apps that don't emit observer notifications)
                    self.schedulePolling(at: upLocation, taskID: taskID)
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
    
    private func startObserver(at mouseLocation: NSPoint, taskID: UUID) {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = focusedApp.processIdentifier
        
        var observerRaw: AXObserver?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        let error = AXObserverCreate(pid, { observer, element, notification, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<TextSelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleSelectionChangedNotification(element: element)
        }, &observerRaw)
        
        guard error == .success, let observer = observerRaw, let focusedElement = AccessibilityManager.shared.getFocusedElement() else { return }
        
        AXObserverAddNotification(observer, focusedElement, kAXSelectedTextChangedNotification as CFString, selfPointer)
        
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
            self.cleanupPendingTask()
        }
        self.observationTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }
    
    private func schedulePolling(at mouseLocation: NSPoint, taskID: UUID) {
        // Try native accessibility polling once at 0.1s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.pendingSelectionTaskID == taskID else { return }
            
            if let text = AccessibilityManager.shared.getSelectedText(), !text.isEmpty {
                NSLog("[OpenFire-Debug] Text found via Polling Fallback at 0.1s.")
                self.handleSelectionFound(text: text, location: mouseLocation, taskID: taskID)
            } else {
                // If native polling fails at 0.1s, immediately fire the Cmd+C fallback for Electron/Qt apps (e.g., Telegram)
                // This eliminates the previous 0.4s waiting penalty.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                    
                    AccessibilityManager.shared.getSelectedTextViaCopy { [weak self] copiedText in
                        guard let self = self, self.pendingSelectionTaskID == taskID else { return }
                        if let text = copiedText, !text.isEmpty {
                            NSLog("[OpenFire-Debug] Text found via Cmd+C Fallback after 0.15s.")
                            self.handleSelectionFound(text: text, location: mouseLocation, taskID: taskID)
                        } else {
                            self.cleanupPendingTask()
                        }
                    }
                }
            }
        }
    }
    
    private func handleSelectionChangedNotification(element: AXUIElement) {
        let taskID = self.pendingSelectionTaskID
        
        var selectedTextRaw: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRaw)
        
        if result == .success, let text = selectedTextRaw as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let location = NSEvent.mouseLocation
            handleSelectionFound(text: text.trimmingCharacters(in: .whitespacesAndNewlines), location: location, taskID: taskID)
        }
    }
    
    private func handleSelectionFound(text: String, location: NSPoint, taskID: UUID?) {
        // Stop all other tracking for this selection drop
        if let taskID = taskID, pendingSelectionTaskID != taskID { return } // Already handled
        
        cleanupPendingTask()
        
        postTextSelectedNotification(text: text, location: location)
    }
    
    private func cleanupPendingTask() {
        pendingSelectionTaskID = nil
        
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
    
    private func checkForEmptyTextInputClick(at mouseLocation: NSPoint) {
        // Quick check: If pasteboard is empty, don't even bother checking accessibility
        guard let pasteboardString = NSPasteboard.general.string(forType: .string), !pasteboardString.isEmpty else {
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
