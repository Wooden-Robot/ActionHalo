import Cocoa
import ApplicationServices
import Carbon

/// Manages macOS Accessibility API integration for detecting text selection
final class AccessibilityManager {
    private static let protectedTextSubroles: Set<String> = [
        "AXSecureTextField",
        "AXSecureTextArea"
    ]

    private static let protectedTextBooleanAttributes: [CFString] = [
        "AXValueProtected" as CFString,
        "AXProtectedContent" as CFString,
        "AXSecure" as CFString
    ]
    
    static let shared = AccessibilityManager()
    
    private let systemWideElement: AXUIElement

    enum SelectionAcquisitionSource {
        case accessibility
        case copyFallback

        var localizationKey: String {
            switch self {
            case .accessibility:
                return "Accessibility API"
            case .copyFallback:
                return "Cmd+C Fallback"
            }
        }
    }

    struct SelectionAcquisitionStatus {
        let source: SelectionAcquisitionSource
        let timestamp: Date
        let textLength: Int
    }

    enum SelectionAttemptFailure {
        case accessibilityEmptySelection
        case copyFallbackEmptySelection
        case observerSetupFailed
        case observerTimedOut
        case noFocusedApplication
    }

    struct SelectionAttemptStatus {
        let timestamp: Date
        let failure: SelectionAttemptFailure
    }

    var onPermissionLost: (() -> Void)?
    private var permissionWatchdog: Timer?
    private(set) var lastSelectionAcquisitionStatus: SelectionAcquisitionStatus?
    private(set) var lastSelectionAttemptStatus: SelectionAttemptStatus?
    
    private init() {
        systemWideElement = AXUIElementCreateSystemWide()
    }

    /// Convert a global AppKit mouse location into the top-left AX coordinate space
    /// for the specific display containing that point.
    func accessibilityScreenPoint(for point: NSPoint) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else {
            return nil
        }

        let frame = screen.frame
        return CGPoint(x: point.x, y: frame.maxY - point.y)
    }
    
    func startWatchdog() {
        permissionWatchdog?.invalidate()
        // Only run watchdog if we CURRENTLY have permission.
        guard isAccessibilityEnabled else { return }
        
        permissionWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isAccessibilityEnabled {
                self.stopWatchdog()
                DispatchQueue.main.async {
                    self.onPermissionLost?()
                }
            }
        }
    }
    
    func stopWatchdog() {
        permissionWatchdog?.invalidate()
        permissionWatchdog = nil
    }
    
    // MARK: - Permission Management
    
    /// Check if accessibility permission is granted silently
    var isAccessibilityEnabled: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Prompt user to grant accessibility permission
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    /// Check and prompt for accessibility permission if not granted
    func ensureAccessibilityPermission() -> Bool {
        if isAccessibilityEnabled {
            return true
        }
        requestAccessibilityPermission()
        return false
    }
    
    // MARK: - Text Selection
    
    func getSelectedText() -> String? {
        guard isAccessibilityEnabled else { return nil }
        guard !isSecureEventInputEnabled() else { return nil }
        
        guard let element = getFocusedElement() else { return nil }
        guard !Self.isProtectedTextElement(element) else { return nil }
        
        // Get the selected text from the focused element
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        guard textResult == .success, let text = selectedText as? String else { return nil }
        
        // Return nil for empty strings
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func isFocusedSelectionEditable() -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let focusedElement = getFocusedElement() else { return false }

        var isSettable: DarwinBoolean = false
        let isValueSettable =
            AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == .success &&
            isSettable.boolValue
        let isSelectedTextSettable =
            AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &isSettable) == .success &&
            isSettable.boolValue

        if isValueSettable || isSelectedTextSettable {
            return true
        }

        var isEditing: AnyObject?
        if AXUIElementCopyAttributeValue(focusedElement, "AXDocumentIsEditing" as CFString, &isEditing) == .success,
           let editing = isEditing as? Bool {
            return editing
        }

        return false
    }
    
    // Fallback: Simulate Cmd+C to grab text from apps that refuse to expose accessibility text
    func getSelectedTextViaCopy(completion: @escaping (String?) -> Void) {
        guard !shouldSuppressSelectionPresentation() else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Give the user ~50ms to lift their fingers from the global hotkey
            // so physical modifiers (like Option/Control) don't turn Cmd+C into Option+Cmd+C
            usleep(50000) 
            
            let pasteboard = NSPasteboard.general
            let snapshot = Self.capturePasteboardSnapshot(from: pasteboard)
            
            pasteboard.clearContents()
            
            // Simulate Cmd+C via CGEvent
            let source = CGEventSource(stateID: .hidSystemState)
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(8), keyDown: true)
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(8), keyDown: false)
            
            cmdDown?.flags = .maskCommand
            cmdUp?.flags = .maskCommand
            
            cmdDown?.post(tap: .cghidEventTap)
            usleep(10000) // 10ms gap between down and up
            cmdUp?.post(tap: .cghidEventTap)
            
            // Wait for Electron/React apps to detect the event, process the DOM, and write to PB
            usleep(50000)
            
            // Read new content
            let newString = pasteboard.string(forType: .string)
            
            // Restore old content so we don't unexpectedly blow away the user's clipboard
            Self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            
            let trimmed = newString?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = (trimmed?.isEmpty == false) ? trimmed : nil
            
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func recordSelectionAcquisition(source: SelectionAcquisitionSource, text: String) {
        lastSelectionAcquisitionStatus = SelectionAcquisitionStatus(
            source: source,
            timestamp: Date(),
            textLength: text.count
        )
        lastSelectionAttemptStatus = nil
    }

    func recordSelectionAttemptFailure(_ failure: SelectionAttemptFailure) {
        lastSelectionAttemptStatus = SelectionAttemptStatus(
            timestamp: Date(),
            failure: failure
        )
    }

    func isFocusedElementProtected() -> Bool {
        guard isAccessibilityEnabled else { return false }
        guard let focusedElement = getFocusedElement() else { return false }
        return Self.isProtectedTextElement(focusedElement)
    }

    func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    func shouldSuppressSelectionPresentation() -> Bool {
        isSecureEventInputEnabled() || isFocusedElementProtected()
    }

    private static func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
    }
    
    private static func restorePasteboardSnapshot(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        
        guard !snapshot.isEmpty else { return }
        
        let restoredItems = snapshot.map { itemSnapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
        
        pasteboard.writeObjects(restoredItems)
    }
    
    /// Check if the element at the specified screen coordinates is a text input field
    func isTextInputElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }

        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        
        // 1. Get the globally focused element instead of hit-testing.
        // Hit-testing often returns low-level items like AXGroup or AXStaticText which breaks the logic.
        guard let focusedElement = getFocusedElement() else { return false }
        
        // 2. Verify the role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else { return false }
        
        // 3. Verify it's a text input
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea", "AXGroup", "AXDocument", "AXSearchField"]
        let forbiddenRoles = [
            kAXCheckBoxRole,
            kAXRadioButtonRole,
            kAXButtonRole,
            kAXPopUpButtonRole,
            kAXMenuButtonRole,
            kAXSliderRole,
            kAXValueIndicatorRole,
            kAXColorWellRole,
            kAXListRole,
            kAXOutlineRole,
            kAXTableRole
        ]
        
        if forbiddenRoles.contains(role) {
            NSLog("[OpenFire-Debug] Focused element is forbidden (role: \(role)), refusing to treat as text input.")
            return false
        }
        
        var isEditableText = false
        
        var isSettable: DarwinBoolean = false
        let isValueSettable = AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == .success && isSettable.boolValue
        let isSelectedTextSettable = AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &isSettable) == .success && isSettable.boolValue
        
        if isValueSettable || isSelectedTextSettable {
            isEditableText = true
        } else if textRoles.contains(role) {
            // Some specific rich text editors don't flag attributes as settable but are actively editing
            var isEditing: AnyObject?
            if AXUIElementCopyAttributeValue(focusedElement, "AXDocumentIsEditing" as CFString, &isEditing) == .success,
               let editing = isEditing as? Bool, editing {
                isEditableText = true
            }
        }
        
        guard isEditableText else {
            NSLog("[OpenFire-Debug] Focused element is NOT an editable text input (role: \(role)).")
            return false
        }
        
        // 4. Verify the click fell INSIDE the element's bounds to avoid false positives when clicking out
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        
        if AXUIElementCopyAttributeValue(focusedElement, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(focusedElement, kAXSizeAttribute as CFString, &sizeValue) == .success {
            
            var position = CGPoint.zero
            var size = CGSize.zero

            guard
                let positionValue,
                let sizeValue,
                CFGetTypeID(positionValue) == AXValueGetTypeID(),
                CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else {
                NSLog("[OpenFire-Debug] Failed to decode AX position/size for focused text input.")
                return false
            }

            let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
            let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)

            guard
                AXValueGetValue(positionAXValue, .cgPoint, &position),
                AXValueGetValue(sizeAXValue, .cgSize, &size)
            else {
                NSLog("[OpenFire-Debug] Failed to decode AX position/size for focused text input.")
                return false
            }
            
            let elementRect = CGRect(origin: position, size: size)
            let contains = elementRect.contains(axPoint)
            
            NSLog("[OpenFire-Debug] Element bounds: \(elementRect), Click point: \(axPoint), Contains: \(contains)")
            return contains
        }
        
        // Fallback: If we couldn't get bounding boxes but we know it's a focused text input, 
        // return true as a best-effort.
        NSLog("[OpenFire-Debug] Could not get element bounds. Assuming true.")
        return true
    }
    
    /// Check if the element at the specified screen coordinates is purely text (like a webpage paragraph, a text field, or static text label),
    /// specifically excluding structural elements like Finder rows, cells, or images that get double-clicked.
    func isTextElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }

        // 1. Get the globally focused element or the element exactly under the mouse
        // We use systemWideElement to hit-test the specific point on screen
        guard let axPoint = accessibilityScreenPoint(for: point) else { return false }
        
        var hitElementRaw: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(systemWideElement, Float(axPoint.x), Float(axPoint.y), &hitElementRaw)
        
        guard hitResult == .success, let hitElement = hitElementRaw else { return false }
        
        // Hard-block file managers and desktop to prevent file clicking from triggering text selection
        if let bundleID = getFocusedAppBundleID() {
            if bundleID == "com.apple.finder" || bundleID == "com.apple.WindowManager" {
                NSLog("[OpenFire-Debug] Ignoring double click because frontmost app is Finder/Desktop")
                return false
            }
        }
        
        // 2. Identify the role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(hitElement, kAXRoleAttribute as CFString, &roleValue)
        guard roleResult == .success, let role = roleValue as? String else { return false }
        
        // Allowed roles that represent actual selectable text content
        let allowedRoles = [
            kAXStaticTextRole,
            kAXTextFieldRole,
            kAXTextAreaRole,
            "AXWebArea",
            "AXHeading",
            "AXParagraph",
            "AXLink"
        ]
        
        // Strictly forbidden roles (Finder files, Desktop icons, buttons, table cells)
        let forbiddenRoles = [
            kAXImageRole,
            kAXCellRole,
            kAXRowRole,
            kAXButtonRole,
            kAXWindowRole,
            kAXApplicationRole
        ]
        
        NSLog("[OpenFire-Debug] Double-click hit test detected role: \(role)")
        
        if forbiddenRoles.contains(role) {
            return false
        }
        
        if allowedRoles.contains(role) {
            // Even if it's "StaticText", check if it's literally just a label inside a button or a row (common in native macOS apps)
            var parentRaw: AnyObject?
            if AXUIElementCopyAttributeValue(hitElement, kAXParentAttribute as CFString, &parentRaw) == .success,
               let parentRaw,
               CFGetTypeID(parentRaw) == AXUIElementGetTypeID() {
                let parent = unsafeBitCast(parentRaw, to: AXUIElement.self)
                var parentRoleRaw: AnyObject?
                if AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &parentRoleRaw) == .success,
                   let parentRole = parentRoleRaw as? String {
                    if forbiddenRoles.contains(parentRole) || parentRole == kAXListRole || parentRole == kAXOutlineRole || parentRole == kAXTableRole {
                        NSLog("[OpenFire-Debug] Blocking allowed role \(role) because its parent is \(parentRole)")
                        return false
                    }
                }
            }
            return true
        }
        
        // If it's an unknown group, we default to false to be safe and avoid misfires,
        // EXCEPT if it's Electron/Chromium (which often wrap text in generic AXGroups).
        // Let's explicitly check the app ID.
        if role == "AXGroup" {
            if let bundleID = getFocusedAppBundleID() {
                // Electron apps (VSCode, Telegram, Obsidian, Discord) and Chromium use massive AXGroups
                let electronHeuristics = ["electron", "desktop", "telegram", "discord", "obsidian", "code", "chrome", "edge", "brave"]
                let lowerID = bundleID.lowercased()
                if electronHeuristics.contains(where: lowerID.contains) {
                    return true
                }
            }
        }
        
        return false
    }
    
    func getFocusedElement() -> AXUIElement? {
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        guard
            appResult == .success,
            let focusedApp,
            CFGetTypeID(focusedApp) == AXUIElementGetTypeID()
        else { return nil }
        let app = unsafeBitCast(focusedApp, to: AXUIElement.self)
        
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard
            elementResult == .success,
            let focusedElement,
            CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else { return nil }
        
        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    private static func isProtectedTextElement(_ element: AXUIElement) -> Bool {
        var subroleValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String,
           protectedTextSubroles.contains(subrole) {
            return true
        }

        for attribute in protectedTextBooleanAttributes {
            var attributeValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute, &attributeValue) == .success,
               let isProtected = attributeValue as? Bool,
               isProtected {
                return true
            }
        }

        return false
    }

    static func isProtectedTextElementDescriptor(subrole: String?, flags: [String: Bool]) -> Bool {
        if let subrole, protectedTextSubroles.contains(subrole) {
            return true
        }

        return protectedTextBooleanAttributes.contains { attribute in
            flags[attribute as String] == true
        }
    }

    static func shouldSuppressSelectionPresentation(
        isProtectedElement: Bool,
        secureEventInputEnabled: Bool
    ) -> Bool {
        secureEventInputEnabled || isProtectedElement
    }

    func focusedElementRoleDescription() -> String? {
        guard let element = getFocusedElement() else { return nil }

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard roleResult == .success, let role = roleValue as? String else { return nil }

        var subroleValue: AnyObject?
        let subroleResult = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )

        if subroleResult == .success, let subrole = subroleValue as? String, !subrole.isEmpty {
            return "\(role) / \(subrole)"
        }

        return role
    }
    
    /// Get the currently focused application's bundle identifier
    func getFocusedAppBundleID() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontApp.bundleIdentifier
    }
}
