import Cocoa
import Foundation

class ShortcutRecorderField: NSView {
    
    private var isRecording = false
    private let defaultPlaceholder = "Click here to record hotkey".localized
    private var recordedKeyCombo = ""
    
    // For Carbon-based global hotkey registration
    var onKeyComboRecorded: ((UInt32, UInt32) -> Void)?
    private var carbonKeyCode: UInt32?
    private var carbonModifiers: UInt32?
    
    private var eventMonitor: Any?
    
    private let label: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.alignment = .center
        l.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        l.textColor = .labelColor
        l.usesSingleLineMode = true
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
        
        updateLabelFromState()
    }
    
    // No deinit needed
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override var canBecomeKeyView: Bool {
        return true
    }
    
    override func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
    }
    
    // Set the initial value from saved config and append the hint
    var stringValue: String {
        get { return recordedKeyCombo }
        set {
            if !newValue.isEmpty && !newValue.hasSuffix("(Click to modify)".localized) && !isRecording {
                recordedKeyCombo = newValue
                updateLabelFromState()
            }
        }
    }
    
    // We only want the raw combo string when saving
    var rawComboString: String {
        return recordedKeyCombo
    }
    
    override func becomeFirstResponder() -> Bool {
        isRecording = true
        layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.2).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.stringValue = "Please press key combination...".localized
        label.textColor = .secondaryLabelColor
        return true
    }
    
    override func resignFirstResponder() -> Bool {
        isRecording = false
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        updateLabelFromState()
        return true
    }
    
    private func updateLabelFromState() {
        if recordedKeyCombo.isEmpty {
            label.stringValue = defaultPlaceholder
            label.textColor = .placeholderTextColor
        } else {
            label.stringValue = String(format: "%@ (Click to modify)".localized, recordedKeyCombo)
            label.textColor = .labelColor
        }
    }
    
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        
        let flags = event.modifierFlags
        var mods: [String] = []
        if flags.contains(.control) { mods.append("Control") }
        if flags.contains(.option) { mods.append("Option") }
        if flags.contains(.shift) { mods.append("Shift") }
        if flags.contains(.command) { mods.append("Command") }
        
        if mods.isEmpty {
            label.stringValue = "Please press key combination...".localized
        } else {
            label.stringValue = mods.joined(separator: "+") + "+"
        }
        
        super.flagsChanged(with: event)
    }
    
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        
        let keycode = event.keyCode
        
        // Ignore standalone modifier presses completely
        if [54, 55, 56, 58, 59, 60, 61, 62].contains(keycode) {
            return
        }
        
        // Collect modifiers
        let flags = event.modifierFlags
        var mods: [String] = []
        if flags.contains(.control) { mods.append("Control") }
        if flags.contains(.option) { mods.append("Option") }
        if flags.contains(.shift) { mods.append("Shift") }
        if flags.contains(.command) { mods.append("Command") }
        
        var keyName = ""
        if keycode == 53 { keyName = "Esc" }
        else if keycode == 36 { keyName = "Return" }
        else if keycode == 48 { keyName = "Tab" }
        else if keycode == 49 { keyName = "Space" }
        else if keycode == 51 { keyName = "Delete" }
        else if keycode == 123 { keyName = "Left" }
        else if keycode == 124 { keyName = "Right" }
        else if keycode == 125 { keyName = "Down" }
        else if keycode == 126 { keyName = "Up" }
        else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty, chars.first!.isASCII {
            keyName = chars.uppercased()
        }
        
        // As a fallback for some layouts, use the un-modifier characters
        if keyName.isEmpty, let chars = event.characters, !chars.isEmpty, chars.first!.isASCII {
            keyName = chars.uppercased()
        }
        
        if keyName.isEmpty { return }
        
        // Convert NSEvent modifier flags to Carbon modifier flags
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= 0x0100 } // cmdKey
        if flags.contains(.shift) { carbonMods |= 0x0200 }   // shiftKey
        if flags.contains(.option) { carbonMods |= 0x0800 }  // optionKey
        if flags.contains(.control) { carbonMods |= 0x1000 } // controlKey
        
        self.carbonKeyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbonMods
        self.onKeyComboRecorded?(self.carbonKeyCode!, self.carbonModifiers!)
        
        // Unfocus after recording.
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(nil)
        }
    }
}

/// A visual editor window for creating and modifying OpenFire plugins
final class PluginEditorWindow: NSWindow {

    private var editingPlugin: Plugin?
    
    // UI Elements
    private let nameField = NSTextField()
    private let enNameField = NSTextField()
    private let descField = NSTextField()
    private let enDescField = NSTextField()
    private let identifierField = NSTextField()
    private let iconPopUp = NSPopUpButton()
    private let typePopUp = NSPopUpButton()
    private let contentTextView = NSTextView(frame: .zero)
    private let contentViewScroll = NSScrollView()
    private let shortcutField = ShortcutRecorderField()
    private let infoLabel = NSTextField(labelWithString: "")
    
    private var customIconURL: URL?
    
    /// Initializes the editor. If `plugin` is nil, it starts in "New Plugin" mode.
    init(plugin: Plugin? = nil) {
        self.editingPlugin = plugin
        
        let width: CGFloat = 400
        let height: CGFloat = 500
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        self.title = plugin == nil ? "New Plugin".localized : "Edit Plugin".localized
        self.center()
        self.isReleasedWhenClosed = false
        
        setupUI()
        populate(with: plugin)
    }
    
    private func setupUI() {
        let cv = NSView()
        self.contentView = cv
        
        // Form layout constants
        let labelWidth: CGFloat = 80
        let spacing: CGFloat = 10
        
        // Helper to create labels
        func makeLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(label)
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: labelWidth)
            ])
            return label
        }
        
        // Name
        let nameLabel = makeLabel("Name:".localized)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "e.g.: Google Search".localized
        cv.addSubview(nameField)
        
        // EN Name
        let enNameLabel = makeLabel("Eng Name:".localized)
        enNameField.translatesAutoresizingMaskIntoConstraints = false
        enNameField.placeholderString = "Optional English Name".localized
        cv.addSubview(enNameField)
        
        // Description
        let descLabel = makeLabel("Description:".localized)
        descField.translatesAutoresizingMaskIntoConstraints = false
        descField.placeholderString = "Optional description".localized
        cv.addSubview(descField)
        
        // EN Description
        let enDescLabel = makeLabel("Eng Desc:".localized)
        enDescField.translatesAutoresizingMaskIntoConstraints = false
        enDescField.placeholderString = "Optional English description".localized
        cv.addSubview(enDescField)
        
        // Identifier
        let idLabel = makeLabel("Identifier:".localized)
        identifierField.translatesAutoresizingMaskIntoConstraints = false
        identifierField.placeholderString = "e.g.: com.openfire.search".localized
        if editingPlugin != nil {
            identifierField.isEnabled = false // Cannot change ID of existing plugin easily
        }
        cv.addSubview(identifierField)
        
        // Icon
        let iconLabel = makeLabel("Icon:".localized)
        iconPopUp.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(iconPopUp)
        
        let customIconButton = NSButton(title: "Custom...".localized, target: self, action: #selector(chooseCustomIcon))
        customIconButton.translatesAutoresizingMaskIntoConstraints = false
        customIconButton.bezelStyle = .rounded
        cv.addSubview(customIconButton)
        
        let commonSFSymbols = [
            "link", "magnifyingglass", "translate", "doc.on.clipboard", "scissors",
            "character.book.closed", "sparkles", "hammer", "pencil", "folder",
            "paperplane", "star.fill", "play.fill", "terminal", "chevron.right.circle",
            "safari", "globe", "message", "envelope", "book", "bookmark",
            "lightbulb", "gearshape", "wrench.and.screwdriver", "macwindow", "keyboard",
            "bolt.fill", "doc.text.magnifyingglass", "text.quote", "doc.on.clipboard.fill"
        ].sorted()
        
        let menu = NSMenu()
        for symbol in commonSFSymbols {
            let item = NSMenuItem(title: symbol, action: nil, keyEquivalent: "")
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                item.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            }
            menu.addItem(item)
        }
        iconPopUp.menu = menu
        
        // Action Type
        let typeLabel = makeLabel("Type:".localized)
        typePopUp.translatesAutoresizingMaskIntoConstraints = false
        typePopUp.addItems(withTitles: [
            "Open URL".localized,
            "Execute Shell Script".localized,
            "Execute AppleScript".localized,
            "Simulate Key Combo".localized,
            "Built-in: Copy".localized,
            "Built-in: Paste".localized
        ])
        typePopUp.target = self
        typePopUp.action = #selector(typeChanged)
        cv.addSubview(typePopUp)
        
        // Action Content
        let contentLabel = makeLabel("Action Content:".localized)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = NSFont.systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .right
        infoLabel.lineBreakMode = .byWordWrapping
        cv.addSubview(infoLabel)
        
        contentViewScroll.translatesAutoresizingMaskIntoConstraints = false
        contentViewScroll.hasVerticalScroller = true
        contentViewScroll.borderType = .bezelBorder
        
        contentTextView.autoresizingMask = .width
        contentTextView.isVerticallyResizable = true
        contentTextView.isHorizontallyResizable = false
        contentTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        contentTextView.allowsUndo = true
        contentTextView.isRichText = false
        contentViewScroll.documentView = contentTextView
        cv.addSubview(contentViewScroll)
        
        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.isHidden = true
        cv.addSubview(shortcutField)
        
        // Buttons
        let saveBtn = NSButton(title: "Save".localized, target: self, action: #selector(saveClicked))
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        cv.addSubview(saveBtn)
        
        let cancelBtn = NSButton(title: "Cancel".localized, target: self, action: #selector(cancelClicked))
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        cancelBtn.bezelStyle = .rounded
        cv.addSubview(cancelBtn)
        
        var deleteBtn: NSButton?
        if let p = editingPlugin {
            let pathStr = p.directoryURL.path
            let isBuiltIn = pathStr.hasPrefix(Bundle.main.bundlePath) || pathStr.contains("/Resources/Plugins/")
            
            let btnTitle = isBuiltIn ? "Restore Default".localized : "Delete".localized
            let btn = NSButton(title: btnTitle, target: self, action: #selector(deleteClicked))
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.bezelStyle = .rounded
            btn.contentTintColor = .systemRed
            cv.addSubview(btn)
            deleteBtn = btn
        }
        
        // Layout Constraints
        NSLayoutConstraint.activate([
            // Name Row
            nameLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            nameField.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: spacing),
            nameField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            // EN Name Row
            enNameLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            enNameLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            enNameField.firstBaselineAnchor.constraint(equalTo: enNameLabel.firstBaselineAnchor),
            enNameField.leadingAnchor.constraint(equalTo: enNameLabel.trailingAnchor, constant: spacing),
            enNameField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            // Description Row
            descLabel.topAnchor.constraint(equalTo: enNameField.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            descField.firstBaselineAnchor.constraint(equalTo: descLabel.firstBaselineAnchor),
            descField.leadingAnchor.constraint(equalTo: descLabel.trailingAnchor, constant: spacing),
            descField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            // EN Description Row
            enDescLabel.topAnchor.constraint(equalTo: descField.bottomAnchor, constant: 16),
            enDescLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            enDescField.firstBaselineAnchor.constraint(equalTo: enDescLabel.firstBaselineAnchor),
            enDescField.leadingAnchor.constraint(equalTo: enDescLabel.trailingAnchor, constant: spacing),
            enDescField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            // ID Row
            idLabel.topAnchor.constraint(equalTo: enDescField.bottomAnchor, constant: 16),
            idLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            identifierField.firstBaselineAnchor.constraint(equalTo: idLabel.firstBaselineAnchor),
            identifierField.leadingAnchor.constraint(equalTo: idLabel.trailingAnchor, constant: spacing),
            identifierField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            // Icon Row
            iconLabel.topAnchor.constraint(equalTo: identifierField.bottomAnchor, constant: 16),
            iconLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            iconPopUp.centerYAnchor.constraint(equalTo: iconLabel.centerYAnchor),
            iconPopUp.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: spacing),
            iconPopUp.trailingAnchor.constraint(equalTo: customIconButton.leadingAnchor, constant: -spacing),
            customIconButton.centerYAnchor.constraint(equalTo: iconLabel.centerYAnchor),
            customIconButton.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            customIconButton.widthAnchor.constraint(equalToConstant: 80),
            
            // Type Row
            typeLabel.topAnchor.constraint(equalTo: iconPopUp.bottomAnchor, constant: 16),
            typeLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            typePopUp.centerYAnchor.constraint(equalTo: typeLabel.centerYAnchor),
            typePopUp.leadingAnchor.constraint(equalTo: typeLabel.trailingAnchor, constant: spacing),
            typePopUp.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            // Content Row
            contentLabel.topAnchor.constraint(equalTo: typePopUp.bottomAnchor, constant: 24),
            contentLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            
            infoLabel.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 4),
            infoLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: contentLabel.trailingAnchor),
            
            contentViewScroll.topAnchor.constraint(equalTo: typePopUp.bottomAnchor, constant: 20),
            contentViewScroll.leadingAnchor.constraint(equalTo: contentLabel.trailingAnchor, constant: spacing),
            contentViewScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            
            shortcutField.topAnchor.constraint(equalTo: contentViewScroll.topAnchor),
            shortcutField.leadingAnchor.constraint(equalTo: contentViewScroll.leadingAnchor),
            shortcutField.trailingAnchor.constraint(equalTo: contentViewScroll.trailingAnchor),
            shortcutField.bottomAnchor.constraint(equalTo: contentViewScroll.bottomAnchor),
            
            // Buttons Row
            saveBtn.topAnchor.constraint(equalTo: contentViewScroll.bottomAnchor, constant: 20),
            saveBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            saveBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
            saveBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            
            cancelBtn.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor),
            cancelBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -10),
            cancelBtn.widthAnchor.constraint(equalTo: saveBtn.widthAnchor)
        ])
        
        if let deleteBtn = deleteBtn {
            NSLayoutConstraint.activate([
                deleteBtn.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor),
                deleteBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
                deleteBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
            ])
        }
        
        typeChanged() // Init labels
    }
    
    private func populate(with plugin: Plugin?) {
        guard let p = plugin else { return }
        nameField.stringValue = p.config.name
        enNameField.stringValue = p.config.localizedNames?["en"] ?? ""
        descField.stringValue = p.config.description ?? ""
        enDescField.stringValue = p.config.localizedDescriptions?["en"] ?? ""
        identifierField.stringValue = p.id
        let iconName = p.iconName
        let customIconPath = p.directoryURL.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: customIconPath.path) {
            self.customIconURL = customIconPath
            let item = NSMenuItem(title: "Custom Image".localized, action: nil, keyEquivalent: "")
            if let img = NSImage(contentsOf: customIconPath) {
                img.size = NSSize(width: 14, height: 14)
                item.image = img
            }
            iconPopUp.menu?.insertItem(item, at: 0)
            iconPopUp.selectItem(at: 0)
        } else {
            if iconPopUp.itemTitles.contains(iconName) {
                iconPopUp.selectItem(withTitle: iconName)
            } else {
                let item = NSMenuItem(title: iconName, action: nil, keyEquivalent: "")
                if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                    item.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
                }
                iconPopUp.menu?.insertItem(item, at: 0)
                iconPopUp.selectItem(at: 0)
            }
        }
        
        switch p.config.action.type {
        case .url:
            typePopUp.selectItem(at: 0)
            contentTextView.string = p.config.action.url ?? ""
        case .shellScript:
            typePopUp.selectItem(at: 1)
            var loaded = false
            if let scriptName = p.config.action.script {
                let scriptURL = p.directoryURL.appendingPathComponent(scriptName)
                let accessed = scriptURL.startAccessingSecurityScopedResource()
                var enc1: String.Encoding = .utf8
                if let content = try? String(contentsOf: scriptURL, usedEncoding: &enc1) {
                    contentTextView.string = content
                    loaded = true
                } else if p.config.action.inline == nil {
                    // Fallback: if there strictly is no such file and no inline, treat the JSON string value itself as the inline script
                    contentTextView.string = scriptName
                    loaded = true
                }
                if accessed { scriptURL.stopAccessingSecurityScopedResource() }
            }
            if !loaded, let inline = p.config.action.inline {
                contentTextView.string = inline
            }
        case .applescript:
            typePopUp.selectItem(at: 2)
            var loaded = false
            if let scriptName = p.config.action.script {
                let scriptURL = p.directoryURL.appendingPathComponent(scriptName)
                let accessed = scriptURL.startAccessingSecurityScopedResource()
                var enc2: String.Encoding = .utf8
                if let content = try? String(contentsOf: scriptURL, usedEncoding: &enc2) {
                    contentTextView.string = content
                    loaded = true
                } else if p.config.action.inline == nil {
                    // Fallback: if there strictly is no such file and no inline, treat the JSON string value itself as the inline script
                    contentTextView.string = scriptName
                    loaded = true
                }
                if accessed { scriptURL.stopAccessingSecurityScopedResource() }
            }
            if !loaded, let inline = p.config.action.inline {
                contentTextView.string = inline
            }
        case .keyCombo:
            typePopUp.selectItem(at: 3)
            let key = p.config.action.key ?? ""
            let mods = p.config.action.modifiers?.joined(separator: "+") ?? ""
            shortcutField.stringValue = mods.isEmpty ? key : "\(mods)+\(key)"
        case .copy:
            typePopUp.selectItem(at: 4)
            contentTextView.string = ""
        case .paste:
            typePopUp.selectItem(at: 5)
            contentTextView.string = ""
        }
        typeChanged()
    }
    
    @objc private func typeChanged() {
        let index = typePopUp.indexOfSelectedItem
        contentViewScroll.isHidden = false
        shortcutField.isHidden = true
        
        switch index {
        case 0: // URL
            infoLabel.stringValue = "Enter a complete URL\nUse {text} as a placeholder for selected text".localized
            contentTextView.isEditable = true
        case 1: // Shell
            infoLabel.stringValue = "Write Shell script\nSelected text is available via $OPENFIRE_TEXT".localized
            contentTextView.isEditable = true
        case 2: // AppleScript
            infoLabel.stringValue = "Write AppleScript code snippet\nSelected text: system attribute \"OPENFIRE_TEXT\"".localized
            contentTextView.isEditable = true
        case 3: // Key combo
            infoLabel.stringValue = "Record key combo\n(Click the box on the right and press keyboard)".localized
            contentViewScroll.isHidden = true
            shortcutField.isHidden = false
        case 4: // Copy
            infoLabel.stringValue = "Built-in: Copy\nWrites the original text directly to the clipboard\n(No content configuration needed)".localized
            contentTextView.isEditable = false
            contentTextView.string = ""
            contentViewScroll.isHidden = true
        case 5: // Paste
            infoLabel.stringValue = "Built-in: Paste\nTriggers the system Cmd+V paste operation\n(No content configuration needed)".localized
            contentTextView.isEditable = false
            contentTextView.string = ""
            contentViewScroll.isHidden = true
        default:
            break
        }
    }
    
    @objc private func cancelClicked() {
        self.close()
    }
    
    @objc private func saveClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let enName = enNameField.stringValue.trimmingCharacters(in: .whitespaces)
        let desc = descField.stringValue.trimmingCharacters(in: .whitespaces)
        let enDesc = enDescField.stringValue.trimmingCharacters(in: .whitespaces)
        let id = identifierField.stringValue.trimmingCharacters(in: .whitespaces)
        let icon = iconPopUp.titleOfSelectedItem ?? "bolt.fill"
        
        let typeIndex = typePopUp.indexOfSelectedItem
        let content: String
        if typeIndex == 3 {
            content = shortcutField.rawComboString.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            content = contentTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard !name.isEmpty, !id.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Save Failed".localized
            alert.informativeText = "Name and Identifier cannot be empty.".localized
            alert.runModal()
            return
        }
        
        let isCustomIcon = (iconPopUp.titleOfSelectedItem == "Custom Image".localized)
        let iconToSave = isCustomIcon ? (editingPlugin?.iconName ?? "bolt.fill") : (icon.isEmpty ? "bolt.fill" : icon)
        
        var actionDict: [String: Any] = [:]
        
        switch typeIndex {
        case 0: // URL
            if content.isEmpty { return showError("URL cannot be empty".localized) }
            actionDict = ["type": "url", "url": content]
        case 1: // Shell script
            if content.isEmpty { return showError("Script cannot be empty".localized) }
            actionDict = ["type": "shell-script", "script": "script.sh"] // Reference external file
        case 2: // AppleScript
            if content.isEmpty { return showError("Code cannot be empty".localized) }
            actionDict = ["type": "applescript", "script": "script.applescript"] // Reference external file
        case 3: // Key Combo
            if content.isEmpty { return showError("Key combo cannot be empty".localized) }
            let parts = content.components(separatedBy: "+")
            let key = parts.last?.lowercased() ?? ""
            let mods = parts.dropLast().map { $0.capitalized } // e.g., ["Command", "Shift"]
            actionDict = ["type": "key-combo", "key": key, "modifiers": mods]
        case 4: // Copy
            actionDict = ["type": "copy"]
        case 5: // Paste
            actionDict = ["type": "paste"]
        default:
            return showError("Unsupported plugin type for saving".localized)
        }
        
        var locNames: [String: String]? = nil
        if !enName.isEmpty {
            locNames = ["en": enName]
        }
        
        var locDescs: [String: String]? = nil
        if !enDesc.isEmpty {
            locDescs = ["en": enDesc]
        }
        
        var configDict: [String: Any] = [
            "name": name,
            "identifier": id,
            "icon": iconToSave,
            "action": actionDict
        ]
        
        if !desc.isEmpty {
            configDict["description"] = desc
        }
        
        if let locales = locNames {
            configDict["localizedNames"] = locales
        }
        if let descLocales = locDescs {
            configDict["localizedDescriptions"] = descLocales
        }
        
        // Preserve existing config like filter, order, isDefaultDisabled
        if let existing = editingPlugin?.config {
            if let filter = existing.filter {
                if let encoded = try? JSONEncoder().encode(filter),
                   let dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                    configDict["filter"] = dict
                }
            }
            if let order = existing.order {
                configDict["order"] = order
            }
            if let isDefaultDisabled = existing.isDefaultDisabled {
                configDict["isDefaultDisabled"] = isDefaultDisabled
            }
        }
        
        // Create Plugin Bundle
        let pluginsURL = PluginManager.shared.userPluginsURL
        let bundleURL: URL
        if let p = editingPlugin, p.directoryURL.path.hasPrefix(pluginsURL.path) {
            bundleURL = p.directoryURL
        } else {
            bundleURL = pluginsURL.appendingPathComponent("\(id).openfireext")
        }
        let editingPluginWasNil = (editingPlugin == nil)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                if FileManager.default.fileExists(atPath: bundleURL.path) {
                    if editingPluginWasNil {
                        DispatchQueue.main.async { self?.showError("A plugin with this identifier already exists".localized) }
                        return
                    }
                } else {
                    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                }
                
                // Write Config.json
                let configURL = bundleURL.appendingPathComponent("Config.json")
                let data = try JSONSerialization.data(withJSONObject: configDict, options: .prettyPrinted)
                try data.write(to: configURL, options: .atomic)
                
                // Write Script Files if applicable
                if typeIndex == 1 {
                    let scriptURL = bundleURL.appendingPathComponent("script.sh")
                    try content.write(to: scriptURL, atomically: true, encoding: .utf8)
                } else if typeIndex == 2 {
                    let scriptURL = bundleURL.appendingPathComponent("script.applescript")
                    try content.write(to: scriptURL, atomically: true, encoding: .utf8)
                }
                
                // Handle custom icon image
                let iconDestURL = bundleURL.appendingPathComponent("icon.png")
                let safeIconURL = self?.customIconURL
                if isCustomIcon {
                    if let srcURL = safeIconURL, srcURL != iconDestURL {
                        if FileManager.default.fileExists(atPath: iconDestURL.path) {
                            try? FileManager.default.removeItem(at: iconDestURL)
                        }
                        try FileManager.default.copyItem(at: srcURL, to: iconDestURL)
                    }
                } else {
                    // Not using custom image, delete if it exists
                    if FileManager.default.fileExists(atPath: iconDestURL.path) {
                        try? FileManager.default.removeItem(at: iconDestURL)
                    }
                }
                

                
                DispatchQueue.main.async {
                    // Force reload plugins
                    PluginManager.shared.reloadPlugins()
                    NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: nil)
                    self?.close()
                }
                
            } catch {
                DispatchQueue.main.async {
                    self?.showError(String(format: "Failed to write plugin: %@".localized, error.localizedDescription))
                }
            }
        }
    }
    
    @objc private func deleteClicked() {
        guard let p = editingPlugin else { return }
        
        // If it's a core default plugin, it can never be deleted
        if PluginManager.coreDefaultPluginIDs.contains(p.id) {
            let alert = NSAlert()
            alert.messageText = "Core Plugin Cannot Be Deleted".localized
            alert.informativeText = "This is a core system plugin and cannot be completely deleted. If you don't want to use it, please click the circle on the left to disable it.".localized
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        
        let pathStr = p.directoryURL.path
        let isBuiltIn = pathStr.hasPrefix(Bundle.main.bundlePath) || pathStr.contains("/Resources/Plugins/")
        let userPluginsURL = PluginManager.shared.userPluginsURL
        let userOverrideURL = userPluginsURL.appendingPathComponent("\(p.id).openfireext")
        let hasUserOverride = FileManager.default.fileExists(atPath: userOverrideURL.path)
        
        // Let PluginManager handle the actual file/soft deletion logic depending on whether it has an override
        let alert = NSAlert()
        alert.messageText = isBuiltIn && !hasUserOverride ? "Delete Built-in Plugin?".localized : (hasUserOverride && isBuiltIn ? "Restore Default?".localized : "Delete Plugin?".localized)
        alert.informativeText = isBuiltIn && !hasUserOverride ? "Are you sure you want to delete this built-in plugin? It will still exist but will be hidden from the list.".localized : (hasUserOverride && isBuiltIn ? "Are you sure you want to delete your modifications to this plugin? It will be restored to the built-in default state.".localized : "Are you sure you want to completely delete this plugin? This action is irreversible.".localized)
        alert.addButton(withTitle: isBuiltIn && hasUserOverride ? "Restore Default".localized : "Confirm Delete".localized)
        alert.addButton(withTitle: "Cancel".localized)
        
        if alert.runModal() == .alertFirstButtonReturn {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try PluginManager.shared.deletePlugin(p)
                    
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: nil)
                        self?.close()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showError(String(format: "Delete Failed: %@".localized, error.localizedDescription))
                    }
                }
            }
        }
    }
    
    @objc private func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose Icon".localized
        
        if panel.runModal() == .OK, let url = panel.url {
            self.customIconURL = url
            
            // Add or update "自定义图片" item in popup
            if let existing = iconPopUp.item(withTitle: "Custom Image".localized) {
                iconPopUp.menu?.removeItem(existing)
            }
            
            let item = NSMenuItem(title: "Custom Image".localized, action: nil, keyEquivalent: "")
            if let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 14, height: 14)
                item.image = img
            }
            iconPopUp.menu?.insertItem(item, at: 0)
            iconPopUp.selectItem(at: 0)
        }
    }

    private func showError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "Error".localized
        alert.informativeText = msg
        alert.alertStyle = .critical
        alert.runModal()
    }
}
