import Cocoa
import QuartzCore

/// The main radial menu view — draws a circular ring with segmented actions
final class RadialMenuView: NSView {
    
    // MARK: - Configuration (dynamic based on item count)
    
    private let minArcPerItem: CGFloat = 60
    private let baseOuterRadius: CGFloat = 120
    private let baseInnerRadius: CGFloat = 55
    private let baseIconSize: CGFloat = 22
    private let gapAngle: CGFloat = 0.04  // Distinct separated blocks for HUD feel
    
    /// Dynamically computed radii based on item count
    var outerRadius: CGFloat {
        let count = CGFloat(max(menuItems.count, 1))
        let needed = (count * minArcPerItem) / (2 * .pi)
        return max(baseOuterRadius, min(needed, 200))
    }
    var innerRadius: CGFloat {
        let ratio = baseInnerRadius / baseOuterRadius
        return outerRadius * ratio
    }
    var iconSize: CGFloat {
        if menuItems.count <= 6 { return baseIconSize }
        return max(16, baseIconSize - CGFloat(menuItems.count - 6) * 1.0)
    }
    var menuDiameter: CGFloat { outerRadius * 2 + 30 }
    
    // MARK: - State
    
    var menuItems: [RadialMenuItem] = []
    var selectedText: String = ""
    var onItemSelected: ((RadialMenuItem) -> Void)?
    
    private var hoveredIndex: Int = -1
    private var sectorLayers: [CAShapeLayer] = []
    private var glowLayers: [CAShapeLayer] = []
    private var iconLayers: [CALayer] = []
    
    // Cached hits for O(1) mouse movement calculations without doing division/geometry
    private var hitTestBounds: [(start: CGFloat, end: CGFloat)] = []
    
    // Cache for SF Symbol CGImages to prevent re-rasterization every time the menu opens
    fileprivate static var symbolCache: [String: Any] = [:]
    
    // MARK: - Prewarming
    
    /// Prewarms the asset cache on a background thread to prevent stutter on first popup
    static func prewarm(plugins: [Plugin]) {
        DispatchQueue.global(qos: .utility).async {
            for plugin in plugins {
                // 1. Prewarm custom icons (triggers disk IO if needed)
                _ = plugin.customIcon
                
                // 2. Prewarm SF Symbol rasterization
                let cacheKey = plugin.iconName
                // Thread-safe dictionary read check (swift dictionaries aren't fully thread safe but assuming population only appends here)
                // Better approach to just jump to main thread for the dictionary write
                let needsRasterization = DispatchQueue.main.sync { symbolCache[cacheKey] == nil }
                
                if needsRasterization {
                    let iconSize: CGFloat = 24.0
                    if let symbolImage = NSImage(systemSymbolName: plugin.iconName, accessibilityDescription: plugin.name) {
                        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
                            .applying(.init(hierarchicalColor: .white))
                        let configured = symbolImage.withSymbolConfiguration(config)
                        let img = configured ?? symbolImage
                        img.isTemplate = true
                        let contents = img.layerContents(forContentsScale: 2.0)
                        DispatchQueue.main.async {
                            symbolCache[cacheKey] = contents
                        }
                    } else {
                        DispatchQueue.main.async {
                            symbolCache[cacheKey] = NSNull()
                        }
                    }
                }
            }
        }
    }
    
    private var labelLayers: [CATextLayer] = []
    private var centerLabel: CATextLayer?
    private var centerCircleLayer: CAShapeLayer?
    
    // MARK: - Centers
    
    /// Where the visual elements are drawn
    var visualCenter: NSPoint = .zero
    
    /// Where mouse tracking/gestures originate
    var trackingCenter: NSPoint = .zero
    
    var onDismissRequested: (() -> Void)?
    
    // MARK: - Game HD Colors
    
    // Base sector is a darker glass panel with sharp edges
    private let sectorColor = NSColor(white: 0.18, alpha: 0.85)
    
    // Hover is an energetic metallic blue/cyan glow
    private let sectorHoverColor = NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.9, alpha: 0.95)
    
    // Intense glow behind the hovered item
    private let glowColor = NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 0.9)
    
    // Borders are crisp and stand out
    private let borderColor = NSColor(white: 1.0, alpha: 0.25)
    private let borderHoverColor = NSColor(white: 1.0, alpha: 0.6)
    
    private let iconColor = NSColor.white
    private let labelColor = NSColor(white: 0.9, alpha: 1.0)
    
    // Store the base window alpha to know what to revert to when un-hovering
    var windowBaseAlpha: CGFloat = 0.25
    
    // MARK: - Init
    
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
        layer?.masksToBounds = false
        setupTrackingArea()
    }
    
    private var trackingArea: NSTrackingArea?
    
    private func setupTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }
    
    // MARK: - Layout
    
    func buildMenu() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        defer { CATransaction.commit() }
        
        guard !menuItems.isEmpty else {
            // Hide everything if empty
            sectorLayers.forEach { $0.isHidden = true }
            glowLayers.forEach { $0.isHidden = true }
            iconLayers.forEach { $0.isHidden = true }
            labelLayers.forEach { $0.isHidden = true }
            centerCircleLayer?.isHidden = true
            centerLabel?.isHidden = true
            return
        }
        
        // Unhide global elements
        centerCircleLayer?.isHidden = false
        centerLabel?.isHidden = false
        
        let center = visualCenter
        let itemCount = menuItems.count
        let totalGap = gapAngle * CGFloat(itemCount)
        let availableAngle = 2 * .pi - totalGap
        let sectorAngle = availableAngle / CGFloat(itemCount)
        // Start from top (π/2) and go clockwise
        var startAngle = CGFloat.pi / 2
        
        // Pre-calculate hit test bounds array for ultra-fast 120Hz swiping
        hitTestBounds.removeAll()
        var currentStartAngle: CGFloat = 0
        for _ in 0..<itemCount {
            let currentEnd = currentStartAngle + sectorAngle
            hitTestBounds.append((start: currentStartAngle, end: currentEnd + gapAngle))
            currentStartAngle = currentEnd + gapAngle
        }
        
        // Ensure arrays are large enough (pooling)
        while sectorLayers.count < itemCount {
            let glowLayer = CAShapeLayer()
            glowLayer.fillColor = NSColor.clear.cgColor
            glowLayer.strokeColor = NSColor.clear.cgColor
            glowLayer.shadowColor = glowColor.cgColor
            glowLayer.shadowRadius = 0
            glowLayer.shadowOpacity = 0
            glowLayer.shadowOffset = .zero
            layer?.addSublayer(glowLayer)
            glowLayers.append(glowLayer)
            
            let sectorLayer = CAShapeLayer()
            sectorLayer.fillColor = sectorColor.cgColor
            sectorLayer.strokeColor = borderColor.cgColor
            sectorLayer.lineWidth = 0.5
            sectorLayer.opacity = Float(self.windowBaseAlpha) // Added opacity
            layer?.addSublayer(sectorLayer)
            sectorLayers.append(sectorLayer)
            
            let iconLayer = CALayer()
            iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            iconLayer.shadowColor = NSColor.black.cgColor
            iconLayer.shadowRadius = 2
            iconLayer.shadowOpacity = 0.6
            iconLayer.shadowOffset = CGSize(width: 0, height: -1)
            iconLayer.opacity = Float(self.windowBaseAlpha) * 0.85 // Added opacity
            // Rasterize icon layers so their dynamic alpha mask shadows don't recalculate on every 1.15x scale animation tick
            iconLayer.shouldRasterize = true
            iconLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer?.addSublayer(iconLayer)
            iconLayers.append(iconLayer)
            
            let label = CATextLayer()
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.fontSize = 13
            label.alignmentMode = .center
            label.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            label.foregroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
            label.opacity = Float(self.windowBaseAlpha)
            layer?.addSublayer(label)
            labelLayers.append(label)
        }
        
        // Hide unused pooled layers
        for i in itemCount..<sectorLayers.count {
            sectorLayers[i].isHidden = true
            glowLayers[i].isHidden = true
            iconLayers[i].isHidden = true
            labelLayers[i].isHidden = true
        }
        
        let combinedMaskPath = CGMutablePath()
        
        for (index, item) in menuItems.enumerated() {
            let endAngle = startAngle - sectorAngle
            
            let sectorLayer = sectorLayers[index]
            let glowLayer = glowLayers[index]
            let iconLayer = iconLayers[index]
            let labelLayer = labelLayers[index]
            
            sectorLayer.isHidden = false
            glowLayer.isHidden = false
            iconLayer.isHidden = false
            labelLayer.isHidden = false
            
            // Clean up old hover state paths/animations just in case
            sectorLayer.removeAllAnimations()
            glowLayer.removeAllAnimations()
            iconLayer.removeAllAnimations()
            labelLayer.removeAllAnimations()
            
            // Re-apply base styles (in case it was left in hover state)
            sectorLayer.fillColor = sectorColor.cgColor
            sectorLayer.strokeColor = borderColor.cgColor
            sectorLayer.lineWidth = 0.5
            sectorLayer.opacity = Float(self.windowBaseAlpha)
            
            // Reset Glow
            glowLayer.shadowRadius = 0
            glowLayer.shadowOpacity = 0
            glowLayer.fillColor = NSColor.clear.cgColor
            
            // Reset Icon
            iconLayer.setValue(1.0, forKeyPath: "transform.scale")
            iconLayer.shadowRadius = 2
            iconLayer.shadowOpacity = 0.6
            iconLayer.shadowColor = NSColor.black.cgColor
            iconLayer.opacity = Float(self.windowBaseAlpha) * 0.85
            
            labelLayer.opacity = Float(self.windowBaseAlpha)
            
            // Update Paths
            let sectorPath = createSectorPath(
                center: center,
                innerRadius: innerRadius,
                outerRadius: outerRadius,
                startAngle: startAngle,
                endAngle: endAngle
            )
            sectorLayer.path = sectorPath.cgPath
            
            // Add to combined mask for the glass effect background
            combinedMaskPath.addPath(sectorPath.cgPath)
            
            let glowPath = createSectorPath(
                center: center,
                innerRadius: innerRadius - 3,
                outerRadius: outerRadius + 5,
                startAngle: startAngle + 0.01,
                endAngle: endAngle - 0.01
            )
            glowLayer.path = glowPath.cgPath
            glowLayer.shadowPath = glowPath.cgPath // Fixes CA drop-shadow blur stutter
            
            // Update Icon
            let midAngle = (startAngle + endAngle) / 2
            
            // Icon placed normally in the center of the arc space
            let iconRadius = (innerRadius + outerRadius) / 2 + 3
            let iconCenter = NSPoint(
                x: center.x + iconRadius * cos(midAngle),
                y: center.y + iconRadius * sin(midAngle)
            )
            
            iconLayer.frame = CGRect(
                x: iconCenter.x - iconSize / 2,
                y: iconCenter.y - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            
            // Update Number Label to be directly against the inside edge
            let labelRadius = innerRadius + 10
            let labelCenter = NSPoint(
                x: center.x + labelRadius * cos(midAngle),
                y: center.y + labelRadius * sin(midAngle)
            )
            
            labelLayer.string = "\(index + 1)"
            
            // Set frame size
            labelLayer.bounds = CGRect(x: 0, y: 0, width: 20, height: 16)
            // Position using anchorPoint (0.5, 0.5)
            labelLayer.position = labelCenter
            
            // Rotate the text so it aligns radially (bottom of text points to center)
            labelLayer.transform = CATransform3DMakeRotation(midAngle - .pi / 2, 0, 0, 1)
            
            if let customIcon = item.customIcon {
                iconLayer.contents = customIcon
                iconLayer.contentsGravity = .resizeAspect
                
                // Add a bright white glow shadow so black custom PNGs remain visible
                // without destroying full-color App Icons
                iconLayer.shadowColor = NSColor.white.cgColor
                iconLayer.shadowRadius = 3
                iconLayer.shadowOpacity = 0.8
                iconLayer.shadowOffset = .zero
            } else {
                let cacheKey = item.iconName
                if let cachedContents = RadialMenuView.symbolCache[cacheKey] {
                    iconLayer.contents = (cachedContents is NSNull) ? nil : cachedContents
                } else if let symbolImage = NSImage(systemSymbolName: item.iconName, accessibilityDescription: item.title) {
                    let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
                        .applying(.init(hierarchicalColor: .white))
                    let configured = symbolImage.withSymbolConfiguration(config)
                    let img = configured ?? symbolImage
                    img.isTemplate = true
                    let contents = img.layerContents(forContentsScale: 2.0)
                    RadialMenuView.symbolCache[cacheKey] = contents
                    iconLayer.contents = contents
                } else {
                    RadialMenuView.symbolCache[cacheKey] = NSNull()
                    iconLayer.contents = nil
                }
                iconLayer.contentsGravity = .resizeAspect
            }
            
            // Move to next sector (with gap)
            startAngle = endAngle - gapAngle
        }
        
        hoveredIndex = -1
        
        // Draw or Update center core
        if centerCircleLayer == nil {
            let cc = CAShapeLayer()
            // Sleek metallic center core
            cc.fillColor = NSColor(white: 0.05, alpha: 0.9).cgColor
            cc.strokeColor = NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.9, alpha: 0.5).cgColor
            cc.lineWidth = 1.5
            cc.shadowColor = NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.9, alpha: 1.0).cgColor
            cc.shadowRadius = 10
            cc.shadowOpacity = 0.4
            cc.shadowOffset = CGSize(width: 0, height: 0)
            cc.opacity = Float(self.windowBaseAlpha) // Added opacity
            layer?.addSublayer(cc)
            centerCircleLayer = cc
        }
        
        let circleEdge: CGFloat = 4 // Very tight gap
        let circlePath = NSBezierPath(ovalIn: CGRect(
            x: center.x - innerRadius + circleEdge,
            y: center.y - innerRadius + circleEdge,
            width: (innerRadius - circleEdge) * 2,
            height: (innerRadius - circleEdge) * 2
        ))
        centerCircleLayer?.path = circlePath.cgPath
        centerCircleLayer?.shadowPath = circlePath.cgPath // Precompute core shadow to prevent lag
        
        // Label
        if centerLabel == nil {
            let cl = CATextLayer()
            cl.fontSize = 11
            cl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            cl.foregroundColor = NSColor(white: 0.8, alpha: 1.0).cgColor
            cl.alignmentMode = .center
            cl.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            cl.isWrapped = true
            cl.truncationMode = .end
            cl.opacity = Float(self.windowBaseAlpha) // Added opacity
            layer?.addSublayer(cl)
            centerLabel = cl
        }
        
        let labelEdge: CGFloat = 4
        centerLabel?.frame = CGRect(
            x: center.x - innerRadius + labelEdge,
            y: center.y - 18,
            width: (innerRadius - labelEdge) * 2,
            height: 28
        )
        centerLabel?.string = "OpenFire"
        
        // Add center core to the combined mask
        combinedMaskPath.addPath(circlePath.cgPath)
        
        // Apply the exact mask to the underlying visual effect view
        if let visualEffectView = self.superview?.subviews.first(where: { $0 is NSVisualEffectView }) as? NSVisualEffectView {
            let maskLayer = CAShapeLayer()
            // The combined path is calculated in the coordinate space of RadialMenuView (centered at visualCenter).
            // We need to translate it to the coordinate space of the visualEffectView
            // However, RadialMenuWindow sets radialMenuView.frame = cv.bounds and the visual center relative to that,
            // while it sets visualEffectView.frame to be a tightly wrapped box around vCenter.
            // Let's offset the path to match the visualEffectView coordinate space.
            let radius = outerRadius + 15  // Same math as RadialMenuWindow
            var transform = CGAffineTransform(translationX: -(visualCenter.x - radius), y: -(visualCenter.y - radius))
            if let translatedPath = combinedMaskPath.copy(using: &transform) {
                maskLayer.path = translatedPath
            }
            visualEffectView.layer?.mask = maskLayer
        }
    }
    
    // MARK: - Sector Path
    
    private func createSectorPath(center: NSPoint, innerRadius: CGFloat, outerRadius: CGFloat, startAngle: CGFloat, endAngle: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        
        // Outer arc
        path.appendArc(
            withCenter: center,
            radius: outerRadius,
            startAngle: startAngle * 180 / .pi,
            endAngle: endAngle * 180 / .pi,
            clockwise: true
        )
        
        // Line to inner arc
        path.appendArc(
            withCenter: center,
            radius: innerRadius,
            startAngle: endAngle * 180 / .pi,
            endAngle: startAngle * 180 / .pi,
            clockwise: false
        )
        
        path.close()
        return path
    }
    
    // MARK: - Mouse Handling
    
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = hitTestSector(at: point)
        
        if newIndex != hoveredIndex {
            // Un-hover previous
            if hoveredIndex >= 0 && hoveredIndex < sectorLayers.count {
                unhoverSector(at: hoveredIndex)
            }
            
            // Play haptic tick when entering a new valid sector
            if newIndex >= 0 && newIndex < sectorLayers.count {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            }
            
            // Hover new
            if newIndex >= 0 && newIndex < sectorLayers.count {
                hoverSector(at: newIndex)
            } else {
                // Reset center label when not hovering any sector
                updateCenterLabel(text: "OpenFire", color: NSColor(white: 0.5, alpha: 1.0))
            }
            
            hoveredIndex = newIndex
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        // Clear all hover effects when mouse leaves the view
        if hoveredIndex >= 0 && hoveredIndex < sectorLayers.count {
            unhoverSector(at: hoveredIndex)
        }
        hoveredIndex = -1
        updateCenterLabel(text: "OpenFire", color: NSColor(white: 0.5, alpha: 1.0))
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        // Catch to ensure we receive mouseUp/mouseDragged
        let point = convert(event.locationInWindow, from: nil)
        let index = hitTestSector(at: point)
        if index != hoveredIndex {
            if hoveredIndex >= 0 && hoveredIndex < sectorLayers.count {
                unhoverSector(at: hoveredIndex)
            }
            if index >= 0 && index < sectorLayers.count {
                hoverSector(at: index)
            }
            hoveredIndex = index
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = hitTestSector(at: point)
        if index != hoveredIndex {
            if hoveredIndex >= 0 && hoveredIndex < sectorLayers.count {
                unhoverSector(at: hoveredIndex)
            }
            if index >= 0 && index < sectorLayers.count {
                hoverSector(at: index)
            }
            hoveredIndex = index
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        let dx = point.x - trackingCenter.x
        let dy = point.y - trackingCenter.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // If they click far away or inside the deadzone, dismiss
        if distance > outerRadius + 150 || distance < 5 {
            onDismissRequested?()
            return
        }
        
        let index = hitTestSector(at: point)
        
        if index >= 0 && index < menuItems.count {
            // Flash feedback and trigger immediately on mouse release
            flashSector(at: index) { [weak self] in
                self?.onItemSelected?(self!.menuItems[index])
            }
        }
    }
    
    // MARK: - Hover Effects
    
    private func hoverSector(at index: Int) {
        let sector = sectorLayers[index]
        let glow = glowLayers[index]
        let icon = iconLayers[index]
        let label = labelLayers[index]
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        
        // 1. Sector Fill
        sector.fillColor = sectorHoverColor.cgColor
        
        // 2. Sector Stroke (thicker and brighter for game feel)
        sector.strokeColor = borderHoverColor.cgColor
        sector.lineWidth = 2.0
        
        // 3. Glow effect (intense neon)
        glow.shadowRadius = 15
        glow.shadowOpacity = 1.0
        glow.shadowColor = glowColor.cgColor
        glow.fillColor = glowColor.withAlphaComponent(0.25).cgColor
        
        // 4. Icon scale & opacity
        icon.setValue(1.15, forKeyPath: "transform.scale")
        icon.opacity = 1.0
        sector.opacity = 1.0
        label.opacity = 1.0
        centerCircleLayer?.opacity = 1.0
        centerLabel?.opacity = 1.0
        
        CATransaction.commit()
        
        // 5. Update center label with item title
        if index < menuItems.count {
            updateCenterLabel(text: menuItems[index].title, color: .white)
        }
    }
    
    private func unhoverSector(at index: Int) {
        let sector = sectorLayers[index]
        let glow = glowLayers[index]
        let icon = iconLayers[index]
        let label = labelLayers[index]
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        
        // 1. Sector Fill
        sector.fillColor = sectorColor.cgColor
        
        // 2. Sector Stroke
        sector.strokeColor = borderColor.cgColor
        sector.lineWidth = 0.5
        
        // 3. Remove Glow
        glow.shadowRadius = 0
        glow.shadowOpacity = 0
        glow.fillColor = NSColor.clear.cgColor
        
        // 4. Icon scale & opacity back
        icon.setValue(1.0, forKeyPath: "transform.scale")
        icon.opacity = Float(self.windowBaseAlpha) * 0.85
        sector.opacity = Float(self.windowBaseAlpha)
        label.opacity = Float(self.windowBaseAlpha)
        
        CATransaction.commit()
        
        // 5. Restore center circle & label opacity unconditionally
        // (If we immediately hover another sector, hoverSector will reset them to 1.0)
        centerCircleLayer?.opacity = Float(self.windowBaseAlpha)
        centerLabel?.opacity = Float(self.windowBaseAlpha)
    }
    
    private func flashSector(at index: Int, completion: @escaping () -> Void) {
        let sector = sectorLayers[index]
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)
        sector.fillColor = NSColor(calibratedRed: 0.6, green: 0.8, blue: 1.0, alpha: 1.0).cgColor
        CATransaction.commit()
        
        // Execute the action IMMEDIATELY for responsiveness. Do not rely on CATransaction 
        // completion blocks as they are often dropped by macOS if animations overlap.
        completion()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            sector.fillColor = self.sectorHoverColor.cgColor
            CATransaction.commit()
        }
    }
    
    private func updateCenterLabel(text: String, color: NSColor) {
        guard let cl = centerLabel else { return }
        
        // Disable implicit fade animation to make text change instantly
        // A cross-fade during fast swiping makes it feel choppy/laggy to the user
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cl.string = text
        cl.foregroundColor = color.cgColor
        CATransaction.commit()
    }
    
    // MARK: - Hit Testing
    
    private func hitTestSector(at point: NSPoint) -> Int {
        let center = trackingCenter
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // Deadzone in the center where nothing is selected
        // Set to 5 so the user has to slide slightly to select, avoiding instant misclicks.
        if distance < 5 {
            return -1
        }
        
        guard hitTestBounds.count > 0 else { return -1 }
        
        // Calculate angle of the mouse relative to center (0 to 2π)
        var angle = atan2(dy, dx)
        if angle < 0 {
            angle += 2 * .pi
        }
        
        // Convert mouse angle to the same coordinate system (clockwise from top)
        var relativeAngle = CGFloat.pi / 2 - angle
        if relativeAngle < 0 {
            relativeAngle += 2 * .pi
        }
        
        // O(1) array lookup loop
        for (i, bounds) in hitTestBounds.enumerated() {
            if relativeAngle >= bounds.start && relativeAngle < bounds.end {
                return i
            }
        }
        
        return -1
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let center = trackingCenter
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // Only claim the click if it's within our interactive radius + a small margin
        if distance <= outerRadius + 30 {
            return self
        }
        
        // Let the click pass through to other windows/apps if it's far away
        return nil
    }
}

// MARK: - NSBezierPath CGPath Extension

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }
        
        return path
    }
}
