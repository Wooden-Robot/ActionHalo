import Cocoa
import QuartzCore

/// The main radial menu view — draws a circular ring with segmented actions
final class RadialMenuView: NSView {
    private struct GeometrySignature: Equatable {
        let itemCount: Int
        let center: NSPoint
        let boundsSize: CGSize
    }
    
    // MARK: - Configuration (dynamic based on item count)
    
    private let minArcPerItem: CGFloat = 60
    private let baseOuterRadius: CGFloat = 130
    private let baseInnerRadius: CGFloat = 85
    private let baseIconSize: CGFloat = 32
    private let selectionDeadzoneRadius: CGFloat = 16
    private let centerCoreInset: CGFloat = 10
    private let outsideDismissPadding: CGFloat = 60
    
    private var gapAngle: CGFloat {
        let count = max(1, menuItems.count)
        if count >= 12 {
            return 0.015 // Very tight gap (~2px) for 12/16 items so it doesn't eat up space
        } else if count >= 8 {
            return 0.025
        } else {
            return 0.04  // Distinct separated blocks for 6 items HUD feel
        }
    }
    
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
    private var acceptsInteraction = true
    private let actionGate = SingleFireActionGate()
    private var sectorLayers: [CAShapeLayer] = []
    private var glowLayers: [CAShapeLayer] = []
    private var iconLayers: [CALayer] = []
    
    // Cached hits for O(1) mouse movement calculations without doing division/geometry
    private var hitTestBounds: [(start: CGFloat, end: CGFloat)] = []
    
    // Cache for SF Symbol CGImages to prevent re-rasterization every time the menu opens
    fileprivate static var symbolCache: [String: Any] = [:]
    
    // MARK: - Prewarming
    
    /// Prewarms the asset cache on the main thread because AppKit image objects are not thread-safe.
    static func prewarm(plugins: [Plugin]) {
        DispatchQueue.main.async {
            for plugin in plugins {
                // 1. Prewarm custom icons (triggers disk IO if needed)
                _ = plugin.customIcon
                
                // 2. Prewarm SF Symbol rasterization
                let cacheKey = plugin.iconName
                let needsRasterization = symbolCache[cacheKey] == nil
                
                if needsRasterization {
                    let iconSize: CGFloat = 24.0
                    if let symbolImage = NSImage(systemSymbolName: plugin.iconName, accessibilityDescription: plugin.name) {
                        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
                            .applying(.init(hierarchicalColor: .white))
                        let configured = symbolImage.withSymbolConfiguration(config)
                        let img = configured ?? symbolImage
                        img.isTemplate = true
                        let contents = img.layerContents(forContentsScale: 2.0)
                        symbolCache[cacheKey] = contents
                    } else {
                        symbolCache[cacheKey] = NSNull()
                    }
                }
            }
        }
    }
    
    private var labelLayers: [CATextLayer] = []
    private var centerLabel: CATextLayer?
    private var centerSubtitleLabel: CATextLayer?
    private var centerCircleLayer: CAShapeLayer?
    private var visualEffectMaskLayer = CAShapeLayer()
    private var lastGeometrySignature: GeometrySignature?
    private let hoverGlowRadius: CGFloat = 12
    private var centerLabelText: String = "ActionHalo"
    private var centerLabelColor: NSColor = .white
    private var centerSubtitleText: String = "HOLD AND RELEASE"
    private var centerSubtitleColor: NSColor = NSColor(white: 1.0, alpha: 0.42)
    
    // MARK: - Centers
    
    /// Where the visual elements are drawn
    var visualCenter: NSPoint = .zero
    
    /// Where mouse tracking/gestures originate
    var trackingCenter: NSPoint = .zero
    
    var onDismissRequested: (() -> Void)?
    
    // MARK: - Game HD Colors
    
    private var sectorColor: NSColor {
        isGTAModeEnabled
            ? NSColor(calibratedWhite: 0.05, alpha: 0.74)
            : NSColor(calibratedWhite: 0.08, alpha: 0.46)
    }
    
    private var sectorHoverColor: NSColor {
        isGTAModeEnabled
            ? NSColor(calibratedWhite: 0.88, alpha: 0.96)
            : NSColor(calibratedRed: 0.58, green: 0.82, blue: 0.96, alpha: 0.90)
    }
    
    private var glowColor: NSColor {
        isGTAModeEnabled
            ? NSColor(calibratedWhite: 0.98, alpha: 0.60)
            : NSColor(calibratedRed: 0.68, green: 0.9, blue: 1.0, alpha: 0.42)
    }
    
    private var borderColor: NSColor {
        isGTAModeEnabled
            ? NSColor(white: 1.0, alpha: 0.14)
            : NSColor(white: 1.0, alpha: 0.22)
    }
    
    private var borderHoverColor: NSColor {
        isGTAModeEnabled
            ? NSColor(white: 1.0, alpha: 0.94)
            : NSColor(white: 1.0, alpha: 0.62)
    }
    
    private let iconColor = NSColor.white
    private let labelColor = NSColor(white: 0.9, alpha: 1.0)
    private var centerHoverLabelColor: NSColor {
        windowBaseAlpha <= 0.02
            ? NSColor.white
            : NSColor(calibratedWhite: 0.99, alpha: 1.0)
    }
    
    // Store the base window alpha to know what to revert to when un-hovering
    var windowBaseAlpha: CGFloat = 0.25
    var isGTAModeEnabled: Bool = true
    
    private var baseSectorOpacity: Float { Float(windowBaseAlpha) }
    private var baseIconOpacity: Float { Float(windowBaseAlpha) * 0.85 }
    private var baseLabelOpacity: Float { Float(windowBaseAlpha) }
    private var centerCoreOpacity: Float { Float(windowBaseAlpha) }
    private var centerTextOpacity: Float { Float(windowBaseAlpha) }
    private var activeSectorOpacity: Float { min(1.0, Float(windowBaseAlpha) + 0.38) }
    private var activeIconOpacity: Float { min(1.0, Float(windowBaseAlpha) + 0.5) }
    private var activeCenterTitleOpacity: Float { max(0.92, min(1.0, Float(windowBaseAlpha) + 0.55)) }
    private var activeCenterSubtitleOpacity: Float {
        guard isGTAModeEnabled else { return activeCenterTitleOpacity }
        return max(0.82, min(1.0, Float(windowBaseAlpha) + 0.48))
    }
    
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

    func beginInteractionSession() {
        acceptsInteraction = true
        actionGate.reset()
    }

    func endInteractionSession() {
        acceptsInteraction = false
        _ = actionGate.consume()
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
            centerSubtitleLabel?.isHidden = true
            centerLabelText = "ActionHalo"
            centerLabelColor = .white
            centerSubtitleText = "HOLD AND RELEASE"
            centerSubtitleColor = NSColor(white: 1.0, alpha: 0.42)
            return
        }
        
        // Unhide global elements
        centerCircleLayer?.isHidden = false
        centerLabel?.isHidden = false
        centerSubtitleLabel?.isHidden = false
        
        let center = visualCenter
        let itemCount = menuItems.count
        let totalGap = gapAngle * CGFloat(itemCount)
        let availableAngle = 2 * .pi - totalGap
        let sectorAngle = availableAngle / CGFloat(itemCount)
        let geometrySignature = GeometrySignature(itemCount: itemCount, center: center, boundsSize: bounds.size)
        let needsGeometryRebuild = lastGeometrySignature != geometrySignature
        let shouldResetPresentationState = hoveredIndex != -1
        // Start from top (π/2) and go clockwise
        var startAngle = CGFloat.pi / 2
        
        if needsGeometryRebuild {
            // Pre-calculate hit test bounds array for ultra-fast 120Hz swiping
            hitTestBounds.removeAll(keepingCapacity: true)
            var currentStartAngle = CGFloat.pi / 2
            for _ in 0..<itemCount {
                let currentEnd = currentStartAngle - sectorAngle
                hitTestBounds.append((start: currentStartAngle, end: currentEnd))
                currentStartAngle = currentEnd - gapAngle
            }
        }
        
        // Ensure arrays are large enough (pooling)
        while sectorLayers.count < itemCount {
            let glowLayer = CAShapeLayer()
            glowLayer.fillColor = NSColor.clear.cgColor
            glowLayer.strokeColor = NSColor.clear.cgColor
            glowLayer.shadowColor = glowColor.cgColor
            glowLayer.shadowRadius = hoverGlowRadius
            glowLayer.shadowOpacity = 0
            glowLayer.shadowOffset = .zero
            glowLayer.shouldRasterize = true
            glowLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer?.addSublayer(glowLayer)
            glowLayers.append(glowLayer)
            
            let sectorLayer = CAShapeLayer()
            sectorLayer.fillColor = sectorColor.cgColor
            sectorLayer.strokeColor = borderColor.cgColor
            sectorLayer.lineWidth = 1.0
            sectorLayer.opacity = baseSectorOpacity
            sectorLayer.shouldRasterize = true
            sectorLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer?.addSublayer(sectorLayer)
            sectorLayers.append(sectorLayer)
            
            let iconLayer = CALayer()
            iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            iconLayer.shadowColor = NSColor.black.cgColor
            iconLayer.shadowRadius = 5
            iconLayer.shadowOpacity = 0.9
            iconLayer.shadowOffset = .zero
            iconLayer.opacity = baseIconOpacity
            // Rasterize icon layers so their dynamic alpha mask shadows don't recalculate on every 1.15x scale animation tick
            iconLayer.shouldRasterize = true
            iconLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
            layer?.addSublayer(iconLayer)
            iconLayers.append(iconLayer)
            
            let label = CATextLayer()
            label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            label.fontSize = 10
            label.alignmentMode = .center
            label.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            label.foregroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
            label.opacity = baseLabelOpacity
            label.isWrapped = false
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
        
        let combinedMaskPath = needsGeometryRebuild ? CGMutablePath() : nil
        
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
            
            // Determine base opacity multiplier based on executable state
            let executableMultiplier: Float = item.isExecutable ? 1.0 : 0.25
            
            if shouldResetPresentationState {
                sectorLayer.removeAllAnimations()
                glowLayer.removeAllAnimations()
                iconLayer.removeAllAnimations()
                labelLayer.removeAllAnimations()
            }
            
            // Re-apply base styles (in case it was left in hover state)
            if shouldResetPresentationState || sectorLayer.fillColor == nil {
                sectorLayer.fillColor = sectorColor.cgColor
                sectorLayer.strokeColor = borderColor.cgColor
                sectorLayer.lineWidth = 1.0
            }
            sectorLayer.opacity = baseSectorOpacity * executableMultiplier
            
            // Reset Glow
            if shouldResetPresentationState || glowLayer.fillColor == nil {
                glowLayer.shadowOpacity = 0
                glowLayer.fillColor = NSColor.clear.cgColor
            }
            
            // Reset Icon
            if shouldResetPresentationState {
                iconLayer.setValue(1.0, forKeyPath: "transform.scale")
                iconLayer.shadowRadius = 5
                iconLayer.shadowOpacity = 0.9
                iconLayer.shadowColor = NSColor.black.cgColor
            }
            iconLayer.opacity = baseIconOpacity * executableMultiplier
            
            labelLayer.opacity = baseLabelOpacity * executableMultiplier
            
            // Update Paths
            let midAngle = (startAngle + endAngle) / 2
            
            if needsGeometryRebuild {
                let sectorPath = createSectorPath(
                    center: center,
                    innerRadius: innerRadius,
                    outerRadius: outerRadius,
                    startAngle: startAngle,
                    endAngle: endAngle
                )
                sectorLayer.path = sectorPath.cgPath
                combinedMaskPath?.addPath(sectorPath.cgPath)
                
                let glowPath = createSectorPath(
                    center: center,
                    innerRadius: innerRadius - 3,
                    outerRadius: outerRadius + 5,
                    startAngle: startAngle + 0.01,
                    endAngle: endAngle - 0.01
                )
                glowLayer.path = glowPath.cgPath
                glowLayer.shadowPath = glowPath.cgPath // Fixes CA drop-shadow blur stutter
                
                // Icons are the main visual anchor, closer to the center of each slot.
                let iconRadius = (innerRadius + outerRadius) / 2 + 2
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
                
                // Slot number reads like a subtle HUD tag near the core.
                let labelRadius = innerRadius + 7
                let labelCenter = NSPoint(
                    x: center.x + labelRadius * cos(midAngle),
                    y: center.y + labelRadius * sin(midAngle)
                )
                
                labelLayer.bounds = CGRect(x: 0, y: 0, width: 28, height: 12)
                labelLayer.position = labelCenter
                labelLayer.transform = CATransform3DMakeRotation(midAngle - .pi / 2, 0, 0, 1)
            }
            
            labelLayer.string = String(format: "%02d", index + 1)
            labelLayer.foregroundColor = NSColor.white.withAlphaComponent(item.isExecutable ? 0.28 : 0.16).cgColor
            
            if let customIcon = item.customIcon {
                iconLayer.contents = customIcon
                iconLayer.contentsGravity = .resizeAspect
                
                // Add a bright white glow shadow so black custom PNGs remain visible
                // without destroying full-color App Icons
                iconLayer.shadowColor = NSColor.white.cgColor
                iconLayer.shadowRadius = 6
                iconLayer.shadowOpacity = 0.9
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
            cc.fillColor = NSColor.clear.cgColor
            cc.strokeColor = NSColor.clear.cgColor
            cc.lineWidth = 1.0
            cc.shadowColor = NSColor.black.cgColor
            cc.shadowRadius = 0
            cc.shadowOpacity = 0
            cc.shadowOffset = .zero
            cc.opacity = centerCoreOpacity
            layer?.addSublayer(cc)
            centerCircleLayer = cc
        }
        centerCircleLayer?.fillColor = (isGTAModeEnabled ? NSColor(calibratedWhite: 0.04, alpha: 0.92) : NSColor(calibratedWhite: 0.08, alpha: 0.32)).cgColor
        centerCircleLayer?.strokeColor = (isGTAModeEnabled ? NSColor(calibratedWhite: 1.0, alpha: 0.16) : NSColor(calibratedWhite: 1.0, alpha: 0.10)).cgColor
        centerCircleLayer?.shadowRadius = isGTAModeEnabled ? 18 : 6
        centerCircleLayer?.shadowOpacity = isGTAModeEnabled ? 0.45 : 0.12
        
        var circlePath: NSBezierPath?
        if needsGeometryRebuild {
            let circleEdge: CGFloat = centerCoreInset
            circlePath = NSBezierPath(ovalIn: CGRect(
                x: center.x - innerRadius + circleEdge,
                y: center.y - innerRadius + circleEdge,
                width: (innerRadius - circleEdge) * 2,
                height: (innerRadius - circleEdge) * 2
            ))
            centerCircleLayer?.path = circlePath?.cgPath
            centerCircleLayer?.shadowPath = circlePath?.cgPath // Precompute core shadow to prevent lag
        }
        
        // Label
        if centerLabel == nil {
            let cl = CATextLayer()
            cl.fontSize = 15
            cl.font = NSFont.systemFont(ofSize: 15, weight: .heavy)
            cl.foregroundColor = NSColor.white.cgColor
            cl.alignmentMode = .center
            cl.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            cl.isWrapped = true
            cl.truncationMode = .end
            cl.opacity = centerTextOpacity
            
            // Add a strong drop shadow so text is readable against bright backgrounds
            cl.shadowColor = NSColor.black.cgColor
            cl.shadowRadius = 8.0
            cl.shadowOpacity = 0.95
            cl.shadowOffset = .zero
            
            layer?.addSublayer(cl)
            centerLabel = cl
        }
        
        if centerSubtitleLabel == nil {
            let subtitle = CATextLayer()
            subtitle.fontSize = 10
            subtitle.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            subtitle.foregroundColor = NSColor(white: 1.0, alpha: 0.42).cgColor
            subtitle.alignmentMode = .center
            subtitle.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            subtitle.isWrapped = false
            subtitle.opacity = centerTextOpacity
            subtitle.truncationMode = .end
            subtitle.shadowColor = NSColor.black.cgColor
            subtitle.shadowRadius = 6.0
            subtitle.shadowOpacity = 0.9
            subtitle.shadowOffset = .zero
            layer?.addSublayer(subtitle)
            centerSubtitleLabel = subtitle
        }
        
        if needsGeometryRebuild {
            let labelEdge: CGFloat = 4
            centerLabel?.frame = CGRect(
                x: center.x - innerRadius + labelEdge,
                y: center.y - 20,
                width: (innerRadius - labelEdge) * 2,
                height: 36
            )
            centerSubtitleLabel?.frame = CGRect(
                x: center.x - innerRadius + labelEdge,
                y: center.y + 12,
                width: (innerRadius - labelEdge) * 2,
                height: 14
            )
        }
        centerLabel?.string = "ActionHalo"
        centerLabel?.foregroundColor = NSColor.white.cgColor
        centerLabel?.opacity = centerTextOpacity
        centerLabelText = "ActionHalo"
        centerLabelColor = .white
        centerSubtitleLabel?.string = isGTAModeEnabled ? "HOLD AND RELEASE" : ""
        centerSubtitleLabel?.foregroundColor = NSColor(white: 1.0, alpha: isGTAModeEnabled ? 0.42 : 0.0).cgColor
        centerSubtitleLabel?.opacity = centerTextOpacity
        centerSubtitleText = isGTAModeEnabled ? "HOLD AND RELEASE" : ""
        centerSubtitleColor = NSColor(white: 1.0, alpha: isGTAModeEnabled ? 0.42 : 0.0)
        centerCircleLayer?.opacity = centerCoreOpacity
        
        if needsGeometryRebuild {
            if let circlePath {
                combinedMaskPath?.addPath(circlePath.cgPath)
            }
            
            // Apply the exact mask to the underlying visual effect view
            if let visualEffectView = self.superview?.subviews.first(where: { $0 is NSVisualEffectView }) as? NSVisualEffectView {
                // The combined path is calculated in the coordinate space of RadialMenuView (centered at visualCenter).
                let radius = outerRadius + 15  // Same math as RadialMenuWindow
                var transform = CGAffineTransform(translationX: -(visualCenter.x - radius), y: -(visualCenter.y - radius))
                if let translatedPath = combinedMaskPath?.copy(using: &transform) {
                    visualEffectMaskLayer.path = translatedPath
                }
                visualEffectView.layer?.mask = visualEffectMaskLayer
            }
        }
        
        lastGeometrySignature = geometrySignature
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
        guard acceptsInteraction else { return }
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = hitTestSector(at: point)
        
        if newIndex != hoveredIndex {
            // Un-hover previous
            if hoveredIndex >= 0 && hoveredIndex < sectorLayers.count {
                unhoverSector(at: hoveredIndex)
            }
            
            // Hover new
            if newIndex >= 0 && newIndex < sectorLayers.count {
                hoverSector(at: newIndex)
            } else {
                // Reset center label when not hovering any sector
                updateCenterLabel(text: "ActionHalo", color: .white)
                updateCenterSubtitle(text: isGTAModeEnabled ? "HOLD AND RELEASE" : "", color: NSColor(white: 1.0, alpha: isGTAModeEnabled ? 0.42 : 0.0))
            }
            
            hoveredIndex = newIndex
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        guard acceptsInteraction else { return }
        // Clear all hover effects when mouse leaves the view
        if hoveredIndex >= 0 && hoveredIndex < sectorLayers.count {
            unhoverSector(at: hoveredIndex)
        }
        hoveredIndex = -1
        updateCenterLabel(text: "ActionHalo", color: .white)
        updateCenterSubtitle(text: isGTAModeEnabled ? "HOLD AND RELEASE" : "", color: NSColor(white: 1.0, alpha: isGTAModeEnabled ? 0.42 : 0.0))
    }
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        guard acceptsInteraction else { return }
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
        guard acceptsInteraction else { return }
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
        guard acceptsInteraction else { return }
        let point = convert(event.locationInWindow, from: nil)
        
        let dx = point.x - trackingCenter.x
        let dy = point.y - trackingCenter.y
        let distanceSquared = dx * dx + dy * dy
        let dismissRadius = outerRadius + outsideDismissPadding
        let deadzoneSquared = selectionDeadzoneRadius * selectionDeadzoneRadius
        
        // If they click far away, dismiss
        if distanceSquared > dismissRadius * dismissRadius {
            guard actionGate.consume() else { return }
            acceptsInteraction = false
            onDismissRequested?()
            return
        }
        
        // Micro-deadzone for dismissal (if user releases exactly where they clicked)
        // Set to 10 points so a standard stationary click can still act as a cancel 
        // without ruining the swiping feel.
        if distanceSquared < deadzoneSquared {
            guard actionGate.consume() else { return }
            acceptsInteraction = false
            onDismissRequested?()
            return
        }
        
        let index = hitTestSector(at: point)
        
        if index >= 0 && index < menuItems.count {
            let item = menuItems[index]
            guard item.isExecutable else { return }
            guard actionGate.consume() else { return }
            acceptsInteraction = false
            // Flash feedback and trigger immediately on mouse release
            flashSector(at: index) { [weak self] in
                self?.onItemSelected?(item)
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
        // Make hover highlight instantaneous for maximum responsiveness (game-feel)
        CATransaction.setDisableActions(true)
        
        // 1. Sector Fill
        sector.fillColor = sectorHoverColor.cgColor
        
        sector.strokeColor = borderHoverColor.cgColor
        sector.lineWidth = isGTAModeEnabled ? 2.0 : 1.0

        // Keep glow cheap: opacity/fill are much lighter than animating blur geometry.
        glow.shadowOpacity = isGTAModeEnabled ? 1.0 : 0.55
        glow.fillColor = glowColor.withAlphaComponent(isGTAModeEnabled ? 0.36 : 0.18).cgColor
        
        icon.setValue(1.22, forKeyPath: "transform.scale")
        icon.opacity = activeIconOpacity
        sector.opacity = activeSectorOpacity
        label.opacity = activeSectorOpacity
        centerLabel?.opacity = activeCenterTitleOpacity
        centerSubtitleLabel?.opacity = activeCenterSubtitleOpacity
        
        CATransaction.commit()
        
        // 5. Update center label with item title
        if index < menuItems.count {
            let item = menuItems[index]
            updateCenterLabel(text: item.title, color: centerHoverLabelColor)
            updateCenterSubtitle(text: centerSubtitle(for: item, index: index), color: centerSubtitleColor(for: item))
        }
    }
    
    private func unhoverSector(at index: Int) {
        let sector = sectorLayers[index]
        let glow = glowLayers[index]
        let icon = iconLayers[index]
        let label = labelLayers[index]
        
        CATransaction.begin()
        // Make un-hover highlight instantaneous
        CATransaction.setDisableActions(true)
        
        // 1. Sector Fill
        sector.fillColor = sectorColor.cgColor
        
        sector.strokeColor = borderColor.cgColor
        sector.lineWidth = 1.0
        
        glow.shadowOpacity = 0
        glow.fillColor = NSColor.clear.cgColor
        
        icon.setValue(1.0, forKeyPath: "transform.scale")
        icon.opacity = baseIconOpacity
        sector.opacity = baseSectorOpacity
        label.opacity = baseLabelOpacity
        centerLabel?.opacity = centerTextOpacity
        centerSubtitleLabel?.opacity = centerTextOpacity
        
        CATransaction.commit()
    }
    
    private func flashSector(at index: Int, completion: @escaping () -> Void) {
        let sector = sectorLayers[index]
        
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)
        sector.fillColor = NSColor(calibratedWhite: 1.0, alpha: 1.0).cgColor
        sector.strokeColor = NSColor.white.cgColor
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
        guard centerLabelText != text || centerLabelColor != color else { return }
        centerLabelText = text
        centerLabelColor = color
        
        // Disable implicit fade animation to make text change instantly
        // A cross-fade during fast swiping makes it feel choppy/laggy to the user
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cl.string = text
        cl.foregroundColor = color.cgColor
        CATransaction.commit()
    }
    
    private func updateCenterSubtitle(text: String, color: NSColor) {
        guard let subtitle = centerSubtitleLabel else { return }
        guard centerSubtitleText != text || centerSubtitleColor != color else { return }
        centerSubtitleText = text
        centerSubtitleColor = color
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        subtitle.string = text
        subtitle.foregroundColor = color.cgColor
        CATransaction.commit()
    }
    
    private func centerSubtitle(for item: RadialMenuItem, index: Int) -> String {
        guard isGTAModeEnabled else { return "" }
        let slot = String(format: "%02d", index + 1)
        
        switch item.action {
        case .pageNext:
            return "PAGE CONTROL"
        case .pagePrev:
            return "PAGE CONTROL"
        default:
            if !item.isExecutable {
                return "SLOT \(slot)  LOCKED"
            }
            return "SLOT \(slot)  READY"
        }
    }
    
    private func centerSubtitleColor(for item: RadialMenuItem) -> NSColor {
        guard isGTAModeEnabled else {
            return NSColor(white: 1.0, alpha: 0.0)
        }
        switch item.action {
        case .pageNext, .pagePrev:
            return NSColor(white: 1.0, alpha: 0.5)
        default:
            return item.isExecutable
                ? NSColor(white: 1.0, alpha: 0.65)
                : NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.82, alpha: 0.6)
        }
    }
    
    // MARK: - Hit Testing
    
    private func hitTestSector(at point: NSPoint) -> Int {
        let center = trackingCenter
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distanceSquared = dx * dx + dy * dy
        let deadzoneSquared = selectionDeadzoneRadius * selectionDeadzoneRadius
        // 10-point deadzone! Prevents normal stationary clicks from instantly selecting a sector,
        // while still feeling extremely responsive.
        if distanceSquared <= deadzoneSquared {
            return -1
        }
        
        guard hitTestBounds.count > 0 else { return -1 }
        
        // Convert mouse angle to standard trigonometric angle (0 to 2π, counter-clockwise from right)
        var angle = atan2(dy, dx)
        if angle < 0 {
            angle += 2 * .pi
        }
        
        // hitTestBounds are stored as (start: larger angle, end: smaller angle) in standard trig
        // going clockwise starting from π/2. Because they can wrap around 0, we need to check both.
        // Also note that gaps are not included in the bounds, so hovering over a gap returns -1.
        for (i, bounds) in hitTestBounds.enumerated() {
            var start = bounds.start
            var end = bounds.end
            
            // Normalize everything to positive 0...2π for easier comparison
            while start < 0 { start += 2 * .pi }
            while end < 0 { end += 2 * .pi }
            while start >= 2 * .pi { start -= 2 * .pi }
            while end >= 2 * .pi { end -= 2 * .pi }
            
            if start > end {
                // Normal case: sector doesn't cross the 0 angle line
                if angle <= start && angle >= end {
                    return menuItems[i].isExecutable ? i : -1
                }
            } else {
                // Wrapping case: sector crosses the 0 angle (e.g. start is 0.1, end is 6.0)
                // Since start > end is false, it means start wrapped around and is now smaller than end.
                // It's conceptually standard trig clockwise: 0.1 down to 0, then 2π down to 6.0.
                if angle <= start || angle >= end {
                    return menuItems[i].isExecutable ? i : -1
                }
            }
        }
        
        return -1
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let center = trackingCenter
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // Claim the full directional selection area handled by mouseUp. Keeping this
        // smaller lets the visual-effect sibling swallow clicks in the outer ring.
        if distance <= outerRadius + outsideDismissPadding {
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
