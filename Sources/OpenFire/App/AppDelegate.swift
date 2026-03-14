import Cocoa

/// Main application delegate — orchestrates all components
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let radialMenuExcludedPluginIDs: Set<String> = ["com.openfire.builtin.paste"]
    static let deletePluginID = "com.openfire.delete"
    
    private let statusBarController = StatusBarController()
    private var radialMenuWindow: RadialMenuWindow?
    private var isEnabled = true
    private var currentSelectedText: String = ""
    private var observersRegistered = false
    private var isDismissingMenus = false
    private var pendingMenuDismissCompletions: [() -> Void] = []
    private var debugSelectionSequence: UInt64 = 0
    
    // Global monitor for clicking outside
    private var globalClickMonitor: Any?

    static func emptyInputPastePlugin(from plugins: [Plugin], appBundleID: String?) -> Plugin? {
        plugins.first { plugin in
            plugin.id == "com.openfire.builtin.paste" &&
            plugin.isEnabled &&
            PluginManager.shared.isPluginEnabled(plugin.id, forAppBundleID: appBundleID)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Automatically clear stale accessibility permissions if the app was updated
        // This prevents the macOS "permission toggle is on but doesn't work" bug for unsigned apps
        checkAndUpdateAccessibilityState()
        
        // Hide dock icon (backup, Info.plist should handle this)
        NSApp.setActivationPolicy(.accessory)
        
        // Create a standard Edit menu so that ⌘C/⌘V/⌘X/⌘A/⌘Z work in text fields (e.g. PluginEditorWindow)
        // Accessory apps don't have a default menu bar, so keyboard shortcuts won't route without this.
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = {
            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            editMenu.addItem(NSMenuItem.separator())
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            return editMenu
        }()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
        
        // Handle pre-launch document opens (LaunchServices passing args directly)
        for arg in CommandLine.arguments.dropFirst() {
            if arg.hasSuffix(".openfireext") {
                let url = URL(fileURLWithPath: arg)
                _ = installPluginWithConfirmation(from: url)
            }
        }
        
        // Manually intercept AppleEvents for double-clicking documents since UIElement apps sometimes drop them
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(event:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        
        // Setup status bar
        statusBarController.setup()
        isEnabled = statusBarController.currentEnabledState
        statusBarController.onEnabledChanged = { [weak self] enabled in
            self?.setEnabled(enabled)
        }

        // Check for updates in the background after the UI is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if UpdateChecker.shared.isAutoCheckEnabled() {
                UpdateChecker.shared.checkForUpdates()
            }
        }
        
        // Check accessibility permission
        if !AccessibilityManager.shared.ensureAccessibilityPermission() {
            NSLog("[OpenFire] Waiting for accessibility permission...")
            // Poll until permission is granted
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AccessibilityManager.shared.isAccessibilityEnabled {
                    timer.invalidate()
                    self?.startServices()
                }
            }
        } else {
            startServices()
        }
        
        // Load plugins
        PluginManager.shared.loadAllPlugins()
        PluginManager.shared.startWatchingPluginDirectories()
        
        // Setup global hotkeys
        HotkeyManager.shared.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyTriggered()
        }
        HotkeyManager.shared.onToggleHotkeyPressed = { [weak self] in
            self?.statusBarController.toggleEnabled()
        }
        
        if HotkeyManager.shared.hotkey != nil || HotkeyManager.shared.toggleHotkey != nil {
            let issues = HotkeyManager.shared.registerHotkeys()
            for issue in issues {
                NSLog("[OpenFire] Hotkey registration issue: \(issue.message)")
            }
        }
    }
    
    /// Called when the global hotkey is pressed
    private func handleHotkeyTriggered() {
        guard isEnabled else { return }
        
        // Quick check via Accessibility API first
        if let text = AccessibilityManager.shared.getSelectedText(), !text.isEmpty {
            let mouseLocation = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
            self.currentSelectedText = text
            showRadialMenu(at: mouseLocation, text: text)
            return
        }
        AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
        
        // If Accessibility fails, simulate Cmd+C (async to allow physical hotkeys to be released)
        AccessibilityManager.shared.getSelectedTextViaCopy { [weak self] copiedText in
            guard let self = self, let text = copiedText, !text.isEmpty else {
                AccessibilityManager.shared.recordSelectionAttemptFailure(.copyFallbackEmptySelection)
                return
            }
            let mouseLocation = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(source: .copyFallback, text: text)
            self.currentSelectedText = text
            self.showRadialMenu(at: mouseLocation, text: text)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        TextSelectionMonitor.shared.stopMonitoring()
        PluginManager.shared.stopWatchingPluginDirectories()
        HotkeyManager.shared.unregisterHotkeys()
        unregisterServiceObservers()
    }
    
    // MARK: - Handle file opening (plugin installation)
    
    @objc private func handleOpenDocumentsEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        NSLog("[OpenFire] handleOpenDocumentsEvent raw event received")
        if let descriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) {
            let numItems = descriptor.numberOfItems
            let typeFileURL = OSType(0x6675726c) // "furl" type
            
            let processDescriptor: (NSAppleEventDescriptor) -> Void = { desc in
                if let urlDesc = desc.coerce(toDescriptorType: typeFileURL) {
                    let data = urlDesc.data
                    if let urlString = String(data: data, encoding: .utf8),
                       let url = URL(string: urlString) {
                        
                        if url.pathExtension == "openfireext" {
                            _ = self.installPluginWithConfirmation(from: url)
                        }
                    }
                }
            }
            
            if numItems > 0 {
                for i in 1...numItems {
                    if let itemDesc = descriptor.atIndex(i) {
                        processDescriptor(itemDesc)
                    }
                }
            } else {
                processDescriptor(descriptor)
            }
        }
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        NSLog("[OpenFire] application(_:openFile:) called for: \(filename)")
        if url.pathExtension == "openfireext" {
            return installPluginWithConfirmation(from: url)
        }
        return false
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("[OpenFire] application(_:open:urls) called with: \(urls)")
        for url in urls {
            if url.pathExtension == "openfireext" {
                _ = installPluginWithConfirmation(from: url)
            }
        }
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        NSLog("[OpenFire] application(_:openFiles:) called with: \(filenames)")
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if url.pathExtension == "openfireext" {
                _ = installPluginWithConfirmation(from: url)
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    
    private func installPluginWithConfirmation(from url: URL) -> Bool {
        // Try to load the plugin config for preview
        let configURL = url.appendingPathComponent("Config.json")
        var pluginName = url.deletingPathExtension().lastPathComponent
        var pluginDescription = ""
        
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(PluginConfig.self, from: data) {
            pluginName = config.name
            pluginDescription = config.description ?? String(format: "Type: %@".localized, config.action.type.rawValue)
            if Plugin(config: config, directoryURL: url).requiresExecutionTrust {
                pluginDescription += "\n\n" + "Warning: this plugin can execute scripts on your Mac. OpenFire will require explicit trust before the first run, and again after plugin changes.".localized
            }
        }
        
        // Show confirmation alert
        let alert = NSAlert()
        alert.messageText = "Install Plugin".localized
        alert.informativeText = String(format: "Do you want to install plugin '%@'?\n%@".localized, pluginName, pluginDescription)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install".localized)
        alert.addButton(withTitle: "Cancel".localized)
        
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            let success = PluginManager.shared.installPlugin(from: url)
            let resultAlert = NSAlert()
            resultAlert.messageText = success ? "Install Succeeded".localized : "Install Failed".localized
            resultAlert.informativeText = success ? String(format: "Plugin '%@' installed successfully.".localized, pluginName) : String(format: "Failed to copy plugin to installation directory. Check permissions.\n(%@)".localized, url.path)
            resultAlert.alertStyle = success ? .informational : .critical
            resultAlert.runModal()
            return success
        }
        return false
    }
    
    // MARK: - Services
    
    private func startServices() {
        NSLog("[OpenFire] Starting text selection monitoring...")
        if isEnabled {
            TextSelectionMonitor.shared.startMonitoring()
        }
        
        AccessibilityManager.shared.onPermissionLost = { [weak self] in
            self?.showPermissionLostAlert()
        }
        AccessibilityManager.shared.startWatchdog()
        
        // Listen for text selection events
        registerServiceObserversIfNeeded()
    }

    private func registerServiceObserversIfNeeded() {
        guard !observersRegistered else { return }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextSelection(_:)),
            name: TextSelectionMonitor.textSelectedNotification,
            object: nil
        )
        
        // Listen for empty text input clicks (for Paste)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEmptyTextInputClick(_:)),
            name: TextSelectionMonitor.emptyTextInputClickedNotification,
            object: nil
        )
        
        observersRegistered = true
    }
    
    private func unregisterServiceObservers() {
        guard observersRegistered else { return }
        NotificationCenter.default.removeObserver(self, name: TextSelectionMonitor.textSelectedNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: TextSelectionMonitor.emptyTextInputClickedNotification, object: nil)
        observersRegistered = false
    }
    
    private func showPermissionLostAlert() {
        TextSelectionMonitor.shared.stopMonitoring()
        
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Lost".localized
        alert.informativeText = "OpenFire relies on Accessibility to detect text selection. Please re-check OpenFire in 'System Settings -> Privacy & Security -> Accessibility'.".localized
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings".localized)
        alert.addButton(withTitle: "Quit".localized)
        
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            waitAndRecoverPermission()
        } else {
            NSApp.terminate(nil)
        }
    }
    
    private func waitAndRecoverPermission() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AccessibilityManager.shared.isAccessibilityEnabled {
                timer.invalidate()
                self?.startServices()
                
                let alert = NSAlert()
                alert.messageText = "Permission Restored".localized
                alert.informativeText = "OpenFire has resumed working.".localized
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK".localized)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
    
    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            TextSelectionMonitor.shared.startMonitoring()
        } else {
            TextSelectionMonitor.shared.stopMonitoring()
            dismissAllMenus()
        }
    }
    
    // MARK: - Text Selection Handling
    
    private var pastePopupWindow: PastePopupWindow?
    
    // MARK: - Text Selection Handling
    
    @objc private func handleTextSelection(_ notification: Notification) {
        guard isEnabled else { return }
        
        guard let userInfo = notification.userInfo,
              let text = userInfo["text"] as? String,
              let locationValue = userInfo["mouseLocation"] as? NSValue else { return }
        
        let mouseLocation = locationValue.pointValue
        currentSelectedText = text
        
        showRadialMenu(at: mouseLocation, text: text)
    }
    
    @objc private func handleEmptyTextInputClick(_ notification: Notification) {
        guard isEnabled else { return }
        guard let userInfo = notification.userInfo,
              let locationValue = userInfo["mouseLocation"] as? NSValue else { return }
        
        let mouseLocation = locationValue.pointValue
        currentSelectedText = "" // Empty text because nothing is selected
        
        let appBundleID = AccessibilityManager.shared.getFocusedAppBundleID()

        // Find the built-in paste plugin, respecting per-app disable overrides.
        guard let pastePlugin = Self.emptyInputPastePlugin(
            from: PluginManager.shared.plugins,
            appBundleID: appBundleID
        ) else {
            return
        }
        
        // Use the minimal inline paste popup instead of the full radial menu
        showPastePopup(at: mouseLocation, plugin: pastePlugin)
    }
    
    // MARK: - Radial Menu & Popups
    
    private func showRadialMenu(at point: NSPoint, text: String) {
        let appBundleID = AccessibilityManager.shared.getFocusedAppBundleID()
        let availablePlugins = PluginManager.shared.availablePlugins(for: text, appBundleID: appBundleID)
        showRadialMenu(at: point, plugins: Self.radialMenuPlugins(from: availablePlugins))
    }

    static func radialMenuPlugins(from plugins: [Plugin]) -> [Plugin] {
        plugins.filter { !radialMenuExcludedPluginIDs.contains($0.id) }
    }

    static func isPluginExecutable(_ plugin: Plugin, text: String, appBundleID: String?, isSelectionEditable: Bool) -> Bool {
        let matchesContext = plugin.shouldShow(text: text, appBundleID: appBundleID)
        guard matchesContext else { return false }

        if plugin.id == deletePluginID {
            return isSelectionEditable
        }

        return true
    }

    func beginMenuDismiss(completion: (() -> Void)? = nil) -> Bool {
        if let completion {
            pendingMenuDismissCompletions.append(completion)
        }

        guard !isDismissingMenus else { return false }
        isDismissingMenus = true
        return true
    }

    func finishMenuDismiss() {
        let completions = pendingMenuDismissCompletions
        pendingMenuDismissCompletions.removeAll()
        isDismissingMenus = false
        completions.forEach { $0() }
    }
    
    private func showRadialMenu(at point: NSPoint, plugins: [Plugin]) {
        dismissAllMenus()
        
        var items: [RadialMenuItem] = []
        let appBundleID = AccessibilityManager.shared.getFocusedAppBundleID()
        let isSelectionEditable = AccessibilityManager.shared.isFocusedSelectionEditable()
        
        for plugin in plugins {
            items.append(RadialMenuItem(
                title: plugin.name,
                iconName: plugin.iconName,
                action: .plugin(plugin),
                customIcon: plugin.customIcon,
                isExecutable: Self.isPluginExecutable(
                    plugin,
                    text: currentSelectedText,
                    appBundleID: appBundleID,
                    isSelectionEditable: isSelectionEditable
                )
            ))
        }
        
        // Don't show if no items available
        guard !items.isEmpty else { return }
        
        // Create and show the radial menu window
        let window = RadialMenuWindow()
        window.onItemSelected = { [weak self] item in
            guard let self = self else { return }
            self.debugSelectionSequence += 1
            let selectionID = self.debugSelectionSequence
            let actionSummary: String
            switch item.action {
            case .plugin(let plugin):
                actionSummary = "plugin:\(plugin.id)"
            case .builtIn(let action):
                actionSummary = "builtIn:\(String(describing: action))"
            default:
                actionSummary = "other"
            }
            NSLog("[OpenFire-Debug] AppDelegate.onItemSelected selectionID=%llu title=%@ action=%@ textLength=%ld",
                  selectionID,
                  item.title,
                  actionSummary,
                  self.currentSelectedText.count)
            self.handleMenuAction(item, text: self.currentSelectedText)
        }
        window.showMenu(at: point, items: items, selectedText: currentSelectedText)
        
        radialMenuWindow = window
        setupGlobalClickMonitor()
    }
    
    private func showPastePopup(at point: NSPoint, plugin: Plugin) {
        dismissAllMenus()
        
        let window = PastePopupWindow()
        window.onPasteClicked = { [weak self] in
            // Hide the window immediately so the target app can receive the key event
            self?.dismissAllMenus()
            
            // Need a slightly longer delay (e.g. 0.3s) for the OS to properly focus the underlying text field
            // after the click on our popup window is processed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                PluginManager.shared.executePlugin(plugin, with: "")
            }
        }
        
        window.onClearClicked = { [weak self] in
            NSPasteboard.general.clearContents()
            self?.dismissAllMenus()
        }
        
        window.show(at: point)
        pastePopupWindow = window
        setupGlobalClickMonitor()
    }
    
    private func dismissAllMenus(completion: (() -> Void)? = nil) {
        let completionLabel = completion == nil ? "none" : "provided"
        NSLog("[OpenFire-Debug] dismissAllMenus called completion=%@ radialVisible=%@ popupVisible=%@ isDismissing=%@",
              completionLabel,
              radialMenuWindow == nil ? "false" : "true",
              pastePopupWindow == nil ? "false" : "true",
              isDismissingMenus ? "true" : "false")
        guard beginMenuDismiss(completion: completion) else { return }

        let radialWindow = radialMenuWindow
        let popupWindow = pastePopupWindow
        radialMenuWindow = nil
        pastePopupWindow = nil
        removeGlobalClickMonitor()

        let dismissCount = (popupWindow == nil ? 0 : 1) + (radialWindow == nil ? 0 : 1)
        guard dismissCount > 0 else {
            finishMenuDismiss()
            return
        }

        var pendingDismissals = dismissCount
        let finishDismissal: () -> Void = { [weak self] in
            guard pendingDismissals > 0 else { return }
            pendingDismissals -= 1
            if pendingDismissals == 0 {
                self?.finishMenuDismiss()
            }
        }

        if let popupWindow {
            popupWindow.hidePopup(completion: finishDismissal)
        }

        if let radialWindow {
            radialWindow.hideMenu(completion: finishDismissal)
        }
    }
    
    private func handleMenuAction(_ item: RadialMenuItem, text: String) {
        switch item.action {
        case .plugin(let plugin):
            NSLog("[OpenFire-Debug] handleMenuAction plugin=%@ requiresTrust=%@ textLength=%ld",
                  plugin.id,
                  plugin.requiresExecutionTrust ? "true" : "false",
                  text.count)
        case .builtIn(let action):
            NSLog("[OpenFire-Debug] handleMenuAction builtIn=%@ textLength=%ld",
                  String(describing: action),
                  text.count)
        default:
            NSLog("[OpenFire-Debug] handleMenuAction other textLength=%ld", text.count)
        }

        switch item.action {
        case .builtIn(let action):
            ActionExecutor.shared.execute(action: action, text: text)
            dismissAllMenus()
        case .plugin(let plugin):
            if plugin.requiresExecutionTrust {
                dismissAllMenus {
                    NSLog("[OpenFire-Debug] dismissAllMenus completion executing trusted plugin=%@",
                          plugin.id)
                    PluginManager.shared.executePlugin(plugin, with: text)
                }
            } else {
                PluginManager.shared.executePlugin(plugin, with: text)
                dismissAllMenus()
            }
        default:
            dismissAllMenus()
            break
        }
    }
    
    // MARK: - Global Click Monitor
    
    private func setupGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            self?.dismissAllMenus()
        }
    }
    
    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
    
    // MARK: - App Update TCC Reset
    
    private func checkAndUpdateAccessibilityState() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let lastVersion = UserDefaults.standard.string(forKey: "LastRunVersion")
        
        // If this is a new version running for the first time
        if lastVersion != currentVersion {
            NSLog("[OpenFire] App updated from \(lastVersion ?? "none") to \(currentVersion). Resetting TCC permissions.")

            // Mark the new version first so repeated launches do not enqueue duplicate resets.
            // Mark the new version as launched
            UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")

            // Reset asynchronously to avoid blocking app launch on a shell task.
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                task.arguments = ["reset", "Accessibility", "com.openfire.app"]

                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {
                    NSLog("[OpenFire] Failed to reset Accessibility TCC: \(error.localizedDescription)")
                }
            }
        }
    }
}
