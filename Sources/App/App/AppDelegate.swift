import Cocoa

/// Main-thread interaction gate used by transient UI surfaces.
///
/// Mouse-up events, button actions, and animation callbacks may be delivered
/// again while a panel is fading out. Consuming this gate before dispatching an
/// action keeps destructive and external operations single-shot.
final class SingleFireActionGate {
    private(set) var hasFired = false

    func consume() -> Bool {
        guard !hasFired else { return false }
        hasFired = true
        return true
    }

    func reset() {
        hasFired = false
    }
}

@MainActor
private final class MenuDismissalBarrier {
    private var remainingCount: Int
    private let completion: @MainActor @Sendable () -> Void

    init(count: Int, completion: @escaping @MainActor @Sendable () -> Void) {
        remainingCount = count
        self.completion = completion
    }

    func completeOne() {
        guard remainingCount > 0 else { return }
        remainingCount -= 1
        if remainingCount == 0 {
            completion()
        }
    }
}

/// Main application delegate — orchestrates all components
@MainActor
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
    private var pendingMenuPresentation: (() -> Void)?
    private let menuActionGate = SingleFireActionGate()
    private var startupPermissionTimer: Timer?
    private var permissionRecoveryTimer: Timer?
    private let pluginInstallQueue = DispatchQueue(
        label: "com.openfire.plugin-install",
        qos: .userInitiated
    )
    private var pendingPluginInstallPaths: Set<String> = []
    
    // Global monitor for clicking outside
    private var globalClickMonitor: Any?
    private var globalClickMonitorGeneration: UInt64 = 0

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
            startupPermissionTimer = Timer.scheduledTimer(
                withTimeInterval: 2.0,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AccessibilityManager.shared.isAccessibilityEnabled else {
                        return
                    }
                    self.startupPermissionTimer?.invalidate()
                    self.startupPermissionTimer = nil
                    self.startServices()
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
        startupPermissionTimer?.invalidate()
        startupPermissionTimer = nil
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

        guard let preview = PluginManager.shared.makeInstallPreview(from: url) else {
            let alert = NSAlert()
            alert.messageText = "Install Failed".localized
            alert.informativeText = PluginManager.PluginInstallFailure.invalidPackage.localizedMessage(
                sourcePath: url.path
            )
            alert.alertStyle = .critical
            alert.runModal()
            return false
        }

        let pluginName = preview.name
        var pluginDescription = preview.description ??
            String(format: "Type: %@".localized, preview.actionType.rawValue)
        if preview.requiresExecutionTrust {
            pluginDescription += "\n\n" + "Warning: this plugin can perform protected actions on your Mac. OpenFire will require explicit trust before the first run, and again after plugin changes.".localized
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

            let handleInstallResult: @MainActor @Sendable (PluginManager.PluginInstallResult) -> Void = {
                [weak self] installResult in
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

            pluginInstallQueue.async {
                let installResult = PluginManager.shared.installPluginDetailed(
                    from: url,
                    expectedPreviewFingerprint: preview.fingerprint
                )

                Task { @MainActor in
                    handleInstallResult(installResult)
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

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AccessibilityManager.shared.isAccessibilityEnabled else {
                    return
                }
                self.permissionRecoveryTimer?.invalidate()
                self.permissionRecoveryTimer = nil
                self.startServices()

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
        guard !isDismissingMenus else { return false }
        isDismissingMenus = true
        if let completion {
            pendingMenuDismissCompletions.append(completion)
        }
        return true
    }

    func finishMenuDismiss() {
        guard isDismissingMenus else { return }
        let completions = pendingMenuDismissCompletions
        pendingMenuDismissCompletions.removeAll()
        isDismissingMenus = false
        completions.forEach { $0() }
        presentPendingMenuIfNeeded()
    }
    
    private func showRadialMenu(
        at point: NSPoint,
        plugins: [Plugin],
        selectedText: String,
        targetProcessIdentifier: pid_t?
    ) {
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

        scheduleMenuPresentation { [weak self] in
            guard let self else { return }
            guard self.currentContextAllowsMenuPresentation(
                expectedProcessIdentifier: targetProcessIdentifier
            ) else {
                return
            }

            let window = RadialMenuWindow()
            window.onDismissRequested = { [weak self] in
                self?.dismissAllMenus()
            }
            window.onItemSelected = { [weak self] item in
                guard let self, self.menuActionGate.consume() else { return }
                self.handleMenuAction(
                    item,
                    text: selectedText,
                    targetProcessIdentifier: targetProcessIdentifier
                )
            }
            self.menuActionGate.reset()
            window.showMenu(at: point, items: items, selectedText: selectedText)

            self.radialMenuWindow = window
            self.setupGlobalClickMonitor()
        }
    }
    
    private func showPastePopup(
        at point: NSPoint,
        plugin: Plugin,
        targetProcessIdentifier: pid_t
    ) {
        scheduleMenuPresentation { [weak self] in
            guard let self else { return }
            guard self.currentContextAllowsMenuPresentation(
                expectedProcessIdentifier: targetProcessIdentifier
            ) else {
                return
            }

            let window = PastePopupWindow()
            window.onPasteClicked = { [weak self] in
                guard let self, self.menuActionGate.consume() else { return }
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
                guard let self, self.menuActionGate.consume() else { return }
                NSPasteboard.general.clearContents()
                self.dismissAllMenus()
            }

            self.menuActionGate.reset()
            window.show(at: point)
            self.pastePopupWindow = window
            self.setupGlobalClickMonitor()
        }
    }

    private func scheduleMenuPresentation(_ presentation: @escaping () -> Void) {
        // The newest hotkey/selection wins while an older panel is fading out.
        pendingMenuPresentation = presentation
        dismissAllMenus(cancelPendingPresentation: false)
    }

    private func presentPendingMenuIfNeeded() {
        guard !isDismissingMenus, let presentation = pendingMenuPresentation else { return }
        pendingMenuPresentation = nil
        presentation()
    }

    private func dismissAllMenus(
        completion: (() -> Void)? = nil,
        cancelPendingPresentation: Bool = true
    ) {
        if cancelPendingPresentation {
            pendingMenuPresentation = nil
        }
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

        let dismissalBarrier = MenuDismissalBarrier(count: dismissCount) { [weak self] in
            self?.finishMenuDismiss()
        }

        if let popupWindow {
            popupWindow.hidePopup {
                dismissalBarrier.completeOne()
            }
        }

        if let radialWindow {
            radialWindow.hideMenu {
                dismissalBarrier.completeOne()
            }
        }
    }
    
    private func handleMenuAction(
        _ item: RadialMenuItem,
        text: String,
        targetProcessIdentifier: pid_t?
    ) {
        if let targetProcessIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcessIdentifier {
            dismissAllMenus()
            return
        }

        let requiresEditableTarget: Bool
        switch item.action {
        case .builtIn(let action):
            requiresEditableTarget = action == .cut || action == .paste
        case .plugin(let plugin):
            requiresEditableTarget =
                plugin.id == Self.cutPluginID ||
                plugin.id == Self.deletePluginID ||
                plugin.id == Self.pastePluginID
        default:
            requiresEditableTarget = false
        }
        if requiresEditableTarget && !AccessibilityManager.shared.isFocusedSelectionEditable() {
            dismissAllMenus()
            return
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
        removeGlobalClickMonitor()
        globalClickMonitorGeneration &+= 1
        let monitorGeneration = globalClickMonitorGeneration
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.menuDismissEventMask) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.globalClickMonitorGeneration == monitorGeneration else { return }
                self.dismissAllMenus()
            }
        }
    }
    
    private func removeGlobalClickMonitor() {
        globalClickMonitorGeneration &+= 1
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
