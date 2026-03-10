import Cocoa

/// A button that changes its background color on hover
final class HoverButton: NSButton {
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.backgroundColor = NSColor.clear.cgColor
        
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .activeAlways],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = self.trackingAreas.first {
            self.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .activeAlways],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(trackingArea)
    }
    
    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.1).cgColor
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// A minimal, floating "Paste" popup that appears near the cursor
final class PastePopupWindow: NSPanel {
    
    var onPasteClicked: (() -> Void)?
    var onClearClicked: (() -> Void)?
    
    private let popupWidth: CGFloat = 120
    private let popupHeight: CGFloat = 30
    private var pasteButton: HoverButton!
    private var clearButton: HoverButton!
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = false
        
        setupUI()
    }
    
    private func setupUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = 15 // Capsule shape
        container.layer?.masksToBounds = true
        
        // Use a solid color instead of visual effect to guarantee visibility
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fillProportionally
        
        pasteButton = HoverButton()
        pasteButton.title = "Paste".localized
        pasteButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pasteButton.target = self
        pasteButton.action = #selector(pasteAction)
        
        if let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            pasteButton.image = icon.withSymbolConfiguration(config)
            pasteButton.imagePosition = .imageLeft
        }
        
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        
        clearButton = HoverButton()
        clearButton.title = "Clear".localized
        clearButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        clearButton.target = self
        clearButton.action = #selector(clearAction)
        
        if let icon = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            clearButton.image = icon.withSymbolConfiguration(config)
            clearButton.imagePosition = .imageLeft
        }
        
        stackView.addArrangedSubview(pasteButton)
        stackView.addArrangedSubview(separator)
        stackView.addArrangedSubview(clearButton)
        
        container.addSubview(stackView)
        
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.topAnchor.constraint(equalTo: stackView.topAnchor, constant: 4),
            separator.bottomAnchor.constraint(equalTo: stackView.bottomAnchor, constant: -4)
        ])
        
        self.contentView = container
    }
    
    @objc private func pasteAction() {
        onPasteClicked?()
        hidePopup()
    }
    
    @objc private func clearAction() {
        onClearClicked?()
        hidePopup()
    }
    
    func show(at screenPoint: NSPoint) {
        // Position slightly above the cursor
        let adjustedPoint = NSPoint(x: screenPoint.x - (popupWidth / 2), y: screenPoint.y + 15)
        setFrameOrigin(adjustedPoint)
        
        NSLog("[OpenFire-Debug] PastePopupWindow.show at: \(adjustedPoint)")
        
        self.alphaValue = 1.0
        self.makeKeyAndOrderFront(nil)
        
        NSLog("[OpenFire-Debug] PastePopupWindow forced show, isVisible=\(self.isVisible)")
    }
    
    func hidePopup(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }
    
    override var canBecomeKey: Bool { false }
}
