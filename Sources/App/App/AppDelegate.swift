import Cocoa
import Darwin

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

/// Keeps the non-Sendable Accessibility target confined to the main actor while
/// a menu window retains its action callback. Capturing the raw AXUIElement in
/// that callback makes Swift 6.1 treat the value as being sent to the window.
@MainActor
private final class MenuTargetContext {
    let processIdentifier: pid_t?
    let focusedElement: AXUIElement?
    let windowID: CGWindowID?
    let allowsAcquiredSelectionFocusFallback: Bool
    let focusedElementAssessment: AccessibilityManager.FocusedElementAssessment?
    let interactionGeneration: UInt64?

    init(
        processIdentifier: pid_t?,
        focusedElement: AXUIElement?,
        windowID: CGWindowID?,
        allowsAcquiredSelectionFocusFallback: Bool,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment? = nil,
        interactionGeneration: UInt64? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.focusedElement = focusedElement
        self.windowID = windowID
        self.allowsAcquiredSelectionFocusFallback = allowsAcquiredSelectionFocusFallback
        self.focusedElementAssessment = focusedElementAssessment
        self.interactionGeneration = interactionGeneration
    }
}

/// Main application delegate — orchestrates all components
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let cutPluginID = "com.actionhalo.cut"
    static let deletePluginID = "com.actionhalo.delete"
    static let pastePluginID = "com.actionhalo.builtin.paste"
    static let menuDismissEventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel]
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

    nonisolated static func shouldTerminate(
        hasVisibleUnsavedPluginEditors: Bool,
        discardConfirmed: Bool
    ) -> Bool {
        !hasVisibleUnsavedPluginEditors || discardConfirmed
    }
    
    private let statusBarController = StatusBarController()
    private let legacyMigrationStartupCoordinator: LegacyMigrationStartupCoordinator?
    private var radialMenuWindow: RadialMenuWindow?
    private var isEnabled = true
    private var currentSelectedText: String = ""
    private var observersRegistered = false
    private var isDismissingMenus = false
    private var pendingMenuDismissCompletions: [() -> Void] = []
    private var pendingMenuPresentation: (() -> Void)?
    private var pendingHotkeyFocusTask: Task<Void, Never>?
    private var pendingHotkeyFocusRequestID: UUID?
    private var pendingPastePopupTask: Task<Void, Never>?
    private var pendingPastePopupRequestID: UUID?
    private(set) var interactionGeneration: UInt64 = 0
    private var lastMenuMouseDown: (timestamp: CGEventTimestamp, result: TextSelectionMonitor.MenuMouseDownResult)?
    private let menuActionGate = SingleFireActionGate()
    private var startupPermissionTimer: Timer?
    private(set) var permissionRecoveryTimer: Timer?
    private var permissionRecoveryNeedsPermissionChange = false
    private let pluginInstallQueue = DispatchQueue(
        label: "com.actionhalo.plugin-install",
        qos: .userInitiated
    )
    private var pendingPluginInstallPaths: Set<String> = []
    private var pendingPrelaunchPluginURLs: [URL] = []
    private var hasFinishedLaunching = false
    private var relaunchRequested = false
    
    private var globalMenuDismissMonitor: Any?
    private var localMenuDismissMonitor: Any?
    private var menuDismissMonitorGeneration: UInt64 = 0

    override init() {
        legacyMigrationStartupCoordinator = nil
        super.init()
    }

    init(
        legacyDataImportResult: LegacyDataImportResult,
        legacyMigrationDependencies: LegacyMigrationStartupCoordinator.Dependencies? = nil
    ) {
        legacyMigrationStartupCoordinator = LegacyMigrationStartupCoordinator(
            importResult: legacyDataImportResult,
            dependencies: legacyMigrationDependencies
        )
        super.init()
    }

    static func monitoringStartFailureMessage(_ failure: TextSelectionMonitor.MonitoringStartFailure) -> String {
        switch failure {
        case .accessibilityPermissionMissing:
            return "ActionHalo does not currently have Accessibility permission. Please re-check ActionHalo in System Settings.".localized
        case .eventTapCreationFailed:
            return "ActionHalo could not start the text selection monitor. If Accessibility is already enabled but ActionHalo still does not respond, reset the permission record and re-check ActionHalo in System Settings.".localized
        }
    }

    static func shouldOfferAccessibilityPermissionReset(for failure: TextSelectionMonitor.MonitoringStartFailure) -> Bool {
        failure == .eventTapCreationFailed
    }

    static func shouldExecuteMenuAction(
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        requiresOriginalFocusedElement: Bool,
        requiresEditableTarget: Bool,
        focusedElementMatches: @autoclosure () -> Bool,
        isFocusedSelectionEditable: @autoclosure () -> Bool
    ) -> Bool {
        guard AccessibilityManager.isExpectedCopyFallbackProcess(
            expectedProcessIdentifier: expectedProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ) else {
            return false
        }

        if requiresOriginalFocusedElement || requiresEditableTarget {
            guard focusedElementMatches() else { return false }
        }
        return !requiresEditableTarget || isFocusedSelectionEditable()
    }

    static func accessibilityElement(from value: Any?) -> AXUIElement? {
        guard let value else { return nil }
        let object = value as AnyObject
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(object, to: AXUIElement.self)
    }

    nonisolated static func loadPluginInstallPreview<Result: Sendable>(
        from url: URL,
        on queue: DispatchQueue,
        previewProvider: @escaping @Sendable (URL) -> Result,
        completion: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        queue.async {
            let result = previewProvider(url)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    static func accessibilityResetArguments(bundleIdentifier: String = "com.actionhalo.app") -> [String] {
        ["reset", "Accessibility", bundleIdentifier]
    }

    static func isSupportedPluginPackageURL(_ url: URL) -> Bool {
        PluginLoader.isSupportedPackageURL(url)
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
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // UIElement apps can miss the normal delegate callback for document
        // opens, so register the matching AppleEvent path before AppKit
        // delivers any cold-launch files.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(event:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit delivers Finder document-open requests before this callback.
        // Preserve those paths until startup completes so the user's original
        // plugin-open action is not lost.
        let queuedPrelaunchPluginURLs = pendingPrelaunchPluginURLs

        hasFinishedLaunching = true
        pendingPrelaunchPluginURLs.removeAll()

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

        // Import already ran before this delegate was constructed. Route its
        // result before Accessibility can show a system prompt, keeping the two
        // modal flows strictly ordered. Finder-open URLs remain in the local
        // queue above and are handled immediately after this returns.
        legacyMigrationStartupCoordinator?.handlePostLaunchResult()

        // Automatically clear stale accessibility permissions if the app was updated.
        checkAndUpdateAccessibilityState()
        applyDefaultOfficeSuiteExcludedAppsMigrationIfNeeded()
        
        // Handle pre-launch document opens (LaunchServices passing args directly)
        for arg in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: arg)
            if Self.isSupportedPluginPackageURL(url) {
                _ = installPluginWithConfirmation(from: url)
            }
        }
        for url in queuedPrelaunchPluginURLs {
            _ = installPluginWithConfirmation(from: url)
        }
        
        // Setup status bar
        statusBarController.setup()
        isEnabled = statusBarController.currentEnabledState
        statusBarController.onEnabledChanged = { [weak self] enabled in
            self?.setEnabled(enabled)
        }
        statusBarController.onRelaunchRequested = { [weak self] in
            self?.relaunchRequested = true
            NSApp.terminate(nil)
        }

        // Check accessibility permission.
        if !AccessibilityManager.shared.ensureAccessibilityPermission() {
            NSLog("[ActionHalo] Waiting for accessibility permission...")
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

        // Install the root watcher synchronously so package creation cannot be
        // missed, then load plugins while fine-grained watcher discovery runs
        // in the background.
        PluginManager.shared.startWatchingPluginDirectories()
        PluginManager.shared.loadAllPlugins()

        // Setup global hotkeys.
        HotkeyManager.shared.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyTriggered()
        }
        HotkeyManager.shared.onToggleHotkeyPressed = { [weak self] in
            self?.statusBarController.toggleEnabled()
        }

        if HotkeyManager.shared.hotkey != nil || HotkeyManager.shared.toggleHotkey != nil {
            let issues = HotkeyManager.shared.registerHotkeys()
            for issue in issues {
                NSLog("[ActionHalo] Hotkey registration issue: \(issue.message)")
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
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        guard let expectedProcessIdentifier = frontmostApplication?.processIdentifier else {
            return
        }
        let expectedBundleID = frontmostApplication?.bundleIdentifier
        guard let expectedWindowSnapshot = TextSelectionMonitor.currentFrontmostWindowSnapshot(
            frontmostApplication: frontmostApplication
        ), let expectedWindowID = expectedWindowSnapshot.windowID else {
            return
        }
        let expectedWindowConstraint = AccessibilityManager.FocusedWindowConstraint(
            windowID: expectedWindowID,
            ownerPID: expectedWindowSnapshot.ownerPID,
            bounds: expectedWindowSnapshot.bounds
        )
        guard Self.shouldAllowMenuPresentation(
            isEnabled: isEnabled,
            frontmostBundleID: expectedBundleID,
            frontmostLocalizedName: frontmostApplication?.localizedName,
            // This preflight intentionally avoids an AX lookup. Critical apps
            // and exclusions still fail, while Finder gets its established
            // editable-focus decision after focus acquisition below.
            isFocusedSelectionEditable: true
        ) else {
            return
        }
        TextSelectionMonitor.shared.cancelPendingInteraction()
        let requestInteractionGeneration = beginNewInteraction()
        let focusRequestID = UUID()
        pendingHotkeyFocusRequestID = focusRequestID

        pendingHotkeyFocusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let assessedFocusedElement = await AccessibilityManager.shared
                .resolveAssessedFocusedElementWithRetry(
                    expectedProcessIdentifier: expectedProcessIdentifier,
                    windowConstraint: expectedWindowConstraint,
                    bundleID: expectedBundleID,
                    requireUsableSelection: true,
                    acceptExistingSelection: true
                )
            let expectedFocusedElement = assessedFocusedElement?.focusedElement
            guard !Task.isCancelled,
                  Self.isInteractionCurrent(
                    expectedGeneration: requestInteractionGeneration,
                    currentGeneration: self.interactionGeneration
                  ),
                  self.pendingHotkeyFocusRequestID == focusRequestID else {
                return
            }
            self.pendingHotkeyFocusTask = nil
            self.pendingHotkeyFocusRequestID = nil
            guard AccessibilityManager.isExpectedCopyFallbackProcess(
                expectedProcessIdentifier: expectedProcessIdentifier,
                currentProcessIdentifier:
                    NSWorkspace.shared.frontmostApplication?.processIdentifier
            ) else {
                return
            }
            let currentTopmostWindow =
                TextSelectionMonitor.currentFrontmostWindowSnapshot(
                    frontmostProcessID: expectedProcessIdentifier
                )
            guard TextSelectionMonitor.focusedWindowRetryDisposition(
                capturedWindow: expectedWindowSnapshot,
                currentTopmostWindow: currentTopmostWindow,
                accessibilityWindowMatches: true
            ) == .accept else {
                return
            }
            self.completeHotkeyTrigger(
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedBundleID: expectedBundleID,
                expectedWindowID: expectedWindowID,
                expectedFocusedElement: expectedFocusedElement,
                focusedElementAssessment: assessedFocusedElement?.assessment,
                interactionGeneration: requestInteractionGeneration
            )
        }
    }

    nonisolated static func isInteractionCurrent(
        expectedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        expectedGeneration == currentGeneration
    }

    @discardableResult
    func beginNewInteraction() -> UInt64 {
        interactionGeneration &+= 1
        cancelPendingPastePopupWork()
        pendingHotkeyFocusTask?.cancel()
        pendingHotkeyFocusTask = nil
        pendingHotkeyFocusRequestID = nil
        pendingMenuPresentation = nil
        AccessibilityManager.shared.cancelActiveSelectedTextViaCopy()
        return interactionGeneration
    }

    func handlePhysicalMouseDownStarted(
        _ type: CGEventType, at screenPoint: NSPoint, timestamp: CGEventTimestamp
    ) -> TextSelectionMonitor.MenuMouseDownResult {
        // AppKit and the event tap can observe the same click in either order.
        if timestamp != 0, let lastMenuMouseDown, lastMenuMouseDown.timestamp == timestamp {
            return lastMenuMouseDown.result
        }
        _ = beginNewInteraction()
        let result: TextSelectionMonitor.MenuMouseDownResult
        // Use the selection event tap too; cross-app AppKit notifications can be missed.
        if radialMenuWindow == nil && pastePopupWindow == nil {
            result = .noMenu
        } else if (pastePopupWindow != nil && type != .leftMouseDown) || Self.shouldDismissMenus(
            atScreenPoint: screenPoint,
            radialMenuWindow: radialMenuWindow,
            pastePopupWindow: pastePopupWindow
        ) {
            dismissAllMenus()
            result = .dismissedMenu
        } else {
            result = .menuClick
        }
        lastMenuMouseDown = timestamp == 0 ? nil : (timestamp, result)
        return result
    }

    private func completeHotkeyTrigger(
        expectedProcessIdentifier: pid_t,
        expectedBundleID: String?,
        expectedWindowID: CGWindowID?,
        expectedFocusedElement: AXUIElement?,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment?,
        interactionGeneration: UInt64
    ) {
        guard Self.isInteractionCurrent(
            expectedGeneration: interactionGeneration,
            currentGeneration: self.interactionGeneration
        ) else {
            return
        }
        let allowMissingFocusedElement = expectedWindowID != nil &&
            AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                bundleID: expectedBundleID
            )
        guard expectedFocusedElement != nil || allowMissingFocusedElement else {
            AccessibilityManager.shared.recordSelectionAttemptFailure(.noFocusedApplication)
            return
        }
        guard !AccessibilityManager.shouldSuppressCopyFallback(
            focusedElementAssessment: focusedElementAssessment?.protection,
            secureEventInputEnabled:
                AccessibilityManager.shared.isSecureEventInputEnabled(),
            accessibilityEnabled:
                AccessibilityManager.shared.isAccessibilityEnabled,
            allowMissingFocusedElement: allowMissingFocusedElement
        ) else {
            return
        }
        let currentFrontmostApplication = NSWorkspace.shared.frontmostApplication
        guard Self.shouldAllowMenuPresentation(
            isEnabled: isEnabled,
            frontmostBundleID: currentFrontmostApplication?.bundleIdentifier,
            frontmostLocalizedName: currentFrontmostApplication?.localizedName,
            isFocusedSelectionEditable:
                focusedElementAssessment?.isSelectionEditable ?? false
        ) else {
            return
        }

        if let expectedFocusedElement,
           let text = focusedElementAssessment?.selectionSnapshot?.usableText,
           !text.isEmpty {
            let mouseLocation = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(
                source: .accessibility, text: text,
                processIdentifier: expectedProcessIdentifier, windowID: expectedWindowID
            )
            self.currentSelectedText = text
            showRadialMenu(
                at: mouseLocation,
                text: text,
                targetProcessIdentifier: expectedProcessIdentifier,
                targetFocusedElement: expectedFocusedElement,
                targetWindowID: expectedWindowID,
                allowsAcquiredSelectionFocusFallback: true,
                focusedElementAssessment: focusedElementAssessment,
                interactionGeneration: interactionGeneration,
                keyboardNavigation: true
            )
            return
        }
        AccessibilityManager.shared.recordSelectionAttemptFailure(.accessibilityEmptySelection)
        
        // If Accessibility fails, simulate Cmd+C (async to allow physical hotkeys to be released)
        AccessibilityManager.shared.getSelectedTextViaCopy(
            expectedProcessIdentifier: expectedProcessIdentifier,
            expectedFocusedElement: expectedFocusedElement,
            expectedFocusedElementAssessment: focusedElementAssessment?.protection,
            allowMissingFocusedElement: allowMissingFocusedElement,
            expectedBundleID: expectedBundleID,
            expectedWindowID: expectedWindowID,
            allowsAcquiredSelectionFocusFallback: true
        ) { [weak self] copiedText in
            guard let self,
                  Self.isInteractionCurrent(
                    expectedGeneration: interactionGeneration,
                    currentGeneration: self.interactionGeneration
                  ) else {
                return
            }
            guard AccessibilityManager.isExpectedCopyFallbackProcess(
                expectedProcessIdentifier: expectedProcessIdentifier,
                currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ) else {
                return
            }
            guard let text = copiedText, !text.isEmpty else {
                AccessibilityManager.shared.recordSelectionAttemptFailure(.copyFallbackEmptySelection)
                return
            }
            guard self.currentContextAllowsMenuPresentation(
                expectedProcessIdentifier: expectedProcessIdentifier,
                expectedFocusedElement: expectedFocusedElement,
                expectedWindowID: expectedWindowID,
                allowsAcquiredSelectionFocusFallback: true,
                resolvedCurrentFocusedElement: expectedFocusedElement,
                resolvedFocusedElementAssessment: focusedElementAssessment,
                useResolvedCurrentFocusedElement: true
            ) else {
                return
            }
            let mouseLocation = NSEvent.mouseLocation
            AccessibilityManager.shared.recordSelectionAcquisition(
                source: .copyFallback, text: text,
                processIdentifier: expectedProcessIdentifier, windowID: expectedWindowID
            )
            self.currentSelectedText = text
            self.showRadialMenu(
                at: mouseLocation,
                text: text,
                targetProcessIdentifier: expectedProcessIdentifier,
                targetFocusedElement: expectedFocusedElement,
                targetWindowID: expectedWindowID,
                allowsAcquiredSelectionFocusFallback: true,
                focusedElementAssessment: focusedElementAssessment,
                interactionGeneration: interactionGeneration,
                keyboardNavigation: true
            )
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        applicationShouldTerminate(sender, presentAlert: { $0.runModal() })
    }

    func applicationShouldTerminate(
        _ sender: NSApplication,
        presentAlert: (NSAlert) -> NSApplication.ModalResponse
    ) -> NSApplication.TerminateReply {
        let editors = sender.windows.compactMap { $0 as? PluginEditorWindow }
        var pluginOperationInProgress = !pendingPluginInstallPaths.isEmpty ||
            editors.contains { $0.isPersisting }
        if !pluginOperationInProgress {
            if PluginManager.tryBeginPluginMutation() {
                PluginManager.endPluginMutation()
            } else {
                pluginOperationInProgress = true
            }
        }
        if pluginOperationInProgress {
            relaunchRequested = false
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Plugin Operation in Progress".localized
            alert.informativeText = "Wait for the current plugin save, installation, or deletion to finish before quitting or restarting ActionHalo.".localized
            alert.addButton(withTitle: "OK".localized)
            sender.activate(ignoringOtherApps: true)
            _ = presentAlert(alert)
            return .terminateCancel
        }
        let unsavedEditors = editors.filter {
            ($0.isVisible || $0.isMiniaturized) && $0.hasUnsavedChanges
        }

        guard !unsavedEditors.isEmpty else {
            return prepareForTermination()
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unsaved Plugin Changes".localized
        alert.informativeText = "One or more plugin editors have unsaved changes. Save them before quitting or restarting ActionHalo.".localized
        alert.addButton(withTitle: "Cancel Quit".localized)
        let discardButton = alert.addButton(withTitle: "Discard Changes and Quit".localized)
        discardButton.hasDestructiveAction = true

        sender.activate(ignoringOtherApps: true)
        let discardConfirmed = presentAlert(alert) == .alertSecondButtonReturn
        guard Self.shouldTerminate(
            hasVisibleUnsavedPluginEditors: true,
            discardConfirmed: discardConfirmed
        ) else {
            relaunchRequested = false
            sender.activate(ignoringOtherApps: true)
            if let editor = unsavedEditors.first {
                if editor.isMiniaturized {
                    editor.deminiaturize(nil)
                }
                editor.makeKeyAndOrderFront(nil)
            }
            return .terminateCancel
        }

        let reply = prepareForTermination()
        if reply == .terminateNow {
            unsavedEditors.forEach { $0.discardUnsavedChanges() }
        }
        return reply
    }

    static func relaunchProcess(
        bundlePath: String,
        processIdentifier: pid_t,
        openerPath: String = "/usr/bin/open"
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec \"$2\" \"$3\"",
            "ActionHalo-relaunch", String(processIdentifier), openerPath, bundlePath
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func prepareForTermination() -> NSApplication.TerminateReply {
        guard relaunchRequested else { return .terminateNow }
        do {
            try Self.relaunchProcess(
                bundlePath: Bundle.main.bundlePath,
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            ).run()
            return .terminateNow
        } catch {
            relaunchRequested = false
            NSAlert(error: error).runModal()
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        beginNewInteraction()
        TextSelectionMonitor.shared.onPhysicalMouseDown = nil
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
        NSLog("[ActionHalo] handleOpenDocumentsEvent raw event received")
        if let descriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) {
            let numItems = descriptor.numberOfItems
            let typeFileURL = OSType(0x6675726c) // "furl" type
            
            let processDescriptor: (NSAppleEventDescriptor) -> Void = { desc in
                if let urlDesc = desc.coerce(toDescriptorType: typeFileURL) {
                    let data = urlDesc.data
                    if let urlString = String(data: data, encoding: .utf8),
                       let url = URL(string: urlString) {
                        
                        _ = self.handlePluginOpenRequest(url)
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
        NSLog("[ActionHalo] application(_:openFile:) called for: \(filename)")
        return handlePluginOpenRequest(url)
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("[ActionHalo] application(_:open:urls) called with: \(urls)")
        for url in urls {
            _ = handlePluginOpenRequest(url)
        }
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        NSLog("[ActionHalo] application(_:openFiles:) called with: \(filenames)")
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            _ = handlePluginOpenRequest(url)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func handlePluginOpenRequest(_ url: URL) -> Bool {
        guard Self.isSupportedPluginPackageURL(url) else {
            return false
        }
        let standardizedURL = url.standardizedFileURL
        guard hasFinishedLaunching else {
            if !pendingPrelaunchPluginURLs.contains(standardizedURL) {
                pendingPrelaunchPluginURLs.append(standardizedURL)
            }
            return true
        }
        return installPluginWithConfirmation(from: standardizedURL)
    }
    
    private func installPluginWithConfirmation(from url: URL) -> Bool {
        let installPath = url.standardizedFileURL.path
        if pendingPluginInstallPaths.contains(installPath) {
            return true
        }
        pendingPluginInstallPaths.insert(installPath)

        Self.loadPluginInstallPreview(
            from: url,
            on: pluginInstallQueue,
            previewProvider: { PluginManager.shared.makeInstallPreview(from: $0) },
            completion: { [weak self] preview in
                guard let self else { return }
                guard let preview else {
                    self.pendingPluginInstallPaths.remove(installPath)
                    let alert = NSAlert()
                    alert.messageText = "Install Failed".localized
                    alert.informativeText = PluginManager.PluginInstallFailure.invalidPackage.localizedMessage(
                        sourcePath: url.path
                    )
                    alert.alertStyle = .critical
                    alert.runModal()
                    return
                }

                self.presentPluginInstallConfirmation(
                    preview,
                    sourceURL: url,
                    installPath: installPath
                )
            }
        )
        return true
    }

    private func presentPluginInstallConfirmation(
        _ preview: PluginManager.PluginInstallPreview,
        sourceURL url: URL,
        installPath: String
    ) {
        let pluginName = preview.name
        var pluginDescription = preview.description ??
            String(format: "Type: %@".localized, preview.actionType.rawValue)
        if preview.requiresExecutionTrust {
            pluginDescription += "\n\n" + "Warning: this plugin can perform protected actions on your Mac. ActionHalo will require explicit trust before the first run, and again after plugin changes.".localized
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

        guard alert.runModal() == .alertFirstButtonReturn else {
            pendingPluginInstallPaths.remove(installPath)
            return
        }

        statusBarController.showTemporaryStatusMessage(
            String(format: "Installing %@".localized, installingPluginName)
        )

        let handleInstallResult: @MainActor @Sendable (PluginManager.PluginInstallResult) -> Void = {
            [weak self] installResult in
            guard let self else { return }
            self.pendingPluginInstallPaths.remove(installPath)

            guard !installResult.isSuccess else {
                NSLog("[ActionHalo] Plugin '%@' installed successfully.", installingPluginName)
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
    }
    
    // MARK: - Services
    
    @discardableResult
    private func startServices(showMonitoringFailure: Bool = true) -> Bool {
        NSLog("[ActionHalo] Starting text selection monitoring...")
        AccessibilityManager.shared.onPermissionLost = { [weak self] in
            self?.showPermissionLostAlert()
        }
        TextSelectionMonitor.shared.onPhysicalMouseDown = { [weak self] type, point, timestamp in
            self?.handlePhysicalMouseDownStarted(type, at: point, timestamp: timestamp) ?? .noMenu
        }
        guard !isEnabled || startTextSelectionMonitoringWithFeedback(
            showFailure: showMonitoringFailure
        ) else { return false }
        permissionRecoveryTimer?.invalidate()
        permissionRecoveryTimer = nil
        AccessibilityManager.shared.startWatchdog()
        
        // Listen for text selection events
        registerServiceObserversIfNeeded()
        return true
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

    private func startTextSelectionMonitoringWithFeedback(showFailure: Bool = true) -> Bool {
        guard !TextSelectionMonitor.shared.startMonitoring() else {
            return true
        }
        if showFailure, let failure = TextSelectionMonitor.shared.lastMonitoringStartFailure {
            showMonitoringStartFailureAlert(failure)
        }
        return false
    }
    
    private func unregisterServiceObservers() {
        guard observersRegistered else { return }
        NotificationCenter.default.removeObserver(self, name: TextSelectionMonitor.textSelectedNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: TextSelectionMonitor.emptyTextInputClickedNotification, object: nil)
        observersRegistered = false
    }
    
    private func showPermissionLostAlert() {
        beginNewInteraction()
        TextSelectionMonitor.shared.stopMonitoring()
        
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Lost".localized
        alert.informativeText = "ActionHalo relies on Accessibility to detect text selection. Please re-check ActionHalo in 'System Settings -> Privacy & Security -> Accessibility'.".localized
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
            waitAndRecoverPermission()
        } else if Self.shouldOfferAccessibilityPermissionReset(for: failure),
                  response == .alertSecondButtonReturn {
            resetAccessibilityPermissions()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            waitAndRecoverPermission()
        }
    }
    
    func waitAndRecoverPermission(
        accessibilityEnabled: @escaping @MainActor @Sendable () -> Bool = {
            AccessibilityManager.shared.isAccessibilityEnabled
        },
        restartServices: (@MainActor @Sendable () -> Bool)? = nil,
        didRecover: (@MainActor @Sendable () -> Void)? = nil
    ) {
        // An explicit Settings/Reset action permits one retry. If the event
        // tap still fails, observe the next permission cycle without repeatedly
        // attempting AX setup or presenting another modal every two seconds.
        permissionRecoveryNeedsPermissionChange = false
        guard permissionRecoveryTimer == nil else { return }
        AccessibilityManager.shared.stopWatchdog()

        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard accessibilityEnabled() else {
                    self.permissionRecoveryNeedsPermissionChange = false
                    return
                }
                guard !self.permissionRecoveryNeedsPermissionChange else { return }
                self.permissionRecoveryNeedsPermissionChange = true
                guard restartServices?() ?? self.startServices(showMonitoringFailure: false) else {
                    return
                }
                self.permissionRecoveryTimer?.invalidate()
                self.permissionRecoveryTimer = nil
                guard self.isEnabled else { return }
                if let didRecover {
                    didRecover()
                    return
                }

                let alert = NSAlert()
                alert.messageText = "Permission Restored".localized
                alert.informativeText = "ActionHalo has resumed working.".localized
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK".localized)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        permissionRecoveryTimer = timer
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            startServices()
        } else {
            beginNewInteraction()
            permissionRecoveryTimer?.invalidate()
            permissionRecoveryTimer = nil
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
        let focusedElement = Self.accessibilityElement(from: userInfo["focusedElement"])
        let focusedElementAssessment = userInfo["focusedElementAssessment"] as?
            AccessibilityManager.FocusedElementAssessment
        let windowID = (userInfo["windowID"] as? NSNumber).map {
            CGWindowID($0.uint32Value)
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
            targetProcessIdentifier: processIdentifier,
            targetFocusedElement: focusedElement,
            targetWindowID: windowID,
            allowsAcquiredSelectionFocusFallback: true,
            focusedElementAssessment: focusedElementAssessment
        )
    }
    
    @objc private func handleEmptyTextInputClick(_ notification: Notification) {
        guard isEnabled else { return }
        guard let userInfo = notification.userInfo,
              let locationValue = userInfo["mouseLocation"] as? NSValue,
              let processNumber = userInfo["processIdentifier"] as? NSNumber,
              let focusedElement = Self.accessibilityElement(from: userInfo["focusedElement"]),
              let assessment = userInfo["focusedElementAssessment"] as?
                AccessibilityManager.FocusedElementAssessment,
              let windowSnapshot = userInfo["windowSnapshot"] as?
                TextSelectionMonitor.FrontmostWindowSnapshot,
              TextSelectionMonitor.shouldPresentEmptyInputPastePopup(assessment: assessment) else {
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
            isFocusedSelectionEditable: assessment.isSelectionEditable
        ) else {
            return
        }
        
        let mouseLocation = locationValue.pointValue
        currentSelectedText = "" // Empty text because nothing is selected
        
        let appBundleID = frontmostApp?.bundleIdentifier

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
            targetProcessIdentifier: processIdentifier,
            targetFocusedElement: focusedElement,
            windowSnapshot: windowSnapshot,
            focusedElementAssessment: assessment
        )
    }
    
    // MARK: - Radial Menu & Popups
    
    private func showRadialMenu(
        at point: NSPoint,
        text: String,
        targetProcessIdentifier: pid_t?,
        targetFocusedElement: AXUIElement?,
        targetWindowID: CGWindowID?,
        allowsAcquiredSelectionFocusFallback: Bool,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment? = nil,
        interactionGeneration: UInt64? = nil,
        keyboardNavigation: Bool = false
    ) {
        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let presentationPlugins = PluginManager.shared.presentationPlugins(appBundleID: appBundleID)
        showRadialMenu(
            at: point,
            plugins: Self.radialMenuPlugins(from: presentationPlugins),
            selectedText: text,
            targetProcessIdentifier: targetProcessIdentifier,
            targetFocusedElement: targetFocusedElement,
            targetWindowID: targetWindowID,
            allowsAcquiredSelectionFocusFallback:
                allowsAcquiredSelectionFocusFallback,
            focusedElementAssessment: focusedElementAssessment,
            interactionGeneration: interactionGeneration,
            keyboardNavigation: keyboardNavigation
        )
    }

    private func currentContextAllowsMenuPresentation(
        expectedProcessIdentifier: pid_t? = nil,
        expectedFocusedElement: AXUIElement? = nil,
        expectedWindowID: CGWindowID? = nil,
        allowsAcquiredSelectionFocusFallback: Bool = false,
        resolvedCurrentFocusedElement: AXUIElement? = nil,
        resolvedFocusedElementAssessment:
            AccessibilityManager.FocusedElementAssessment? = nil,
        useResolvedCurrentFocusedElement: Bool = false
    ) -> Bool {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let currentProcessIdentifier = frontmostApp?.processIdentifier
        let currentFocusedElement: AXUIElement?
        if useResolvedCurrentFocusedElement {
            currentFocusedElement = resolvedCurrentFocusedElement
        } else {
            currentFocusedElement = AccessibilityManager.shared.getFocusedElement(
                expectedProcessIdentifier:
                    expectedProcessIdentifier ?? currentProcessIdentifier
            )
        }

        if allowsAcquiredSelectionFocusFallback {
            let currentWindowID = TextSelectionMonitor.currentFrontmostWindowSnapshot(
                frontmostProcessID: currentProcessIdentifier
            )?.windowID
            let focusedElementMatches = AccessibilityManager.areSameAccessibilityElement(
                expectedFocusedElement,
                currentFocusedElement
            )
            let needsStructuralFocusFallback =
                expectedFocusedElement != nil && !focusedElementMatches
            let currentFocusedElementIsStructural = needsStructuralFocusFallback &&
                AccessibilityManager.shared.isStructuralSelectionFocus(
                    currentFocusedElement
                )
            let focusedWindowMatches: Bool
            if needsStructuralFocusFallback {
                focusedWindowMatches = AccessibilityManager.areSameAccessibilityElement(
                    AccessibilityManager.shared.selectionWindow(
                        for: expectedFocusedElement
                    ),
                    AccessibilityManager.shared.selectionWindow(
                        for: currentFocusedElement
                    )
                )
            } else {
                focusedWindowMatches = focusedElementMatches
            }
            guard TextSelectionMonitor.shouldContinueAcquiredSelectionPresentation(
                expectedProcessIdentifier: expectedProcessIdentifier,
                currentProcessIdentifier: currentProcessIdentifier,
                bundleID: frontmostApp?.bundleIdentifier,
                expectedFocusedElementAvailable: expectedFocusedElement != nil,
                currentFocusedElementAvailable: currentFocusedElement != nil,
                focusedElementMatches: focusedElementMatches,
                currentFocusedElementIsStructural: currentFocusedElementIsStructural,
                focusedWindowMatches: focusedWindowMatches,
                expectedWindowID: expectedWindowID,
                currentWindowID: currentWindowID
            ) else {
                return false
            }
            let allowMissingFocusedElement =
                AccessibilityManager.shouldAllowContextlessBlindCopyFallback(
                    bundleID: frontmostApp?.bundleIdentifier
                )
            if let resolvedFocusedElementAssessment {
                guard !AccessibilityManager.shouldSuppressCopyFallback(
                    focusedElementAssessment:
                        resolvedFocusedElementAssessment.protection,
                    secureEventInputEnabled:
                        AccessibilityManager.shared.isSecureEventInputEnabled(),
                    accessibilityEnabled:
                        AccessibilityManager.shared.isAccessibilityEnabled,
                    allowMissingFocusedElement: allowMissingFocusedElement
                ) else {
                    return false
                }
            } else {
                guard !AccessibilityManager.shared.shouldSuppressSelectionPresentation(
                    focusedElement: currentFocusedElement,
                    allowMissingFocusedElement: allowMissingFocusedElement
                ) else {
                    return false
                }
            }
        } else {
            if expectedProcessIdentifier != nil,
               !AccessibilityManager.isExpectedCopyFallbackProcess(
                expectedProcessIdentifier: expectedProcessIdentifier,
                currentProcessIdentifier: currentProcessIdentifier
               ) {
                return false
            }
            if let expectedFocusedElement,
               !AccessibilityManager.areSameAccessibilityElement(
                    expectedFocusedElement,
                    currentFocusedElement
               ) {
                return false
            }
        }

        return Self.shouldAllowMenuPresentation(
            isEnabled: isEnabled,
            frontmostBundleID: frontmostApp?.bundleIdentifier,
            frontmostLocalizedName: frontmostApp?.localizedName,
            isFocusedSelectionEditable:
                resolvedFocusedElementAssessment?.isSelectionEditable ??
                currentFocusedElement.map {
                    AccessibilityManager.shared.isSelectionEditable($0)
                } ?? false
        )
    }

    static func radialMenuPlugins(from plugins: [Plugin]) -> [Plugin] {
        plugins
    }

    static func pluginRequiresEditableTarget(_ plugin: Plugin) -> Bool {
        plugin.config.action.type == .paste ||
            plugin.id == cutPluginID ||
            plugin.id == deletePluginID ||
            plugin.id == pastePluginID
    }

    static func pluginRequiresOriginalFocusedElement(_ plugin: Plugin) -> Bool {
        pluginRequiresEditableTarget(plugin) ||
            plugin.config.action.type == .keyCombo
    }

    static func isPluginExecutable(_ plugin: Plugin, text: String, appBundleID: String?, isSelectionEditable: Bool) -> Bool {
        let matchesContext = plugin.shouldShow(text: text, appBundleID: appBundleID)
        guard matchesContext else { return false }

        if pluginRequiresEditableTarget(plugin) {
            return isSelectionEditable
        }

        return true
    }

    static func isPluginExecutableInMenu(
        _ plugin: Plugin,
        text: String,
        appBundleID: String?,
        isSelectionEditable: Bool,
        focusedElementMatches: Bool
    ) -> Bool {
        isPluginExecutable(
            plugin,
            text: text,
            appBundleID: appBundleID,
            isSelectionEditable: isSelectionEditable
        ) && (
            !pluginRequiresOriginalFocusedElement(plugin) || focusedElementMatches
        )
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
        targetProcessIdentifier: pid_t?,
        targetFocusedElement: AXUIElement?,
        targetWindowID: CGWindowID?,
        allowsAcquiredSelectionFocusFallback: Bool,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment? = nil,
        interactionGeneration: UInt64? = nil,
        keyboardNavigation: Bool = false
    ) {
        guard !plugins.isEmpty else { return }

        let targetContext = MenuTargetContext(
            processIdentifier: targetProcessIdentifier,
            focusedElement: targetFocusedElement,
            windowID: targetWindowID,
            allowsAcquiredSelectionFocusFallback:
                allowsAcquiredSelectionFocusFallback,
            focusedElementAssessment: focusedElementAssessment,
            interactionGeneration: interactionGeneration
        )

        scheduleMenuPresentation { [weak self] in
            guard let self else { return }
            if let expectedGeneration = targetContext.interactionGeneration,
               !Self.isInteractionCurrent(
                    expectedGeneration: expectedGeneration,
                    currentGeneration: self.interactionGeneration
               ) {
                return
            }
            let resolvedFocusedElement = targetContext.focusedElement
            guard self.currentContextAllowsMenuPresentation(
                expectedProcessIdentifier: targetContext.processIdentifier,
                expectedFocusedElement: targetContext.focusedElement,
                expectedWindowID: targetContext.windowID,
                allowsAcquiredSelectionFocusFallback:
                    targetContext.allowsAcquiredSelectionFocusFallback,
                resolvedCurrentFocusedElement: resolvedFocusedElement,
                resolvedFocusedElementAssessment:
                    targetContext.focusedElementAssessment,
                useResolvedCurrentFocusedElement: true
            ) else {
                return
            }

            // The trigger already resolved and protected this exact candidate.
            // Re-querying AX focus here can turn a transient macOS 15 success
            // into a false negative while the same PID/window remains current.
            let appBundleID =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let isSelectionEditable =
                targetContext.focusedElementAssessment?.isSelectionEditable ??
                resolvedFocusedElement.map {
                    AccessibilityManager.shared.isSelectionEditable($0)
                } ?? false
            let items = plugins.map { plugin in
                RadialMenuItem(
                    title: plugin.name,
                    iconName: plugin.iconName,
                    action: .plugin(plugin),
                    customIcon: plugin.customIcon,
                    isExecutable: Self.isPluginExecutableInMenu(
                        plugin,
                        text: selectedText,
                        appBundleID: appBundleID,
                        isSelectionEditable: isSelectionEditable,
                        focusedElementMatches: resolvedFocusedElement != nil
                    )
                )
            }

            let window = RadialMenuWindow()
            window.onDismissRequested = { [weak self, weak window] in
                guard let self, let window, self.radialMenuWindow === window else { return }
                self.dismissAllMenus()
            }
            window.onItemSelected = { [weak self, weak window] item in
                guard let self, let window, self.radialMenuWindow === window,
                      self.menuActionGate.consume() else { return }
                self.handleMenuAction(
                    item,
                    text: selectedText,
                    targetProcessIdentifier: targetContext.processIdentifier,
                    targetFocusedElement: targetContext.focusedElement
                )
            }
            self.menuActionGate.reset()
            window.showMenu(
                at: point,
                items: items,
                selectedText: selectedText,
                keyboardNavigation: keyboardNavigation
            )

            self.radialMenuWindow = window
            self.setupMenuDismissMonitors()
        }
    }
    
    private func showPastePopup(
        at point: NSPoint,
        plugin: Plugin,
        targetProcessIdentifier: pid_t,
        targetFocusedElement: AXUIElement,
        windowSnapshot: TextSelectionMonitor.FrontmostWindowSnapshot,
        focusedElementAssessment: AccessibilityManager.FocusedElementAssessment
    ) {
        guard let windowID = windowSnapshot.windowID,
              windowSnapshot.ownerPID == targetProcessIdentifier else { return }
        let targetContext = MenuTargetContext(
            processIdentifier: targetProcessIdentifier,
            focusedElement: targetFocusedElement,
            windowID: windowID,
            allowsAcquiredSelectionFocusFallback: false,
            focusedElementAssessment: focusedElementAssessment
        )
        let windowConstraint = AccessibilityManager.FocusedWindowConstraint(
            windowID: windowID,
            ownerPID: windowSnapshot.ownerPID,
            bounds: windowSnapshot.bounds
        )
        let requestID = UUID()
        let generation = interactionGeneration

        scheduleMenuPresentation(pastePopupRequestID: requestID) { [weak self] in
            guard let self, self.isCurrentPastePopupRequest(requestID, generation: generation) else { return }
            self.pendingPastePopupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPastePopupWork(requestID) }
                guard let currentFocusedElement = await AccessibilityManager.shared.getFocusedElementWithRetry(
                    expectedProcessIdentifier: targetContext.processIdentifier,
                    windowConstraint: windowConstraint
                ), self.isCurrentPastePopupRequest(requestID, generation: generation),
                   TextSelectionMonitor.shouldPresentEmptyInputPastePopup(assessment: focusedElementAssessment),
                   self.pastePopupContextAllowsAction(
                    plugin: plugin,
                    targetContext: targetContext,
                    currentFocusedElement: currentFocusedElement,
                    assessment: focusedElementAssessment,
                    windowSnapshot: windowSnapshot
                   ) else { return }

                let window = PastePopupWindow()
                window.onPasteClicked = { [weak self, weak window] in
                    guard let self, let window, self.pastePopupWindow === window,
                          self.menuActionGate.consume() else { return }
                    self.executePastePopupAction(
                        plugin: plugin,
                        targetContext: targetContext,
                        windowSnapshot: windowSnapshot
                    )
                }
                window.onClearClicked = { [weak self, weak window] in
                    guard let self, let window, self.pastePopupWindow === window,
                          self.menuActionGate.consume() else { return }
                    NSPasteboard.general.clearContents()
                    self.dismissAllMenus()
                }

                self.presentPastePopup(window, at: point)
            }
        }
    }

    func presentPastePopup(_ window: PastePopupWindow, at point: NSPoint) {
        menuActionGate.reset()
        window.show(at: point)
        pastePopupWindow = window
    }

    private func executePastePopupAction(
        plugin: Plugin,
        targetContext: MenuTargetContext,
        windowSnapshot: TextSelectionMonitor.FrontmostWindowSnapshot
    ) {
        guard let windowID = windowSnapshot.windowID else { return }
        cancelPendingPastePopupWork()
        let requestID = UUID()
        // Clicking the popup itself starts a physical interaction. Bind execution
        // to that click, rather than to the older input-field click that showed it.
        let generation = interactionGeneration
        pendingPastePopupRequestID = requestID
        let windowConstraint = AccessibilityManager.FocusedWindowConstraint(
            windowID: windowID,
            ownerPID: windowSnapshot.ownerPID,
            bounds: windowSnapshot.bounds
        )
        dismissAllMenus(completion: { [weak self] in
            guard let self, self.isCurrentPastePopupRequest(requestID, generation: generation) else { return }
            self.pendingPastePopupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPastePopupWork(requestID) }
                do {
                    try await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                guard self.isCurrentPastePopupRequest(requestID, generation: generation) else { return }
                let assessedFocus = await AccessibilityManager.shared.resolveAssessedFocusedElementWithRetry(
                    expectedProcessIdentifier: targetContext.processIdentifier,
                    windowConstraint: windowConstraint,
                    bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    forEmptyInputClick: true
                )
                guard self.isCurrentPastePopupRequest(requestID, generation: generation),
                      let assessedFocus,
                      self.pastePopupContextAllowsAction(
                        plugin: plugin,
                        targetContext: targetContext,
                        currentFocusedElement: assessedFocus.focusedElement,
                        assessment: assessedFocus.assessment,
                        windowSnapshot: windowSnapshot
                      ) else { return }
                PluginManager.shared.executePlugin(
                    plugin,
                    with: "",
                    targetProcessIdentifier: targetContext.processIdentifier,
                    targetFocusedElement: targetContext.focusedElement
                )
            }
        }, cancelPendingPopupWork: false)
    }

    private func pastePopupContextAllowsAction(
        plugin: Plugin,
        targetContext: MenuTargetContext,
        currentFocusedElement: AXUIElement,
        assessment: AccessibilityManager.FocusedElementAssessment,
        windowSnapshot: TextSelectionMonitor.FrontmostWindowSnapshot
    ) -> Bool {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard assessment.isEditableTextInput == true,
              !AccessibilityManager.shouldSuppressCopyFallback(
                focusedElementAssessment: assessment.protection,
                secureEventInputEnabled: AccessibilityManager.shared.isSecureEventInputEnabled(),
                accessibilityEnabled: AccessibilityManager.shared.isAccessibilityEnabled,
                allowMissingFocusedElement: false
              ), Self.shouldExecuteMenuAction(
                expectedProcessIdentifier: targetContext.processIdentifier,
                currentProcessIdentifier: frontmostApp?.processIdentifier,
                requiresOriginalFocusedElement: true,
                requiresEditableTarget: true,
                focusedElementMatches: AccessibilityManager.areSameAccessibilityElement(
                    targetContext.focusedElement, currentFocusedElement
                ),
                isFocusedSelectionEditable: assessment.isSelectionEditable
              ), Self.shouldAllowMenuPresentation(
                isEnabled: isEnabled,
                frontmostBundleID: frontmostApp?.bundleIdentifier,
                frontmostLocalizedName: frontmostApp?.localizedName,
                isFocusedSelectionEditable: assessment.isSelectionEditable
              ), Self.emptyInputPastePlugin(
                from: PluginManager.shared.plugins,
                appBundleID: frontmostApp?.bundleIdentifier
              )?.id == plugin.id else { return false }
        return TextSelectionMonitor.focusedWindowRetryDisposition(
            capturedWindow: windowSnapshot,
            currentTopmostWindow: TextSelectionMonitor.currentFrontmostWindowSnapshot(
                frontmostProcessID: frontmostApp?.processIdentifier
            ),
            accessibilityWindowMatches: true
        ) == .accept
    }

    nonisolated static func shouldCompletePastePopupRequest(
        requestID: UUID,
        currentRequestID: UUID?,
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestID == currentRequestID && isInteractionCurrent(
            expectedGeneration: expectedGeneration,
            currentGeneration: currentGeneration
        )
    }

    private func isCurrentPastePopupRequest(_ requestID: UUID, generation: UInt64) -> Bool {
        isEnabled && Self.shouldCompletePastePopupRequest(
            requestID: requestID,
            currentRequestID: pendingPastePopupRequestID,
            expectedGeneration: generation,
            currentGeneration: interactionGeneration,
            isCancelled: Task.isCancelled
        )
    }

    private func cancelPendingPastePopupWork() {
        pendingPastePopupTask?.cancel()
        pendingPastePopupTask = nil
        pendingPastePopupRequestID = nil
        if radialMenuWindow == nil, pastePopupWindow == nil {
            removeMenuDismissMonitors()
        }
    }

    private func finishPastePopupWork(_ requestID: UUID) {
        guard pendingPastePopupRequestID == requestID else { return }
        pendingPastePopupTask = nil
        pendingPastePopupRequestID = nil
        if radialMenuWindow == nil, pastePopupWindow == nil {
            removeMenuDismissMonitors()
        }
    }

    private func scheduleMenuPresentation(
        pastePopupRequestID: UUID? = nil,
        _ presentation: @escaping () -> Void
    ) {
        // The newest hotkey/selection wins while an older panel is fading out.
        cancelPendingPastePopupWork()
        pendingPastePopupRequestID = pastePopupRequestID
        if pastePopupRequestID != nil {
            setupMenuDismissMonitors()
        }
        pendingHotkeyFocusTask?.cancel()
        pendingHotkeyFocusTask = nil
        pendingHotkeyFocusRequestID = nil
        pendingMenuPresentation = presentation
        dismissAllMenus(cancelPendingPresentation: false, cancelPendingPopupWork: false)
    }

    private func presentPendingMenuIfNeeded() {
        guard !isDismissingMenus, let presentation = pendingMenuPresentation else { return }
        pendingMenuPresentation = nil
        presentation()
    }

    private func dismissAllMenus(
        completion: (() -> Void)? = nil,
        cancelPendingPresentation: Bool = true,
        cancelPendingPopupWork: Bool = true
    ) {
        if cancelPendingPopupWork {
            cancelPendingPastePopupWork()
        }
        if cancelPendingPresentation {
            pendingMenuPresentation = nil
        }
        guard beginMenuDismiss(completion: completion) else { return }

        let radialWindow = radialMenuWindow
        let popupWindow = pastePopupWindow
        radialMenuWindow = nil
        pastePopupWindow = nil
        // Keep outside-click/key cancellation alive while an approved paste is
        // fading out or validating its target asynchronously.
        if cancelPendingPopupWork || pendingPastePopupRequestID == nil {
            removeMenuDismissMonitors()
        }

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
    
    func handleMenuAction(
        _ item: RadialMenuItem,
        text: String,
        targetProcessIdentifier: pid_t?,
        targetFocusedElement: AXUIElement?
    ) {
        let requiresOriginalFocusedElement: Bool
        let requiresEditableTarget: Bool
        let isCopyAction: Bool
        switch item.action {
        case .builtIn(let action):
            isCopyAction = action == .copy
            requiresEditableTarget = action == .cut || action == .paste
            requiresOriginalFocusedElement = requiresEditableTarget
        case .plugin(let plugin):
            isCopyAction = plugin.action.type == .copy
            requiresEditableTarget = Self.pluginRequiresEditableTarget(plugin)
            requiresOriginalFocusedElement = Self.pluginRequiresOriginalFocusedElement(plugin)
        default:
            isCopyAction = false
            requiresEditableTarget = false
            requiresOriginalFocusedElement = false
        }
        // Explicit copy uses the captured selection even while source focus changes.
        // Read AX state only when this action needs it. Read-only actions use
        // the captured text and should not wait for another application's IPC.
        guard isCopyAction || Self.shouldExecuteMenuAction(
            expectedProcessIdentifier: targetProcessIdentifier,
            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            requiresOriginalFocusedElement: requiresOriginalFocusedElement,
            requiresEditableTarget: requiresEditableTarget,
            focusedElementMatches: AccessibilityManager.areSameAccessibilityElement(
                targetFocusedElement,
                AccessibilityManager.shared.getFocusedElement(
                    expectedProcessIdentifier: targetProcessIdentifier
                )
            ),
            isFocusedSelectionEditable: targetFocusedElement.map {
                AccessibilityManager.shared.isSelectionEditable($0)
            } ?? false
        ) else {
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
                        targetProcessIdentifier: targetProcessIdentifier,
                        targetFocusedElement: targetFocusedElement
                    )
                }
            } else {
                PluginManager.shared.executePlugin(
                    plugin,
                    with: text,
                    targetProcessIdentifier: targetProcessIdentifier,
                    targetFocusedElement: targetFocusedElement
                )
                dismissAllMenus()
            }
        default:
            dismissAllMenus()
            break
        }
    }
    
    // MARK: - Menu Dismissal Monitors
    
    private func setupMenuDismissMonitors() {
        removeMenuDismissMonitors()
        let monitorGeneration = menuDismissMonitorGeneration
        globalMenuDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.menuDismissEventMask) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.menuDismissMonitorGeneration == monitorGeneration else { return }
                self.handleMenuDismissEvent(event)
            }
        }
        // Global monitors exclude events delivered to our panels and settings windows.
        localMenuDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.menuDismissEventMask) { [weak self] event in
            self?.handleMenuDismissEvent(event)
            return event
        }
    }

    func handleMenuDismissEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           let cgEvent = event.cgEvent {
            let point = event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? AccessibilityManager.appKitScreenPoint(for: cgEvent.location)
                ?? event.locationInWindow
            _ = handlePhysicalMouseDownStarted(cgEvent.type, at: point, timestamp: cgEvent.timestamp)
        } else if Self.shouldDismissMenus(
            for: event, radialMenuWindow: radialMenuWindow, pastePopupWindow: pastePopupWindow
        ) {
            dismissAllMenus()
        }
    }
    
    private func removeMenuDismissMonitors() {
        menuDismissMonitorGeneration &+= 1
        if let monitor = globalMenuDismissMonitor {
            NSEvent.removeMonitor(monitor)
            globalMenuDismissMonitor = nil
        }
        if let monitor = localMenuDismissMonitor {
            NSEvent.removeMonitor(monitor)
            localMenuDismissMonitor = nil
        }
    }

    static func shouldDismissMenus(
        for event: NSEvent,
        radialMenuWindow: RadialMenuWindow?,
        pastePopupWindow: PastePopupWindow?
    ) -> Bool {
        switch event.type {
        case .flagsChanged:
            return radialMenuWindow == nil
        case .keyDown:
            // Explicit keyboard menus handle navigation and dismissal in the view.
            return !(radialMenuWindow?.canBecomeKey == true &&
                event.window === radialMenuWindow &&
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if pastePopupWindow != nil, event.type != .leftMouseDown { return true }
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow)
                ?? event.cgEvent.flatMap { AccessibilityManager.appKitScreenPoint(for: $0.location) }
                ?? event.locationInWindow
            return shouldDismissMenus(
                atScreenPoint: screenPoint,
                radialMenuWindow: radialMenuWindow,
                pastePopupWindow: pastePopupWindow
            )
        case .scrollWheel:
            return true
        default:
            return false
        }
    }

    static func shouldDismissMenus(
        atScreenPoint point: NSPoint,
        radialMenuWindow: RadialMenuWindow?,
        pastePopupWindow: PastePopupWindow?
    ) -> Bool {
        if let radialMenuWindow {
            return radialMenuWindow.shouldDismissClick(at: radialMenuWindow.convertPoint(fromScreen: point))
        }
        if let pastePopupWindow {
            return !pastePopupWindow.frame.contains(point)
        }
        return true
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
            NSLog("[ActionHalo] App version changed from \(lastVersion ?? "none") to \(currentVersion). Keeping Accessibility permissions untouched.")
            return
        }

        NSLog("[ActionHalo] App updated from \(lastVersion ?? "none") to \(currentVersion). Resetting TCC permissions before prompting so stale Accessibility entries do not mislead the user.")

        if resetAccessibilityPermissions() {
            UserDefaults.standard.set(currentVersion, forKey: "LastRunVersion")
        }
    }

    @discardableResult
    private func resetAccessibilityPermissions() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = Self.accessibilityResetArguments(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.actionhalo.app"
        )

        do {
            guard let terminationStatus = try Self.runProcess(task, timeout: 3) else {
                NSLog("[ActionHalo] Failed to reset Accessibility TCC: tccutil timed out.")
                return false
            }
            guard terminationStatus == 0 else {
                NSLog("[ActionHalo] Failed to reset Accessibility TCC: tccutil exited with status \(terminationStatus)")
                return false
            }
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            UserDefaults.standard.set(currentVersion, forKey: Self.lastAccessibilityResetVersionKey)
            return true
        } catch {
            NSLog("[ActionHalo] Failed to reset Accessibility TCC: \(error.localizedDescription)")
            return false
        }
    }
}
