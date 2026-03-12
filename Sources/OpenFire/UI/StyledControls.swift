import Cocoa

final class CapsuleActionButton: NSButton {
    enum Style {
        case neutral
        case accent
        case destructive
    }
    
    var style: Style = .neutral {
        didSet { applyVisualState() }
    }
    
    private var isHovered = false {
        didSet { applyVisualState() }
    }
    
    private var trackingAreaRef: NSTrackingArea?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeft
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 10
        font = .systemFont(ofSize: 12, weight: .semibold)
        contentTintColor = foregroundColor
        applyVisualState()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
    
    override var isEnabled: Bool {
        didSet { applyVisualState() }
    }
    
    private var foregroundColor: NSColor {
        switch style {
        case .neutral:
            return .labelColor
        case .accent:
            return NSColor(calibratedRed: 0.80, green: 0.92, blue: 1.0, alpha: 1.0)
        case .destructive:
            return NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.83, alpha: 1.0)
        }
    }
    
    private var backgroundColor: NSColor {
        let alpha: CGFloat
        if !isEnabled {
            alpha = 0.08
        } else if isHovered {
            alpha = 0.24
        } else {
            alpha = 0.16
        }
        
        switch style {
        case .neutral:
            return NSColor.white.withAlphaComponent(alpha)
        case .accent:
            return NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.76, alpha: 1.0).withAlphaComponent(alpha + 0.04)
        case .destructive:
            return NSColor(calibratedRed: 0.74, green: 0.20, blue: 0.20, alpha: 1.0).withAlphaComponent(alpha + 0.02)
        }
    }
    
    private var borderColor: NSColor {
        switch style {
        case .neutral:
            return NSColor.white.withAlphaComponent(isHovered ? 0.18 : 0.10)
        case .accent:
            return NSColor(calibratedRed: 0.75, green: 0.90, blue: 1.0, alpha: 1.0).withAlphaComponent(isHovered ? 0.34 : 0.22)
        case .destructive:
            return NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.70, alpha: 1.0).withAlphaComponent(isHovered ? 0.30 : 0.18)
        }
    }
    
    private func applyVisualState() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = borderColor.cgColor
        alphaValue = isEnabled ? 1.0 : 0.55
        contentTintColor = foregroundColor
        needsDisplay = true
    }
}

final class CircularIconButton: NSButton {
    enum Style {
        case neutral
        case accent
        case destructive
    }
    
    var style: Style = .neutral {
        didSet { applyVisualState() }
    }
    
    private var isHovered = false {
        didSet { applyVisualState() }
    }
    
    private var trackingAreaRef: NSTrackingArea?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 10
        imageScaling = .scaleProportionallyDown
        applyVisualState()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
    
    private var tintColor: NSColor {
        switch style {
        case .neutral:
            return NSColor.labelColor.withAlphaComponent(isHovered ? 0.95 : 0.72)
        case .accent:
            return NSColor.systemBlue.withAlphaComponent(isHovered ? 0.95 : 0.8)
        case .destructive:
            return NSColor.systemRed.withAlphaComponent(isHovered ? 0.95 : 0.74)
        }
    }
    
    private var fillColor: NSColor {
        switch style {
        case .neutral:
            return NSColor.labelColor.withAlphaComponent(isHovered ? 0.10 : 0.04)
        case .accent:
            return NSColor.systemBlue.withAlphaComponent(isHovered ? 0.14 : 0.08)
        case .destructive:
            return NSColor.systemRed.withAlphaComponent(isHovered ? 0.14 : 0.08)
        }
    }
    
    private func applyVisualState() {
        wantsLayer = true
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.backgroundColor = fillColor.cgColor
        contentTintColor = tintColor
        alphaValue = isEnabled ? 1.0 : 0.5
        needsDisplay = true
    }
    
    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}
