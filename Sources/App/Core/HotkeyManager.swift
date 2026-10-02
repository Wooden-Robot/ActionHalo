import Cocoa
import Carbon

/// Manages the two global hotkeys:
/// 1) open the radial menu for the current selection
/// 2) toggle automatic text-selection triggering on/off
@MainActor
final class HotkeyManager {
    nonisolated private static let maximumVirtualKeyCode: UInt32 = 0x7E
    nonisolated private static let supportedModifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    private enum Defaults {
        static let menuHotkeyConfiguredKey = "hotkeyConfigured"
        static let toggleHotkeyConfiguredKey = "toggleHotkeyConfigured"
        static let defaultMenuHotkey: (keyCode: UInt32, modifiers: UInt32) = (0x02, UInt32(shiftKey | optionKey)) // ⇧⌥D
        static let defaultToggleHotkey: (keyCode: UInt32, modifiers: UInt32) = (0x07, UInt32(shiftKey | optionKey)) // ⇧⌥X
    }

    struct RegistrationIssue: Equatable {
        let kind: Kind
        let message: String

        enum Kind: Equatable {
            case duplicateAssignment
            case invalidModifiers
            case registerFailed(OSStatus)
        }
    }
    
    static let shared = HotkeyManager()
    static let hotkeyChangedNotification = Notification.Name("ActionHaloHotkeyChanged")
    static let toggleHotkeyChangedNotification = Notification.Name("ActionHaloToggleHotkeyChanged")
    
    /// Current hotkey stored as (keyCode, modifiers) for manually opening the radial menu
    var hotkey: (keyCode: UInt32, modifiers: UInt32)? {
        didSet {
            saveHotkey()
            NotificationCenter.default.post(name: Self.hotkeyChangedNotification, object: self)
        }
    }
    
    /// Current hotkey stored as (keyCode, modifiers) for toggling automatic text-selection triggering
    var toggleHotkey: (keyCode: UInt32, modifiers: UInt32)? {
        didSet {
            saveToggleHotkey()
            NotificationCenter.default.post(name: Self.toggleHotkeyChangedNotification, object: self)
        }
    }
    
    /// Human-readable description
    var hotkeyDescription: String {
        description(for: hotkey)
    }
    
    /// Human-readable description for toggle hotkey
    var toggleHotkeyDescription: String {
        description(for: toggleHotkey)
    }

    private func description(for hotkey: (keyCode: UInt32, modifiers: UInt32)?) -> String {
        guard let hk = hotkey else { return "Not Set".localized }
        var parts: [String] = []
        if hk.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if hk.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hk.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hk.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        parts.append(keyStringFromCode(UInt16(hk.keyCode)))
        return parts.joined()
    }
    
    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    var onHotkeyPressed: (() -> Void)?
    
    private var toggleHotkeyRef: EventHotKeyRef?
    var onToggleHotkeyPressed: (() -> Void)?
    
    private init() {
        loadHotkey()
    }

    nonisolated static func hasRequiredGlobalHotkeyModifier(_ modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    nonisolated static func validatedStoredHotkey(
        keyCode: Int?,
        modifiers: Int?
    ) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let keyCode,
              let modifiers,
              keyCode >= 0,
              keyCode <= Int(maximumVirtualKeyCode),
              modifiers >= 0,
              modifiers <= Int(UInt32.max) else {
            return nil
        }

        let validatedModifiers = UInt32(modifiers)
        guard validatedModifiers & ~supportedModifierMask == 0,
              hasRequiredGlobalHotkeyModifier(validatedModifiers) else {
            return nil
        }
        return (UInt32(keyCode), validatedModifiers)
    }

    nonisolated private static func validatedHotkey(
        _ hotkey: (keyCode: UInt32, modifiers: UInt32)?
    ) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let hotkey,
              hotkey.keyCode <= maximumVirtualKeyCode,
              hotkey.modifiers & ~supportedModifierMask == 0,
              hasRequiredGlobalHotkeyModifier(hotkey.modifiers) else {
            return nil
        }
        return hotkey
    }

    /// Keep the working binding and preferences until the replacement is registered.
    @discardableResult
    func updateHotkey(
        _ candidate: (keyCode: UInt32, modifiers: UInt32)?,
        isToggle: Bool = false
    ) -> [RegistrationIssue] {
        if candidate != nil, Self.validatedHotkey(candidate) == nil {
            return [RegistrationIssue(
                kind: .invalidModifiers,
                message: isToggle
                    ? "Auto Trigger Toggle Hotkey must include Command, Option, or Control.".localized
                    : "Open Menu Hotkey must include Command, Option, or Control.".localized
            )]
        }
        let otherHotkey = isToggle ? hotkey : toggleHotkey
        if let candidate, let otherHotkey, candidate == otherHotkey {
            return [RegistrationIssue(
                kind: .duplicateAssignment,
                message: "Open Menu Hotkey and Auto Trigger Toggle Hotkey cannot use the same shortcut.".localized
            )]
        }

        let previousHotkey = isToggle ? toggleHotkey : hotkey
        let previousRef = isToggle ? toggleHotkeyRef : hotkeyRef
        if let candidate, let previousHotkey,
           candidate == previousHotkey, previousRef != nil {
            return []
        }

        var replacementRef: EventHotKeyRef?
        if let candidate {
            var status = installEventHandlerIfNeeded()
            if status == noErr {
                let identifier = EventHotKeyID(signature: fourCharCode("OFIR"), id: isToggle ? 2 : 1)
                status = RegisterEventHotKey(
                    candidate.keyCode, candidate.modifiers, identifier,
                    GetApplicationEventTarget(), 0, &replacementRef
                )
            }
            guard status == noErr else {
                if hotkeyRef == nil, toggleHotkeyRef == nil { unregisterHotkeys() }
                let message = isToggle
                    ? "Failed to register Auto Trigger Toggle Hotkey (%@). It may conflict with another shortcut.".localized
                    : "Failed to register Open Menu Hotkey (%@). It may conflict with another shortcut.".localized
                return [RegistrationIssue(
                    kind: .registerFailed(status),
                    message: String(format: message, description(for: candidate))
                )]
            }
        }

        if let previousRef { UnregisterEventHotKey(previousRef) }
        if isToggle {
            toggleHotkeyRef = replacementRef
            toggleHotkey = candidate
        } else {
            hotkeyRef = replacementRef
            hotkey = candidate
        }
        if hotkeyRef == nil, toggleHotkeyRef == nil { unregisterHotkeys() }
        return []
    }
    
    /// Register all global hotkeys
    @discardableResult
    func registerHotkeys() -> [RegistrationIssue] {
        var issues: [RegistrationIssue] = []

        let menuHotkey = Self.validatedHotkey(hotkey)
        let autoTriggerHotkey = Self.validatedHotkey(toggleHotkey)

        if hotkey != nil, menuHotkey == nil {
            issues.append(
                RegistrationIssue(
                    kind: .invalidModifiers,
                    message: "Open Menu Hotkey must include Command, Option, or Control.".localized
                )
            )
        }
        if toggleHotkey != nil, autoTriggerHotkey == nil {
            issues.append(
                RegistrationIssue(
                    kind: .invalidModifiers,
                    message: "Auto Trigger Toggle Hotkey must include Command, Option, or Control.".localized
                )
            )
        }

        if let hk = menuHotkey, let thk = autoTriggerHotkey, hk == thk {
            let issue = RegistrationIssue(
                kind: .duplicateAssignment,
                message: "Open Menu Hotkey and Auto Trigger Toggle Hotkey cannot use the same shortcut.".localized
            )
            issues.append(issue)
            NSLog("[ActionHalo] Hotkey registration skipped: duplicate assignment")
            return issues
        }

        unregisterHotkeys()
        guard menuHotkey != nil || autoTriggerHotkey != nil else { return issues }
        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            issues.append(RegistrationIssue(
                kind: .registerFailed(handlerStatus),
                message: String(format: "Failed to register Open Menu Hotkey (%@). It may conflict with another shortcut.".localized, hotkeyDescription)
            ))
            return issues
        }
        
        if let hk = menuHotkey {
            let hotkeyID = EventHotKeyID(signature: fourCharCode("OFIR"), id: 1)
            let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, hotkeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
            if status == noErr {
                NSLog("[ActionHalo] Radial Menu Hotkey registered: \(hotkeyDescription)")
            } else {
                issues.append(
                    RegistrationIssue(
                        kind: .registerFailed(status),
                        message: String(format: "Failed to register Open Menu Hotkey (%@). It may conflict with another shortcut.".localized, hotkeyDescription)
                    )
                )
                hotkeyRef = nil
            }
        }
        
        if let thk = autoTriggerHotkey {
            let toggleHotkeyID = EventHotKeyID(signature: fourCharCode("OFIR"), id: 2)
            let status = RegisterEventHotKey(thk.keyCode, thk.modifiers, toggleHotkeyID, GetApplicationEventTarget(), 0, &toggleHotkeyRef)
            if status == noErr {
                NSLog("[ActionHalo] Auto-trigger toggle hotkey registered: \(toggleHotkeyDescription)")
            } else {
                issues.append(
                    RegistrationIssue(
                        kind: .registerFailed(status),
                        message: String(format: "Failed to register Auto Trigger Toggle Hotkey (%@). It may conflict with another shortcut.".localized, toggleHotkeyDescription)
                    )
                )
                toggleHotkeyRef = nil
            }
        }

        return issues
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )

            if status == noErr {
                let identifier = hotkeyID.id
                DispatchQueue.main.async {
                    if identifier == 1 {
                        HotkeyManager.shared.onHotkeyPressed?()
                    } else if identifier == 2 {
                        HotkeyManager.shared.onToggleHotkeyPressed?()
                    }
                }
            }
            return noErr
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
    }
    
    /// Unregister all global hotkeys
    func unregisterHotkeys() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = toggleHotkeyRef {
            UnregisterEventHotKey(ref)
            toggleHotkeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
    
    // MARK: - Persistence
    
    private func saveHotkey() {
        UserDefaults.standard.set(true, forKey: Defaults.menuHotkeyConfiguredKey)
        if let hk = hotkey {
            UserDefaults.standard.set(Int(hk.keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(hk.modifiers), forKey: "hotkeyModifiers")
        } else {
            UserDefaults.standard.removeObject(forKey: "hotkeyKeyCode")
            UserDefaults.standard.removeObject(forKey: "hotkeyModifiers")
        }
    }
    
    private func saveToggleHotkey() {
        UserDefaults.standard.set(true, forKey: Defaults.toggleHotkeyConfiguredKey)
        if let hk = toggleHotkey {
            UserDefaults.standard.set(Int(hk.keyCode), forKey: "toggleHotkeyKeyCode")
            UserDefaults.standard.set(Int(hk.modifiers), forKey: "toggleHotkeyModifiers")
        } else {
            UserDefaults.standard.removeObject(forKey: "toggleHotkeyKeyCode")
            UserDefaults.standard.removeObject(forKey: "toggleHotkeyModifiers")
        }
    }
    
    private func loadHotkey() {
        let menuHotkeyConfigured = UserDefaults.standard.object(forKey: Defaults.menuHotkeyConfiguredKey) as? Bool ?? false
        let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int
        let modifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int
        if let storedHotkey = Self.validatedStoredHotkey(keyCode: keyCode, modifiers: modifiers) {
            hotkey = storedHotkey
        } else if keyCode != nil || modifiers != nil {
            UserDefaults.standard.removeObject(forKey: "hotkeyKeyCode")
            UserDefaults.standard.removeObject(forKey: "hotkeyModifiers")
            UserDefaults.standard.set(true, forKey: Defaults.menuHotkeyConfiguredKey)
        } else if !menuHotkeyConfigured {
            hotkey = Defaults.defaultMenuHotkey
        }
        
        let toggleHotkeyConfigured = UserDefaults.standard.object(forKey: Defaults.toggleHotkeyConfiguredKey) as? Bool ?? false
        let tKeyCode = UserDefaults.standard.object(forKey: "toggleHotkeyKeyCode") as? Int
        let tModifiers = UserDefaults.standard.object(forKey: "toggleHotkeyModifiers") as? Int
        if let storedToggleHotkey = Self.validatedStoredHotkey(keyCode: tKeyCode, modifiers: tModifiers) {
            toggleHotkey = storedToggleHotkey
        } else if tKeyCode != nil || tModifiers != nil {
            UserDefaults.standard.removeObject(forKey: "toggleHotkeyKeyCode")
            UserDefaults.standard.removeObject(forKey: "toggleHotkeyModifiers")
            UserDefaults.standard.set(true, forKey: Defaults.toggleHotkeyConfiguredKey)
        } else if !toggleHotkeyConfigured {
            toggleHotkey = Defaults.defaultToggleHotkey
        }
    }
    
    // MARK: - Helpers
    
    private func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
    
    private func keyStringFromCode(_ keyCode: UInt16) -> String {
        PluginKeyCombo.keyName(for: keyCode)?.capitalized ?? "Key\(keyCode)"
    }
}

/// A simple window for recording a new hotkey
final class HotkeyRecorderWindow: NSWindow {
    
    var onHotkeyRecorded: ((UInt32, UInt32) -> Void)?
    private let recorderField = ShortcutRecorderField(frame: NSRect(x: 20, y: 70, width: 260, height: 30))
    
    init(title windowTitle: String = "Set Hotkey".localized) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        title = windowTitle
        isReleasedWhenClosed = false
        center()
        
        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        
        recorderField.onKeyComboRecorded = { [weak self] keyCode, modifiers in
            self?.onHotkeyRecorded?(keyCode, modifiers)
            self?.close()
        }
        recorderField.requiresGlobalHotkeyModifier = true
        cv.addSubview(recorderField)
        
        let hint = NSTextField(labelWithString: "Needs to include ⌘/⌥/⌃ modifiers".localized)
        hint.frame = NSRect(x: 20, y: 45, width: 260, height: 20)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        cv.addSubview(hint)
        
        let clearBtn = NSButton(title: "Clear Hotkey".localized, target: self, action: #selector(clearHotkey))
        clearBtn.frame = NSRect(x: 100, y: 10, width: 100, height: 28)
        clearBtn.bezelStyle = .rounded
        cv.addSubview(clearBtn)
        
        contentView = cv
        
        // Start recording immediately
        DispatchQueue.main.async {
            self.makeFirstResponder(self.recorderField)
            let _ = self.recorderField.becomeFirstResponder()
        }
    }
    
    @objc private func clearHotkey() {
        onHotkeyRecorded?(0, 0)
        close()
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
