import Cocoa

/// A floating, borderless panel that hosts the radial menu
final class RadialMenuWindow: NSPanel {
    private static let wheelBackdropEnabledKey = "WheelBackdropEnabled"
    
    private let radialMenuView: RadialMenuView
    private let backdropView = NSView(frame: .zero)
    private let visualEffectView = NSVisualEffectView(frame: .zero)
    private let vignetteLayer = CAGradientLayer()
    private var suppressVisualEffectImmediateAlphaUpdate = false
    
    var onItemSelected: ((RadialMenuItem) -> Void)?
    var onDismissRequested: (() -> Void)?
    
    // Pagination state
    private var allItems: [RadialMenuItem] = []
    private var currentPage: Int = 0
    private var currentSelectedText: String = ""
    private var currentScreenPoint: NSPoint = .zero
    private var lastScreenFrame: NSRect = .zero
    private var presentationGeneration: UInt64 = 0
    private var isDismissing = false
    private var dismissalRequested = false
    private let dismissDeadzoneRadius: CGFloat = 16
    private let outsideDismissPadding: CGFloat = 90
    private let compactWindowPadding: CGFloat = 28
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        radialMenuView = RadialMenuView(frame: .zero)
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Configure as floating transparent panel
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true
        
        backdropView.wantsLayer = true
        backdropView.alphaValue = 0
        let backdropLayer = CAGradientLayer()
        backdropLayer.colors = [
            NSColor(calibratedWhite: 0.01, alpha: 0.86).cgColor,
            NSColor(calibratedWhite: 0.015, alpha: 0.58).cgColor,
            NSColor(calibratedWhite: 0.01, alpha: 0.86).cgColor
        ]
        backdropLayer.locations = [0.0, 0.5, 1.0]
        backdropLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        backdropLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        backdropView.layer = backdropLayer
        
        vignetteLayer.type = .radial
        vignetteLayer.colors = [
            NSColor(calibratedWhite: 0.0, alpha: 0.0).cgColor,
            NSColor(calibratedWhite: 0.0, alpha: 0.08).cgColor,
            NSColor(calibratedWhite: 0.0, alpha: 0.34).cgColor,
            NSColor(calibratedWhite: 0.0, alpha: 0.62).cgColor
        ]
        vignetteLayer.locations = [0.0, 0.42, 0.72, 1.0]
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        vignetteLayer.opacity = 0
        backdropView.layer?.addSublayer(vignetteLayer)

        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        
        // Forward item selection or handle pagination
        radialMenuView.onItemSelected = { [weak self] item in
            guard let self = self else { return }
            switch item.action {
            case .pageNext:
                self.currentPage += 1
                self.renderCurrentPage(allowCursorWarp: false)
                self.radialMenuView.beginInteractionSession()
            case .pagePrev:
                self.currentPage -= 1
                self.renderCurrentPage(allowCursorWarp: false)
                self.radialMenuView.beginInteractionSession()
            default:
                self.dismissalRequested = true
                self.disableInput()
                self.onItemSelected?(item)
            }
        }
        
        radialMenuView.onDismissRequested = { [weak self] in
            DispatchQueue.main.async {
                self?.requestDismissal()
            }
        }
    }
    
    // MARK: - Show / Hide
    
    func showMenu(at screenPoint: NSPoint, items: [RadialMenuItem], selectedText: String) {
        presentationGeneration &+= 1
        isDismissing = false
        dismissalRequested = false
        ignoresMouseEvents = false
        radialMenuView.beginInteractionSession()
        self.allItems = items
        self.currentSelectedText = selectedText
        self.currentScreenPoint = screenPoint
        self.currentPage = 0
        
        // Read opacity FIRST so views receive right alpha on creation
        let backdropEnabled = UserDefaults.standard.object(forKey: Self.wheelBackdropEnabledKey) as? Bool ?? true
        let targetAlpha = backdropEnabled ? 1.0 : (UserDefaults.standard.object(forKey: "ringOpacity") as? Double ?? 0.25)
        radialMenuView.windowBaseAlpha = CGFloat(targetAlpha)
        radialMenuView.isGTAModeEnabled = backdropEnabled
        let backdropTargetAlpha = backdropEnabled ? max(0.38, min(CGFloat(targetAlpha) * 2.35, 0.94)) : 0
        
        // Show with animation first time
        setupDismissMonitors()
        alphaValue = 1
        backdropView.alphaValue = 0
        visualEffectView.alphaValue = backdropEnabled ? 0 : radialMenuView.windowBaseAlpha
        orderFront(nil)
        
        renderCurrentPage(allowCursorWarp: true)

        if backdropEnabled {
            suppressVisualEffectImmediateAlphaUpdate = true
            visualEffectView.alphaValue = 0
        }
        
        AnimationHelper.showAnimation(for: radialMenuView)
        
        if backdropEnabled {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.22, 1.0)
                self.backdropView.animator().alphaValue = backdropTargetAlpha
            })
            animateGTAVignette()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                guard self.isVisible else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.84, 0.24, 1.0)
                    self.visualEffectView.animator().alphaValue = self.radialMenuView.windowBaseAlpha
                }, completionHandler: {
                    Task { @MainActor [weak self] in
                        self?.suppressVisualEffectImmediateAlphaUpdate = false
                    }
                })
            }
        }
    }
    
    private func renderCurrentPage(allowCursorWarp: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.0
        
        defer { NSAnimationContext.endGrouping() }
        
        let storedPageSize = UserDefaults.standard.integer(forKey: "maxRadialMenuItems")
        let pageSize = Self.validatedPageSize(storedPageSize)
        
        var pageItems: [RadialMenuItem] = []
        
        if allItems.count <= pageSize {
            pageItems = allItems
        } else {
            let isFirstPage = currentPage == 0
            let startIndex = currentPage == 0 ? 0 : (pageSize - 1) + (currentPage - 1) * (pageSize - 2)
            let capacity = currentPage == 0 ? (pageSize - 1) : (pageSize - 2)
            let endIndex = min(startIndex + capacity, allItems.count)
            let isLastPage = endIndex == allItems.count
            
            if !isFirstPage {
                pageItems.append(RadialMenuItem(title: "Previous".localized, iconName: "arrow.uturn.backward", action: .pagePrev))
            }
            
            pageItems.append(contentsOf: allItems[startIndex..<endIndex])
            
            if !isLastPage {
                pageItems.append(RadialMenuItem(title: "Next".localized, iconName: "arrow.uturn.forward", action: .pageNext))
            }
        }
        
        radialMenuView.menuItems = pageItems
        radialMenuView.selectedText = currentSelectedText
        
        let menuSize = radialMenuView.menuDiameter
        let radius = menuSize / 2
        
        // Find screen
        let screen = NSScreen.screens.first(where: { $0.frame.contains(currentScreenPoint) }) ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return }
        let useFullscreenWindow = radialMenuView.isGTAModeEnabled
        
        let targetWindowFrame: NSRect
        if useFullscreenWindow {
            targetWindowFrame = screenFrame
        } else {
            let compactSize = NSSize(width: menuSize + compactWindowPadding * 2, height: menuSize + compactWindowPadding * 2)
            var compactOrigin = NSPoint(
                x: currentScreenPoint.x - radius - compactWindowPadding,
                y: currentScreenPoint.y - radius - compactWindowPadding
            )
            compactOrigin.x = max(screenFrame.minX, min(compactOrigin.x, screenFrame.maxX - compactSize.width))
            compactOrigin.y = max(screenFrame.minY, min(compactOrigin.y, screenFrame.maxY - compactSize.height))
            targetWindowFrame = NSRect(origin: compactOrigin, size: compactSize)
        }
        
        if lastScreenFrame != targetWindowFrame {
            self.setFrame(targetWindowFrame, display: true)
            lastScreenFrame = targetWindowFrame
        }
        
        let windowContentSize = targetWindowFrame.size
        let cv = contentView ?? NSView(frame: NSRect(origin: .zero, size: windowContentSize))
        if cv.frame != NSRect(origin: .zero, size: windowContentSize) {
            cv.frame = NSRect(origin: .zero, size: windowContentSize)
        }
        cv.wantsLayer = true
        backdropView.frame = cv.bounds
        (backdropView.layer as? CAGradientLayer)?.frame = backdropView.bounds
        vignetteLayer.frame = backdropView.bounds
        backdropView.isHidden = !useFullscreenWindow

        // Calculate tracking center (mouse position relative to the full window)
        let localScreenPoint: NSPoint
        if useFullscreenWindow {
            localScreenPoint = cv.convert(self.convertPoint(fromScreen: currentScreenPoint), from: nil)
        } else {
            localScreenPoint = NSPoint(
                x: currentScreenPoint.x - targetWindowFrame.minX,
                y: currentScreenPoint.y - targetWindowFrame.minY
            )
        }

        // Calculate visual center (clamped so the menu ring stays on screen)
        var vCenter = localScreenPoint
        let paddingHorizontal: CGFloat = 24
        let paddingBottom: CGFloat = 24
        let paddingTop: CGFloat = useFullscreenWindow ? 50 : 24
        
        if vCenter.x - radius < paddingHorizontal { vCenter.x = paddingHorizontal + radius }
        if vCenter.x + radius > cv.bounds.width - paddingHorizontal { vCenter.x = cv.bounds.width - paddingHorizontal - radius }
        if vCenter.y - radius < paddingBottom { vCenter.y = paddingBottom + radius }
        if vCenter.y + radius > cv.bounds.height - paddingTop { vCenter.y = cv.bounds.height - paddingTop - radius }

        // Check if we needed to clamp
        let didClamp = vCenter != localScreenPoint
        
        if didClamp && allowCursorWarp {
            // If the menu was clamped to stay on screen, warp the physical mouse cursor
            // to the new visual center. This ensures the cursor stays exactly in the 
            // middle of the radial menu, preserving the 1:1 aiming feel.
            let newGlobalPoint: NSPoint
            if useFullscreenWindow {
                newGlobalPoint = self.convertPoint(toScreen: cv.convert(vCenter, to: nil))
            } else {
                newGlobalPoint = NSPoint(x: targetWindowFrame.minX + vCenter.x, y: targetWindowFrame.minY + vCenter.y)
            }
            if let cgPoint = AccessibilityManager.coreGraphicsScreenPoint(for: newGlobalPoint) {
                CGWarpMouseCursorPosition(cgPoint)
            }
        }
        
        // Both visual and tracking center are now the clamped position
        radialMenuView.trackingCenter = vCenter
        radialMenuView.visualCenter = vCenter
        radialMenuView.frame = cv.bounds
        
        // Set anchorPoint to visualCenter so that scale animations spring from the menu core
        if let rmLayer = radialMenuView.layer, cv.bounds.width > 0, cv.bounds.height > 0 {
            let relX = vCenter.x / cv.bounds.width
            let relY = vCenter.y / cv.bounds.height
            rmLayer.anchorPoint = CGPoint(x: relX, y: relY)
            rmLayer.position = vCenter
        }
        
        if backdropView.superview == nil {
            cv.addSubview(backdropView)
        }
        
        // Visual effect background for frosted glass look
        let visualFrame = NSRect(x: vCenter.x - radius, y: vCenter.y - radius, width: menuSize, height: menuSize)
        visualEffectView.frame = visualFrame
        visualEffectView.material = radialMenuView.isGTAModeEnabled ? .hudWindow : .popover
        visualEffectView.blendingMode = radialMenuView.isGTAModeEnabled ? .behindWindow : .withinWindow
        visualEffectView.layer?.cornerRadius = radius
        visualEffectView.layer?.masksToBounds = true
        if !visualEffectView.isHidden && !suppressVisualEffectImmediateAlphaUpdate {
            visualEffectView.alphaValue = radialMenuView.windowBaseAlpha
        }
        self.hasShadow = radialMenuView.isGTAModeEnabled
        
        // *The visual effect mask will now be dynamically applied by RadialMenuView.buildMenu()*
        
        if visualEffectView.superview == nil {
            cv.addSubview(visualEffectView)
        }
        
        if radialMenuView.superview == nil {
            cv.addSubview(radialMenuView)
        }
        
        if self.contentView !== cv {
            self.contentView = cv
        }
        
        // Build the visual layers
        radialMenuView.buildMenu()
    }
    
    func hideMenu(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        disableInput()
        let hidingGeneration = presentationGeneration

        if radialMenuView.isGTAModeEnabled {
            suppressVisualEffectImmediateAlphaUpdate = false
            vignetteLayer.removeAllAnimations()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.backdropView.animator().alphaValue = 0
                self.visualEffectView.animator().alphaValue = 0
            })
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            vignetteLayer.opacity = 0
            vignetteLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else {
                        completion?()
                        return
                    }
                    guard self.presentationGeneration == hidingGeneration else {
                        completion?()
                        return
                    }
                    self.orderOut(nil)
                    completion?()
                }
            })
        } else {
            orderOut(nil)
            completion?()
        }
    }

    static func validatedPageSize(_ storedValue: Int) -> Int {
        [6, 8, 12, 16].contains(storedValue) ? storedValue : 12
    }

    func requestDismissal() {
        guard !dismissalRequested else { return }
        dismissalRequested = true
        disableInput()
        if let onDismissRequested {
            onDismissRequested()
        } else {
            hideMenu()
        }
    }

    private func disableInput() {
        ignoresMouseEvents = true
        radialMenuView.endInteractionSession()
        tearDownDismissMonitors()
    }

    // MARK: - Screen positioning

    // (Deprecated: no longer using small window clamping, window matches screen)

    // MARK: - Auto Dismissal

    private var dismissMonitor: Any?
    private var localKeyDownMonitor: Any?
    
    internal func setupDismissMonitors() {
        tearDownDismissMonitors()
        let monitorGeneration = presentationGeneration
        
        // Global monitor for clicks outside our app or scrolling
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == monitorGeneration else { return }
                self.requestDismissal()
            }
        }
        
        // Local monitor to catch ESC key even though we are .nonactivatingPanel
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 /* Esc */ {
                DispatchQueue.main.async {
                    guard let self, self.presentationGeneration == monitorGeneration else { return }
                    self.requestDismissal()
                }
                return nil // Consume Esc
            }
            return event
        }
    }
    
    internal func tearDownDismissMonitors() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
        if let localMonitor = localKeyDownMonitor {
            NSEvent.removeMonitor(localMonitor)
            localKeyDownMonitor = nil
        }
    }
    
    // MARK: - Click outside to dismiss
    
    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        let localPoint = radialMenuView.convert(point, from: nil)
        let center = radialMenuView.trackingCenter
        let dx = localPoint.x - center.x
        let dy = localPoint.y - center.y
        let distanceSquared = dx * dx + dy * dy
        let dismissRadius = radialMenuView.outerRadius + outsideDismissPadding
        let deadzoneSquared = dismissDeadzoneRadius * dismissDeadzoneRadius
        
        // Click far away from tracking center -> dismiss
        // Also click in the absolute deadzone -> dismiss (matching the 10-point view deadzone)
        if distanceSquared > dismissRadius * dismissRadius || distanceSquared < deadzoneSquared {
            requestDismissal()
        }
    }
    
    override var canBecomeKey: Bool { false }
    
    private func animateGTAVignette() {
        vignetteLayer.removeAllAnimations()
        
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.12, 1.0, 1.025, 1.0]
        scale.keyTimes = [0.0, 0.48, 0.78, 1.0]
        scale.duration = 0.34
        scale.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.24, 1.0),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.0, 0.9, 0.72]
        opacity.keyTimes = [0.0, 0.44, 1.0]
        opacity.duration = 0.34
        opacity.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.22, 0.84, 0.24, 1.0),
            CAMediaTimingFunction(name: .easeOut)
        ]
        
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.34
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        vignetteLayer.add(group, forKey: "gtaVignetteReveal")
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vignetteLayer.opacity = 0.72
        vignetteLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}
