import Cocoa

/// A minimal, floating "Paste" popup that appears near the cursor
final class PastePopupWindow: NSPanel {
    
    var onPasteClicked: (() -> Void)?
    var onClearClicked: (() -> Void)?
    
    private let popupWidth: CGFloat = 152
    private let popupHeight: CGFloat = 36
    private var pasteButton: CapsuleActionButton!
    private var clearButton: CapsuleActionButton!
    
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
        container.layer?.cornerRadius = popupHeight / 2
        container.layer?.masksToBounds = true

        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.92).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.distribution = .fillEqually
        
        pasteButton = CapsuleActionButton()
        pasteButton.style = .accent
        pasteButton.title = "Paste".localized
        pasteButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        pasteButton.target = self
        pasteButton.action = #selector(pasteAction)
        pasteButton.imageHugsTitle = true
        pasteButton.contentTintColor = NSColor(calibratedRed: 0.84, green: 0.94, blue: 1.0, alpha: 1.0)
        
        if let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            pasteButton.image = icon.withSymbolConfiguration(config)
        }

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        
        clearButton = CapsuleActionButton()
        clearButton.style = .destructive
        clearButton.title = "Clear".localized
        clearButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        clearButton.target = self
        clearButton.action = #selector(clearAction)
        clearButton.imageHugsTitle = true
        
        if let icon = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            clearButton.image = icon.withSymbolConfiguration(config)
        }
        
        stackView.addArrangedSubview(pasteButton)
        stackView.addArrangedSubview(separator)
        stackView.addArrangedSubview(clearButton)
        
        container.addSubview(stackView)
        
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            separator.topAnchor.constraint(equalTo: stackView.topAnchor, constant: 3),
            separator.bottomAnchor.constraint(equalTo: stackView.bottomAnchor, constant: -3)
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
