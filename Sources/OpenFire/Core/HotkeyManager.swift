import Cocoa
import Carbon

/// Manages the two global hotkeys:
/// 1) open the radial menu for the current selection
/// 2) toggle automatic text-selection triggering on/off
final class HotkeyManager {
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
            case registerFailed(OSStatus)
        }
    }
    
    static let shared = HotkeyManager()
    static let hotkeyChangedNotification = Notification.Name("OpenFireHotkeyChanged")
    static let toggleHotkeyChangedNotification = Notification.Name("OpenFireToggleHotkeyChanged")
    
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
        guard let hk = hotkey else { return "Not Set".localized }
        var parts: [String] = []
        if hk.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if hk.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hk.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hk.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        parts.append(keyStringFromCode(UInt16(hk.keyCode)))
        return parts.joined()
    }
    
    /// Human-readable description for toggle hotkey
    var toggleHotkeyDescription: String {
        guard let hk = toggleHotkey else { return "Not Set".localized }
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
    
    /// Register all global hotkeys
    @discardableResult
    func registerHotkeys() -> [RegistrationIssue] {
        unregisterHotkeys()
        var issues: [RegistrationIssue] = []

        if let hk = hotkey, let thk = toggleHotkey, hk == thk {
            let issue = RegistrationIssue(
                kind: .duplicateAssignment,
                message: "Open Menu Hotkey and Auto Trigger Toggle Hotkey cannot use the same shortcut.".localized
            )
            issues.append(issue)
            NSLog("[OpenFire] Hotkey registration skipped: duplicate assignment")
            return issues
        }
        
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
                if hotkeyID.id == 1 {
                    HotkeyManager.shared.onHotkeyPressed?()
                } else if hotkeyID.id == 2 {
                    HotkeyManager.shared.onToggleHotkeyPressed?()
                }
            }
            return noErr
        }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
        
        if let hk = hotkey {
            let hotkeyID = EventHotKeyID(signature: fourCharCode("OFIR"), id: 1)
            let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, hotkeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
            if status == noErr {
                NSLog("[OpenFire] Radial Menu Hotkey registered: \(hotkeyDescription)")
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
        
        if let thk = toggleHotkey {
            let toggleHotkeyID = EventHotKeyID(signature: fourCharCode("OFIR"), id: 2)
            let status = RegisterEventHotKey(thk.keyCode, thk.modifiers, toggleHotkeyID, GetApplicationEventTarget(), 0, &toggleHotkeyRef)
            if status == noErr {
                NSLog("[OpenFire] Auto-trigger toggle hotkey registered: \(toggleHotkeyDescription)")
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
        if let kc = keyCode, let mod = modifiers {
            hotkey = (UInt32(kc), UInt32(mod))
        } else if !menuHotkeyConfigured {
            hotkey = Defaults.defaultMenuHotkey
        }
        
        let toggleHotkeyConfigured = UserDefaults.standard.object(forKey: Defaults.toggleHotkeyConfiguredKey) as? Bool ?? false
        let tKeyCode = UserDefaults.standard.object(forKey: "toggleHotkeyKeyCode") as? Int
        let tModifiers = UserDefaults.standard.object(forKey: "toggleHotkeyModifiers") as? Int
        if let tkc = tKeyCode, let tmod = tModifiers {
            toggleHotkey = (UInt32(tkc), UInt32(tmod))
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
        let mapping: [UInt16: String] = [
            0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E",
            0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J",
            0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O",
            0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T",
            0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y",
            0x06: "Z", 0x31: "Space", 0x24: "Return", 0x30: "Tab",
            0x35: "Esc",
        ]
        return mapping[keyCode] ?? "Key\(keyCode)"
    }
}

    // We will update ShortcutRecorderField to support this in the next step.
    // For now, let's view it.

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
