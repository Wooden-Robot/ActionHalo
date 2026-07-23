import Cocoa

/// Main application delegate — orchestrates all components
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let cutPluginID = "com.openfire.cut"
    static let deletePluginID = "com.openfire.delete"
    static let pastePluginID = "com.openfire.builtin.paste"
    static let menuDismissEventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
    static let resetAccessibilityOnUpdateKey = "ResetAccessibilityPermissionsOnUpdate"
    static let lastAccessibilityResetVersionKey = "LastAccessibilityResetVersion"
    static let excludedAppsDefaultsKey = AppExclusionStore.defaultsKey
    static let defaultOfficeSuiteExcludedAppsMigrationKey = "DefaultOfficeAppsExcludedMigrationVersion"
    static let defaultOfficeSuiteExcludedAppsMigrationVersion = 1
    static let defaultOfficeSuiteExcludedApps: [String] = [
        "com.apple.Pages",
        "com.apple.Numbers",
        "com.apple.Keynote",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.kingsoft.wpsoffice.mac"
    ]
    
    private let statusBarController = StatusBarController()
    private var radialMenuWindow: RadialMenuWindow?
    private var isEnabled = true
    private var currentSelectedText: String = ""
    private var observersRegistered = false
    private var isDismissingMenus = false
    private var pendingMenuDismissCompletions: [() -> Void] = []
    private var debugSelectionSequence: UInt64 = 0
    private var permissionRecoveryTimer: Timer?
    private let pluginInstallQueue = DispatchQueue(
        label: "com.openfire.plugin-install",
        qos: .userInitiated
    )
    private var pendingPluginInstallPaths: Set<String> = []
    
    // Global monitor for clicking outside
    private var globalClickMonitor: Any?

    static func monitoringStartFailureMessage(_ failure: TextSelectionMonitor.MonitoringStartFailure) -> String {
        switch failure {
        case .accessibilityPermissionMissing:
            return "OpenFire does not currently have Accessibility permission. Please re-check OpenFire in System Settings.".localized
        case .eventTapCreationFailed:
            return "OpenFire could not start the text selection monitor. If Accessibility is already enabled but OpenFire still does not respond, reset the permission record and re-check OpenFire in System Settings.".localized
        }
    }

    static func shouldOfferAccessibilityPermissionReset(for failure: TextSelectionMonitor.MonitoringStartFailure) -> Bool {
        failure == .eventTapCreationFailed
    }

    static func accessibilityResetArguments(bundleIdentifier: String = "com.openfire.app") -> [String] {
        ["reset", "Accessibility", bundleIdentifier]
    }

    static func runProcess(_ process: Process, timeout: TimeInterval) throws -> Int32? {
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        try process.run()
        guard completion.wait(timeout: .now() + max(0, timeout)) == .timedOut else {
            return process.terminationStatus
        }

        if process.isRunning {
            process.terminate()
            _ = completion.wait(timeout: .now() + 0.5)
        }
        return nil
    }

    static func emptyInputPastePlugin(from plugins: [Plugin], appBundleID: String?) -> Plugin? {
        plugins.first { plugin in
            plugin.id == pastePluginID &&
            plugin.isEnabled &&
            PluginManager.shared.isPluginEnabled(plugin.id, forAppBundleID: appBundleID) &&
            plugin.shouldShow(text: "", appBundleID: appBundleID)
        }
    }

    static func shouldAllowMenuPresentation(
        isEnabled: Bool,
        frontmostBundleID: String?,
        frontmostLocalizedName: String?,
        isFocusedSelectionEditable: Bool,
        isAppExcluded: (String) -> Bool = { AppExclusionStore.isExcluded($0) }
    ) -> Bool {
        guard isEnabled else { return false }

        if TextSelectionMonitor.shouldSuppressForFrontmostApp(
            bundleID: frontmostBundleID,
            localizedName: frontmostLocalizedName,
            isFocusedSelectionEditable: isFocusedSelectionEditable
        ) {
            return false
        }

        if let frontmostBundleID, isAppExcluded(frontmostBundleID) {
            return false
        }

        return true
    }

    static func shouldResetAccessibilityPermissionsOnVersionChange(
        lastVersion: String?,
        currentVersion: String,
        resetOptInEnabled: Bool,
        hasAccessibilityPermission: Bool,
        lastResetVersion: String? = nil
    ) -> Bool {
        guard lastResetVersion != currentVersion else { return false }
        guard hasAccessibilityPermission else { return true }

        if resetOptInEnabled {
            guard let lastVersion, !lastVersion.isEmpty else { return true }
            return lastVersion != currentVersion
        }

        return false
    }

    static func migratedExcludedApps(
        existingExcludedApps: [String],
        storedMigrationVersion: Int
    ) -> (apps: [String], newMigrationVersion: Int) {
        guard storedMigrationVersion < defaultOfficeSuiteExcludedAppsMigrationVersion else {
            return (existingExcludedApps, storedMigrationVersion)
        }

        var mergedApps = existingExcludedApps
        for bundleID in defaultOfficeSuiteExcludedApps where !mergedApps.contains(bundleID) {
            mergedApps.append(bundleID)
        }

        return (mergedApps, defaultOfficeSuiteExcludedAppsMigrationVersion)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Automatically clear stale accessibility permissions if the app was updated
        // This prevents the macOS "permission toggle is on but doesn't work" bug for unsigned apps
        checkAndUpdateAccessibilityState()
        applyDefaultOfficeSuiteExcludedAppsMigrationIfNeeded()
        
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

    private func applyDefaultOfficeSuiteExcludedAppsMigrationIfNeeded(userDefaults: UserDefaults = .standard) {
        let existingExcludedApps = AppExclusionStore.excludedApps(userDefaults: userDefaults)
        let storedMigrationVersion = userDefaults.integer(forKey: Self.defaultOfficeSuiteExcludedAppsMigrationKey)
        let migrated = Self.migratedExcludedApps(
            existingExcludedApps: existingExcludedApps,
            storedMigrationVersion: storedMigrationVersion
        )

        guard migrated.newMigrationVersion != storedMigrationVersion else {
            return
        }

        AppExclusionStore.setExcludedApps(migrated.apps, userDefaults: userDefaults)
        userDefaults.set(migrated.newMigrationVersion, forKey: Self.defaultOfficeSuiteExcludedAppsMigrationKey)
    }
    
    /// Called when the global hotkey is pressed
    private func handleHotkeyTriggered() {
        let expectedProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard currentContextAllowsMenuPresentation(
            expectedProcessIdentifier: expectedProcessIdentifier
        ) else {
            return
        }
        AccessibilityManager.shared.cancelActiveSelectedTextViaCopy()

        // Quick check via Accessibility API first
        if let text = AccessibilityManager.shared.getSelectedText(), !text.isEmpty {
            let mouseLocation = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(source: .accessibility, text: text)
            self.currentSelectedText = text
            showRadialMenu(
                at: mouseLocation,
                text: text,
                targetProcessIdentifier: expectedProcessIdentifier
            )
            return
        }
        AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
        
        // If Accessibility fails, simulate Cmd+C (async to allow physical hotkeys to be released)
        AccessibilityManager.shared.getSelectedTextViaCopy(
            expectedProcessIdentifier: expectedProcessIdentifier
        ) { [weak self] copiedText in
            guard AccessibilityManager.isExpectedCopyFallbackProcess(
                expectedProcessIdentifier: expectedProcessIdentifier,
                currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ) else {
                return
            }
            guard let self = self, let text = copiedText, !text.isEmpty else {
                AccessibilityManager.shared.recordSelectionAttemptFailure(.copyFallbackEmptySelection)
                return
            }
            guard self.currentContextAllowsMenuPresentation(
                expectedProcessIdentifier: expectedProcessIdentifier
            ) else {
                return
            }
            let mouseLocation = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(source: .copyFallback, text: text)
            self.currentSelectedText = text
            self.showRadialMenu(
                at: mouseLocation,
                text: text,
                targetProcessIdentifier: expectedProcessIdentifier
            )
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        TextSelectionMonitor.shared.stopMonitoring()
        PluginManager.shared.stopWatchingPluginDirectories()
        HotkeyManager.shared.unregisterHotkeys()
        unregisterServiceObservers()
        permissionRecoveryTimer?.invalidate()
        permissionRecoveryTimer = nil
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
        let installPath = url.standardizedFileURL.path
        if pendingPluginInstallPaths.contains(installPath) {
            return true
        }

        // Try to load the plugin config for preview
        var pluginName = url.deletingPathExtension().lastPathComponent
        var pluginDescription = ""
        
        if let previewPlugin = PluginLoader.load(from: url) {
            let config = previewPlugin.config
            pluginName = config.name
            pluginDescription = config.description ?? String(format: "Type: %@".localized, config.action.type.rawValue)
            if previewPlugin.requiresExecutionTrust {
                pluginDescription += "\n\n" + "Warning: this plugin can perform protected actions on your Mac. OpenFire will require explicit trust before the first run, and again after plugin changes.".localized
            }
        }
        
        // Show confirmation alert
        let alert = NSAlert()
        alert.messageText = "Install Plugin".localized
        let informativeText: String
        if pluginDescription.isEmpty {
            informativeText = String(format: "Do you want to install plugin '%@'?".localized, pluginName)
        } else {
            informativeText = String(format: "Do you want to install plugin '%@'?\n%@".localized, pluginName, pluginDescription)
        }
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install".localized)
        alert.addButton(withTitle: "Cancel".localized)

        NSApp.activate(ignoringOtherApps: true)
        let installingPluginName = pluginName

        if alert.runModal() == .alertFirstButtonReturn {
            pendingPluginInstallPaths.insert(installPath)
            statusBarController.showTemporaryStatusMessage(
                String(format: "Installing %@".localized, installingPluginName)
            )

            let accessGranted = url.startAccessingSecurityScopedResource()
            pluginInstallQueue.async { [weak self] in
                let installResult = PluginManager.shared.installPluginDetailed(from: url)
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingPluginInstallPaths.remove(installPath)

                    guard !installResult.isSuccess else {
                        NSLog("[OpenFire] Plugin '%@' installed successfully.", installingPluginName)
                        self.statusBarController.showTemporaryStatusMessage(
                            String(format: "Installed %@".localized, installingPluginName)
                        )
                        return
                    }

                    let resultAlert = NSAlert()
                    resultAlert.messageText = "Install Failed".localized
                    if case .failed(let failure) = installResult {
                        resultAlert.informativeText = failure.localizedMessage(sourcePath: url.path)
                    }
                    resultAlert.alertStyle = .critical
                    resultAlert.runModal()
                }
            }
            return true
        }
        return false
    }
    
    // MARK: - Services
    
    private func startServices() {
        NSLog("[OpenFire] Starting text selection monitoring...")
        permissionRecoveryTimer?.invalidate()
        permissionRecoveryTimer = nil
        if isEnabled {
            startTextSelectionMonitoringWithFeedback()
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

    private func startTextSelectionMonitoringWithFeedback() {
        guard !TextSelectionMonitor.shared.startMonitoring(),
              let failure = TextSelectionMonitor.shared.lastMonitoringStartFailure else {
            return
        }

        showMonitoringStartFailureAlert(failure)
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

    private func showMonitoringStartFailureAlert(_ failure: TextSelectionMonitor.MonitoringStartFailure) {
        let alert = NSAlert()
        alert.messageText = "Text Selection Monitor Failed to Start".localized
        alert.informativeText = Self.monitoringStartFailureMessage(failure)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings".localized)
        if Self.shouldOfferAccessibilityPermissionReset(for: failure) {
            alert.addButton(withTitle: "Reset Permission".localized)
        }
        alert.addButton(withTitle: "OK".localized)

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if Self.shouldOfferAccessibilityPermissionReset(for: failure),
                  response == .alertSecondButtonReturn {
            resetAccessibilityPermissions()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private func waitAndRecoverPermission() {
        guard permissionRecoveryTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AccessibilityManager.shared.isAccessibilityEnabled {
                timer.invalidate()
                self?.permissionRecoveryTimer = nil
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
        permissionRecoveryTimer = timer
    }
    
    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            startTextSelectionMonitoringWithFeedback()
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
              let locationValue = userInfo["mouseLocation"] as? NSValue,
              let processNumber = userInfo["processIdentifier"] as? NSNumber else {
            return
        }
        let processIdentifier = pid_t(processNumber.int32Value)
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: processIdentifier,
            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) else {
            return
        }
        
        let mouseLocation = locationValue.pointValue
        currentSelectedText = text
        
        showRadialMenu(
            at: mouseLocation,
            text: text,
            targetProcessIdentifier: processIdentifier
        )
    }
    
    @objc private func handleEmptyTextInputClick(_ notification: Notification) {
        guard isEnabled else { return }
        guard let userInfo = notification.userInfo,
              let locationValue = userInfo["mouseLocation"] as? NSValue,
              let processNumber = userInfo["processIdentifier"] as? NSNumber else {
            return
        }
        let processIdentifier = pid_t(processNumber.int32Value)

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: processIdentifier,
            currentProcessIdentifier: frontmostApp?.processIdentifier
        ) else {
            return
        }
        guard Self.shouldAllowMenuPresentation(
            isEnabled: isEnabled,
            frontmostBundleID: frontmostApp?.bundleIdentifier,
            frontmostLocalizedName: frontmostApp?.localizedName,
            isFocusedSelectionEditable: false
        ) else {
            return
        }
        
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
        showPastePopup(
            at: mouseLocation,
            plugin: pastePlugin,
            targetProcessIdentifier: processIdentifier
        )
    }
    
    // MARK: - Radial Menu & Popups
    
    private func showRadialMenu(
        at point: NSPoint,
        text: String,
        targetProcessIdentifier: pid_t?
    ) {
        guard currentContextAllowsMenuPresentation(
            expectedProcessIdentifier: targetProcessIdentifier
        ) else {
            return
        }

        let appBundleID = AccessibilityManager.shared.getFocusedAppBundleID()
        let presentationPlugins = PluginManager.shared.presentationPlugins(appBundleID: appBundleID)
        showRadialMenu(
            at: point,
            plugins: Self.radialMenuPlugins(from: presentationPlugins),
            selectedText: text,
            targetProcessIdentifier: targetProcessIdentifier
        )
    }

    private func currentContextAllowsMenuPresentation(
        expectedProcessIdentifier: pid_t? = nil
    ) -> Bool {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if expectedProcessIdentifier != nil,
           !AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: frontmostApp?.processIdentifier
           ) {
            return false
        }
        return Self.shouldAllowMenuPresentation(
            isEnabled: isEnabled,
            frontmostBundleID: frontmostApp?.bundleIdentifier,
            frontmostLocalizedName: frontmostApp?.localizedName,
            isFocusedSelectionEditable: AccessibilityManager.shared.isFocusedSelectionEditable()
        )
    }

    static func radialMenuPlugins(from plugins: [Plugin]) -> [Plugin] {
        plugins
    }

    static func isPluginExecutable(_ plugin: Plugin, text: String, appBundleID: String?, isSelectionEditable: Bool) -> Bool {
        let matchesContext = plugin.shouldShow(text: text, appBundleID: appBundleID)
        guard matchesContext else { return false }

        if plugin.id == cutPluginID || plugin.id == deletePluginID {
            return isSelectionEditable
        }

        if plugin.id == pastePluginID {
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
    
    private func showRadialMenu(
        at point: NSPoint,
        plugins: [Plugin],
        selectedText: String,
        targetProcessIdentifier: pid_t?
    ) {
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
                    text: selectedText,
                    appBundleID: appBundleID,
                    isSelectionEditable: isSelectionEditable
                )
            ))
        }
        
        // Don't show if no items available
        guard !items.isEmpty else { return }
        
        // Create and show the radial menu window
        let window = RadialMenuWindow()
        window.onDismissRequested = { [weak self] in
            self?.dismissAllMenus()
        }
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
                  selectedText.count)
            self.handleMenuAction(
                item,
                text: selectedText,
                targetProcessIdentifier: targetProcessIdentifier
            )
        }
        window.showMenu(at: point, items: items, selectedText: selectedText)
        
        radialMenuWindow = window
        setupGlobalClickMonitor()
    }
    
    private func showPastePopup(
        at point: NSPoint,
        plugin: Plugin,
        targetProcessIdentifier: pid_t
    ) {
        dismissAllMenus()
        
        let window = PastePopupWindow()
        window.onPasteClicked = { [weak self] in
            guard let self else { return }
            self.dismissAllMenus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard AccessibilityManager.isExpectedCopyFallbackProcess(
                        expectedProcessIdentifier: targetProcessIdentifier,
                        currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
                    ) else {
                        NSLog("[OpenFire] Paste cancelled because the target application changed.")
                        return
                    }
                    PluginManager.shared.executePlugin(
                        plugin,
                        with: "",
                        targetProcessIdentifier: targetProcessIdentifier
                    )
                }
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
    
    private func handleMenuAction(
        _ item: RadialMenuItem,
        text: String,
        targetProcessIdentifier: pid_t?
    ) {
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
            ActionExecutor.shared.execute(
                action: action,
                text: text,
                targetProcessIdentifier: targetProcessIdentifier
            )
            dismissAllMenus()
        case .plugin(let plugin):
            if plugin.requiresExecutionTrust {
                dismissAllMenus {
                    NSLog("[OpenFire-Debug] dismissAllMenus completion executing trusted plugin=%@",
                          plugin.id)
                    PluginManager.shared.executePlugin(
                        plugin,
                        with: text,
                        targetProcessIdentifier: targetProcessIdentifier
                    )
                }
            } else {
                PluginManager.shared.executePlugin(
                    plugin,
                    with: text,
                    targetProcessIdentifier: targetProcessIdentifier
                )
                dismissAllMenus()
            }
        default:
            dismissAllMenus()
            break
        }
    }
    
    // MARK: - Global Click Monitor
    
    private func setupGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.menuDismissEventMask) { [weak self] _ in
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
        let lastResetVersion = UserDefaults.standard.string(forKey: Self.lastAccessibilityResetVersionKey)

        let resetOptInEnabled = UserDefaults.standard.bool(forKey: Self.resetAccessibilityOnUpdateKey)
        guard Self.shouldResetAccessibilityPermissionsOnVersionChange(
            lastVersion: lastVersion,
            currentVersion: currentVersion,
            resetOptInEnabled: resetOptInEnabled,
            hasAccessibilityPermission: AccessibilityManager.shared.isAccessibilityEnabled,
            lastResetVersion: lastResetVersion
        ) else {
            if lastVersion != currentVersion {
                UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")
            }
            NSLog("[OpenFire] App version changed from \(lastVersion ?? "none") to \(currentVersion). Keeping Accessibility permissions untouched.")
            return
        }

        NSLog("[OpenFire] App updated from \(lastVersion ?? "none") to \(currentVersion). Resetting TCC permissions before prompting so stale Accessibility entries do not mislead the user.")

        if resetAccessibilityPermissions() {
            UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")
        }
    }

    @discardableResult
    private func resetAccessibilityPermissions() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = Self.accessibilityResetArguments(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.openfire.app"
        )

        do {
            guard let terminationStatus = try Self.runProcess(task, timeout: 3) else {
                NSLog("[OpenFire] Failed to reset Accessibility TCC: tccutil timed out.")
                return false
            }
            guard terminationStatus == 0 else {
                NSLog("[OpenFire] Failed to reset Accessibility TCC: tccutil exited with status \(terminationStatus)")
                return false
            }
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            UserDefaults.standard.set(currentVersion, forKey: Self.lastAccessibilityResetVersionKey)
            return true
        } catch {
            NSLog("[OpenFire] Failed to reset Accessibility TCC: \(error.localizedDescription)")
            return false
        }
    }
}
