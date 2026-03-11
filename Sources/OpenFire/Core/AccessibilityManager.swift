import Cocoa
import ApplicationServices

/// Manages macOS Accessibility API integration for detecting text selection
final class AccessibilityManager {
    
    static let shared = AccessibilityManager()
    
    private let systemWideElement: AXUIElement
    
    var onPermissionLost: (() -> Void)?
    private var permissionWatchdog: Timer?
    
    private init() {
        systemWideElement = AXUIElementCreateSystemWide()
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
        
        guard let element = getFocusedElement() else { return nil }
        
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
    
    // Fallback: Simulate Cmd+C to grab text from apps that refuse to expose accessibility text
    func getSelectedTextViaCopy(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Give the user ~50ms to lift their fingers from the global hotkey
            // so physical modifiers (like Option/Control) don't turn Cmd+C into Option+Cmd+C
            usleep(50000) 
            
            let pasteboard = NSPasteboard.general
            
            // Save current pasteboard contents
            let oldString = pasteboard.string(forType: .string)
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
            if let old = oldString {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            } else {
                pasteboard.clearContents()
            }
            
            let trimmed = newString?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = (trimmed?.isEmpty == false) ? trimmed : nil
            
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    /// Check if the element at the specified screen coordinates is a text input field
    func isTextInputElement(at point: NSPoint) -> Bool {
        guard isAccessibilityEnabled else { return false }
        
        // NSEvent.mouseLocation uses bottom-left origin. AXUIElement uses top-left origin.
        // We need to convert the point relative to the primary screen.
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let primaryScreenFrame = screens[0].frame
        let axPoint = CGPoint(x: point.x, y: primaryScreenFrame.height - point.y)
        
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
            
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            
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
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let primaryScreenFrame = screens[0].frame
        let axPoint = CGPoint(x: point.x, y: primaryScreenFrame.height - point.y)
        
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
               let parent = parentRaw as! AXUIElement? {
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
        guard appResult == .success, let app = focusedApp else { return nil }
        
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            app as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard elementResult == .success, let element = focusedElement else { return nil }
        
        return (element as! AXUIElement)
    }
    
    /// Get the currently focused application's bundle identifier
    func getFocusedAppBundleID() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontApp.bundleIdentifier
    }
}
