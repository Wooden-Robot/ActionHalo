import Cocoa

/// Controls the menu bar status item — plugin management via embedded submenu view
final class StatusBarController: NSObject {
    private static let wheelBackdropEnabledKey = "WheelBackdropEnabled"
    
    private var statusItem: NSStatusItem?
    private var mainMenu: NSMenu?
    private var isEnabled = true
    private var hotkeyRecorderWindow: HotkeyRecorderWindow?
    private var pluginListView: PluginListMenuView?
    private var excludeAppItem: NSMenuItem?
    private var blacklistWindow: BlacklistWindow?
    
    var onEnabledChanged: ((Bool) -> Void)?
    
    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "OpenFire")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        rebuildMenu()
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(pluginsChanged),
            name: PluginManager.pluginsReloadedNotification, object: nil
        )
    }
    
    @objc private func pluginsChanged() {
        pluginListView?.reloadPlugins()
    }
    
    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        
        // Title
        let titleItem = NSMenuItem(title: "OpenFire 🔥", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        
        // Launch at Login
        let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.openfire.app.plist")
        let isLaunchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)
        
        let launchItem = NSMenuItem(
            title: isLaunchAtLogin ? "✓ Launch at Login".localized : "Launch at Login".localized,
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        menu.addItem(launchItem)
        menu.addItem(NSMenuItem.separator())

        // Auto Check Updates toggle (placed below Launch at Login)
        let autoCheckEnabled = UpdateChecker.shared.isAutoCheckEnabled()
        let autoCheckTitle = autoCheckEnabled ? "✓ Auto Check Updates".localized : "Auto Check Updates".localized
        let autoCheckItem = NSMenuItem(title: autoCheckTitle, action: #selector(toggleAutoCheckUpdates), keyEquivalent: "")
        autoCheckItem.target = self
        menu.addItem(autoCheckItem)
        menu.addItem(NSMenuItem.separator())
        
        // Enable/Disable
        let toggleItem = NSMenuItem(
            title: isEnabled ? "✅ Enabled".localized : "⏸ Disabled".localized,
            action: #selector(toggleEnabled), 
            keyEquivalent: HotkeyManager.shared.toggleHotkeyEquivalent
        )
        toggleItem.keyEquivalentModifierMask = HotkeyManager.shared.toggleHotkeyModifierFlags
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        // Exclude App
        let excludeItem = NSMenuItem(title: "Disable in Current App".localized, action: #selector(toggleExcludeActiveApp), keyEquivalent: "")
        excludeItem.target = self
        excludeAppItem = excludeItem
        menu.addItem(excludeItem)
        
        // Manage Excluded Apps
        let manageExcludeItem = NSMenuItem(title: "Manage Disabled Apps...".localized, action: #selector(openBlacklistWindow), keyEquivalent: "")
        manageExcludeItem.target = self
        menu.addItem(manageExcludeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Plugin management — submenu with embedded interactive list
        let pluginMenuItem = NSMenuItem(title: "Plugin Management".localized, action: nil, keyEquivalent: "")
        let pluginSubmenu = NSMenu()
        
        // Create a custom view menu item for the interactive plugin list
        let listView = PluginListMenuView(frame: NSRect(x: 0, y: 0, width: 220, height: 200))
        listView.reloadPlugins()
        pluginListView = listView
        
        let viewItem = NSMenuItem()
        viewItem.view = listView
        pluginSubmenu.addItem(viewItem)
        
        // Hint at bottom
        pluginSubmenu.addItem(NSMenuItem.separator())
        let hintItem = NSMenuItem(title: "Click to toggle · Drag to reorder".localized, action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        pluginSubmenu.addItem(hintItem)
        
        pluginMenuItem.submenu = pluginSubmenu
        menu.addItem(pluginMenuItem)
        
        // Open plugins folder
        let openFolderItem = NSMenuItem(title: "Open Plugins Folder".localized, action: #selector(openPluginsFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Ring Transparency submenu
        let opacityMenu = NSMenu()
        // 100% transparent = 0.0 alpha, 0% transparent (solid) = 1.0 alpha
        let opacities: [(String, Double)] = [("0% (Opaque)".localized, 1.0), ("25%", 0.75), ("50%", 0.50), ("75%", 0.25), ("100% (Transparent)".localized, 0.0)]
        let currentOpacity = UserDefaults.standard.object(forKey: "ringOpacity") as? Double ?? 0.25
        let backdropEnabled = UserDefaults.standard.object(forKey: Self.wheelBackdropEnabledKey) as? Bool ?? true
        
        for (title, value) in opacities {
            let item = NSMenuItem(title: title, action: #selector(setRingOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(currentOpacity - value) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        
        let opacityMenuItem = NSMenuItem(title: "Ring Opacity".localized, action: nil, keyEquivalent: "")
        opacityMenuItem.submenu = opacityMenu
        opacityMenuItem.isEnabled = !backdropEnabled
        menu.addItem(opacityMenuItem)
        
        let backdropTitle = backdropEnabled ? "✓ GTA Mode".localized : "GTA Mode".localized
        let backdropItem = NSMenuItem(title: backdropTitle, action: #selector(toggleWheelBackdrop), keyEquivalent: "")
        backdropItem.target = self
        menu.addItem(backdropItem)
        menu.addItem(NSMenuItem.separator())
        
        // Max Items submenu
        let maxItemsMenu = NSMenu()
        let maxItemOptions = [6, 8, 12, 16]
        let currentMaxItems = UserDefaults.standard.integer(forKey: "maxRadialMenuItems")
        let activeMaxItems = currentMaxItems == 0 ? 12 : currentMaxItems
        
        for limit in maxItemOptions {
            let title = limit == 12 ? "12 (Default)".localized : "\(limit)".localized
            let item = NSMenuItem(title: title, action: #selector(setMaxItems(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = limit
            item.state = (activeMaxItems == limit) ? .on : .off
            maxItemsMenu.addItem(item)
        }
        
        let maxItemsMenuItem = NSMenuItem(title: "Max Items in Menu".localized, action: nil, keyEquivalent: "")
        maxItemsMenuItem.submenu = maxItemsMenu
        menu.addItem(maxItemsMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        // Language submenu
        let langMenu = NSMenu()
        let languages: [(String, String)] = [
            ("Auto (Follow System)".localized, "auto"),
            ("English", "en"),
            ("简体中文", "zh-Hans")
        ]
        let currentLang = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        
        for (title, value) in languages {
            let item = NSMenuItem(title: title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = (currentLang == value) ? .on : .off
            langMenu.addItem(item)
        }
        
        let langMenuItem = NSMenuItem(title: "Language / 语言".localized, action: nil, keyEquivalent: "")
        langMenuItem.submenu = langMenu
        menu.addItem(langMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        // Hotkeys
        let hotkeyDesc = HotkeyManager.shared.hotkeyDescription
        let hotkeyItem = NSMenuItem(
            title: String(format: "Menu Hotkey: %@".localized, hotkeyDesc),
            action: #selector(setHotkey), keyEquivalent: ""
        )
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)
        
        let toggleHotkeyDesc = HotkeyManager.shared.toggleHotkeyDescription
        let toggleHotkeyItem = NSMenuItem(
            title: String(format: "Toggle Hotkey: %@".localized, toggleHotkeyDesc),
            action: #selector(setToggleHotkey), keyEquivalent: ""
        )
        toggleHotkeyItem.target = self
        menu.addItem(toggleHotkeyItem)
        
        // Check for Updates
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...".localized, action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit OpenFire".localized, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        mainMenu = menu
    }
    
    // MARK: - Actions
    
    @objc func toggleEnabled() {
        isEnabled.toggle()
        onEnabledChanged?(isEnabled)
        rebuildMenu()
        
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: isEnabled ? "flame.fill" : "flame",
                accessibilityDescription: "OpenFire"
            )
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            toggleEnabled()
        default:
            presentMainMenu()
        }
    }

    private func presentMainMenu() {
        guard let statusItem, let button = statusItem.button, let menu = mainMenu else { return }
        statusItem.menu = menu
        button.performClick(nil)
    }
    
    @objc private func toggleLaunchAtLogin() {
        let fileManager = FileManager.default
        let launchAgentsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsURL.appendingPathComponent("com.openfire.app.plist")
        
        do {
            if fileManager.fileExists(atPath: plistURL.path) {
                // If it exists, disable by removing it
                try fileManager.removeItem(at: plistURL)
            } else {
                // If it doesn't exist, enable by creating it
                try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
                let bundlePath = Bundle.main.bundlePath
                
                let plistString = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>com.openfire.app</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>/usr/bin/open</string>
                        <string>\(bundlePath)</string>
                    </array>
                    <key>RunAtLoad</key>
                    <true/>
                </dict>
                </plist>
                """
                
                try plistString.write(to: plistURL, atomically: true, encoding: .utf8)
            }
            rebuildMenu()
        } catch {
            NSLog("[OpenFire] Failed to toggle launch at login: \(error)")
            let alert = NSAlert()
            alert.messageText = "Failed to Set Launch at Login".localized
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK".localized)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates(showUpToDate: true, showErrors: true)
    }

    @objc private func toggleAutoCheckUpdates() {
        let defaults = UserDefaults.standard
        let enabled = UpdateChecker.shared.isAutoCheckEnabled()
        defaults.set(!enabled, forKey: UpdateChecker.autoCheckEnabledKey)
        rebuildMenu()
    }
    
    @objc private func openPluginsFolder() {
        let url = PluginManager.shared.userPluginsURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    
    @objc private func setRingOpacity(_ sender: NSMenuItem) {
        let backdropEnabled = UserDefaults.standard.object(forKey: Self.wheelBackdropEnabledKey) as? Bool ?? true
        guard !backdropEnabled else { return }
        if let opacity = sender.representedObject as? Double {
            UserDefaults.standard.set(opacity, forKey: "ringOpacity")
            rebuildMenu()
        }
    }
    
    @objc private func toggleWheelBackdrop() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Self.wheelBackdropEnabledKey) as? Bool ?? true
        defaults.set(!enabled, forKey: Self.wheelBackdropEnabledKey)
        rebuildMenu()
    }
    
    @objc private func setMaxItems(_ sender: NSMenuItem) {
        if let limit = sender.representedObject as? Int {
            UserDefaults.standard.set(limit, forKey: "maxRadialMenuItems")
            UserDefaults.standard.synchronize()
            rebuildMenu()
            // Force a reload so the active plugin list is truncated immediately
            PluginManager.shared.reloadPlugins()
        }
    }
    
    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let langCode = sender.representedObject as? String else { return }
        
        let currentLang = UserDefaults.standard.string(forKey: "AppLanguage") ?? "auto"
        if currentLang == langCode { return }
        
        UserDefaults.standard.set(langCode, forKey: "AppLanguage")
        UserDefaults.standard.synchronize()
        
        let alert = NSAlert()
        alert.messageText = "Language Changed".localized
        alert.informativeText = "The application needs to restart to apply the new language globally.".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now".localized)
        alert.addButton(withTitle: "Later".localized)
        
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        } else {
            rebuildMenu() // Update the checkmarks immediately at least
        }
    }
    
    // Programmatically relaunch the app
    private func relaunchApp() {
        let task = Process()
        let executablePath = Bundle.main.executablePath!
        task.launchPath = executablePath
        task.launch()
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func setHotkey() {
        let recorder = HotkeyRecorderWindow(title: "Set Menu Hotkey".localized)
        recorder.onHotkeyRecorded = { [weak self] keyCode, modifiers in
            if keyCode == 0 && modifiers == 0 {
                HotkeyManager.shared.hotkey = nil
            } else {
                HotkeyManager.shared.hotkey = (keyCode, modifiers)
            }
            HotkeyManager.shared.registerHotkeys()
            self?.rebuildMenu()
        }
        recorder.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hotkeyRecorderWindow = recorder
    }
    
    @objc private func setToggleHotkey() {
        let recorder = HotkeyRecorderWindow(title: "Set Toggle Hotkey".localized)
        recorder.onHotkeyRecorded = { [weak self] keyCode, modifiers in
            if keyCode == 0 && modifiers == 0 {
                HotkeyManager.shared.toggleHotkey = nil
            } else {
                HotkeyManager.shared.toggleHotkey = (keyCode, modifiers)
            }
            HotkeyManager.shared.registerHotkeys()
            self?.rebuildMenu()
        }
        recorder.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hotkeyRecorderWindow = recorder
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func toggleExcludeActiveApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        
        var excluded = UserDefaults.standard.stringArray(forKey: "ExcludedApps") ?? []
        if excluded.contains(bundleID) {
            excluded.removeAll { $0 == bundleID }
        } else {
            excluded.append(bundleID)
        }
        UserDefaults.standard.set(excluded, forKey: "ExcludedApps")
        
        // Refresh blacklist window if it is open
        blacklistWindow?.showWindow(nil)
    }
    
    @objc private func openBlacklistWindow() {
        if blacklistWindow == nil {
            blacklistWindow = BlacklistWindow()
        }
        blacklistWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard let item = excludeAppItem else { return }
        
        if let app = NSWorkspace.shared.frontmostApplication,
           let appName = app.localizedName,
           let bundleID = app.bundleIdentifier {
            
            let excluded = UserDefaults.standard.stringArray(forKey: "ExcludedApps") ?? []
            let isExcluded = excluded.contains(bundleID)
            
            item.title = isExcluded ? String(format: "Enable in %@".localized, appName) : String(format: "Disable in %@".localized, appName)
            item.state = isExcluded ? .on : .off
            item.isHidden = false
        } else {
            item.isHidden = true
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === mainMenu {
            statusItem?.menu = nil
        }
    }
}
