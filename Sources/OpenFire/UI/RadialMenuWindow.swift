import Cocoa

/// A floating, borderless panel that hosts the radial menu
final class RadialMenuWindow: NSPanel {
    
    private let radialMenuView: RadialMenuView
    
    var onItemSelected: ((RadialMenuItem) -> Void)?
    
    // Pagination state
    private var allItems: [RadialMenuItem] = []
    private var currentPage: Int = 0
    private var currentSelectedText: String = ""
    private var currentScreenPoint: NSPoint = .zero
    
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
        
        // Forward item selection or handle pagination
        radialMenuView.onItemSelected = { [weak self] item in
            guard let self = self else { return }
            switch item.action {
            case .pageNext:
                self.currentPage += 1
                self.renderCurrentPage()
            case .pagePrev:
                self.currentPage -= 1
                self.renderCurrentPage()
            default:
                self.onItemSelected?(item)
            }
        }
        
        radialMenuView.onDismissRequested = { [weak self] in
            DispatchQueue.main.async {
                self?.hideMenu()
            }
        }
    }
    
    // MARK: - Show / Hide
    
    func showMenu(at screenPoint: NSPoint, items: [RadialMenuItem], selectedText: String) {
        self.allItems = items
        self.currentSelectedText = selectedText
        self.currentScreenPoint = screenPoint
        self.currentPage = 0
        
        // Read opacity FIRST so views receive right alpha on creation
        let targetAlpha = UserDefaults.standard.object(forKey: "ringOpacity") as? Double ?? 0.25
        radialMenuView.windowBaseAlpha = CGFloat(targetAlpha)
        
        // Show with animation first time
        setupDismissMonitors()
        alphaValue = 0
        orderFront(nil)
        
        renderCurrentPage()
        
        AnimationHelper.showAnimation(for: radialMenuView)
        
        // The WINDOW itself fully fades in to 1.0, and the views inside manage their own transparency
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        })
    }
    
    private func renderCurrentPage() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.0
        
        defer { NSAnimationContext.endGrouping() }
        
        let maxItems = UserDefaults.standard.integer(forKey: "maxRadialMenuItems")
        let pageSize = maxItems == 0 ? 12 : maxItems
        
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
        
        // Make the window cover the entire screen
        self.setFrame(screenFrame, display: true)
        
        let cv = contentView ?? NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        cv.frame = NSRect(origin: .zero, size: screenFrame.size)
        cv.wantsLayer = true
        
        // Calculate tracking center (mouse position relative to the full window)
        // convertPoint(fromScreen:) converts global coordinates to window base coordinates
        let localScreenPoint = cv.convert(self.convertPoint(fromScreen: currentScreenPoint), from: nil)
        radialMenuView.trackingCenter = localScreenPoint
        
        // Calculate visual center (clamped so the menu ring stays on screen)
        var vCenter = localScreenPoint
        let paddingHorizontal: CGFloat = 24
        let paddingBottom: CGFloat = 24
        let paddingTop: CGFloat = 50
        
        if vCenter.x - radius < paddingHorizontal { vCenter.x = paddingHorizontal + radius }
        if vCenter.x + radius > cv.bounds.width - paddingHorizontal { vCenter.x = cv.bounds.width - paddingHorizontal - radius }
        if vCenter.y - radius < paddingBottom { vCenter.y = paddingBottom + radius }
        if vCenter.y + radius > cv.bounds.height - paddingTop { vCenter.y = cv.bounds.height - paddingTop - radius }
        
        radialMenuView.visualCenter = vCenter
        radialMenuView.frame = cv.bounds
        
        // Set anchorPoint to visualCenter so that scale animations spring from the menu core
        if let rmLayer = radialMenuView.layer, cv.bounds.width > 0, cv.bounds.height > 0 {
            let relX = vCenter.x / cv.bounds.width
            let relY = vCenter.y / cv.bounds.height
            rmLayer.anchorPoint = CGPoint(x: relX, y: relY)
            rmLayer.position = vCenter
        }
        
        // Visual effect background for frosted glass look
        var visualEffect = cv.subviews.first(where: { $0 is NSVisualEffectView }) as? NSVisualEffectView
        let visualFrame = NSRect(x: vCenter.x - radius, y: vCenter.y - radius, width: menuSize, height: menuSize)
        
        if visualEffect == nil {
            visualEffect = NSVisualEffectView(frame: visualFrame)
            visualEffect?.material = .hudWindow
            visualEffect?.state = .active
            visualEffect?.blendingMode = .behindWindow
            visualEffect?.wantsLayer = true
        } else {
            visualEffect?.frame = visualFrame
        }
        
        visualEffect?.layer?.cornerRadius = radius
        visualEffect?.layer?.masksToBounds = true
        visualEffect?.alphaValue = radialMenuView.windowBaseAlpha
        
        // *The visual effect mask will now be dynamically applied by RadialMenuView.buildMenu()*
        
        if visualEffect?.superview == nil, let ve = visualEffect {
            cv.addSubview(ve)
        }
        
        if radialMenuView.superview == nil {
            cv.addSubview(radialMenuView)
        }
        
        self.contentView = cv
        
        // Build the visual layers
        radialMenuView.buildMenu()
    }
    
    func hideMenu(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.tearDownDismissMonitors()
            self?.orderOut(nil)
            completion?()
        })
    }
    
    // MARK: - Screen positioning
    
    // MARK: - Screen positioning
    
    // (Deprecated: no longer using small window clamping, window matches screen)
    
    // MARK: - Auto Dismissal
    
    private var dismissMonitor: Any?
    private var localKeyDownMonitor: Any?
    
    internal func setupDismissMonitors() {
        tearDownDismissMonitors()
        
        // Global monitor for clicks outside our app or scrolling
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            DispatchQueue.main.async {
                self?.hideMenu()
            }
        }
        
        // Local monitor to catch ESC key even though we are .nonactivatingPanel
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 /* Esc */ {
                DispatchQueue.main.async {
                    self?.hideMenu()
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
        let distance = sqrt(dx * dx + dy * dy)
        
        // Click far away from tracking center -> dismiss
        // Also click in the absolute deadzone -> dismiss (matching the 10-point view deadzone)
        if distance > radialMenuView.outerRadius + 150 || distance < 10 {
            hideMenu()
        }
    }
    
    override var canBecomeKey: Bool { false }
}
