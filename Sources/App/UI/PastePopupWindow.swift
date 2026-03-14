import Cocoa

/// A minimal, floating "Paste" popup that appears near the cursor
final class PastePopupWindow: NSPanel {
    
    var onPasteClicked: (() -> Void)?
    var onClearClicked: (() -> Void)?
    
    private let popupWidth: CGFloat = 148
    private let popupHeight: CGFloat = 32
    private var pasteButton: CapsuleActionButton!
    private var clearButton: CapsuleActionButton!
    private let container = NSView()
    
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
        container.frame = NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight)
        container.wantsLayer = true
        container.layer?.cornerRadius = popupHeight / 2
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.985).cgColor
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOffset = .zero
        container.layer?.shadowRadius = 10
        container.layer?.shadowOpacity = 0.16
        
        pasteButton = CapsuleActionButton()
        pasteButton.style = .accent
        pasteButton.usesSolidToolbarStyle = true
        pasteButton.segmentCornerRadius = 0
        pasteButton.title = "Paste".localized
        pasteButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pasteButton.target = self
        pasteButton.action = #selector(pasteAction)
        pasteButton.imageHugsTitle = true
        
        if let icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            pasteButton.image = icon.withSymbolConfiguration(config)
        }

        clearButton = CapsuleActionButton()
        clearButton.style = .neutral
        clearButton.usesSolidToolbarStyle = true
        clearButton.segmentCornerRadius = 0
        clearButton.title = "Clear".localized
        clearButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        clearButton.target = self
        clearButton.action = #selector(clearAction)
        clearButton.imageHugsTitle = true
        
        if let icon = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            clearButton.image = icon.withSymbolConfiguration(config)
        }
        
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        container.addSubview(pasteButton)
        container.addSubview(clearButton)
        container.addSubview(separator)

        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pasteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pasteButton.topAnchor.constraint(equalTo: container.topAnchor),
            pasteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pasteButton.trailingAnchor.constraint(equalTo: container.centerXAnchor),

            clearButton.leadingAnchor.constraint(equalTo: container.centerXAnchor),
            clearButton.topAnchor.constraint(equalTo: container.topAnchor),
            clearButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            separator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            separator.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            separator.widthAnchor.constraint(equalToConstant: 1)
        ])
        
        self.contentView = container
    }
    
    @objc private func pasteAction() {
        onPasteClicked?()
    }
    
    @objc private func clearAction() {
        onClearClicked?()
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
