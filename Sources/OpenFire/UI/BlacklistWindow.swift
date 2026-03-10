import Cocoa

/// A dedicated window to manage apps where OpenFire has been disabled.
final class BlacklistWindow: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    
    private let tableView = NSTableView()
    private var excludedApps: [String] = []
    private let rowHeight: CGFloat = 40
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "App Blacklist".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        
        super.init(window: window)
        setupUI()
        loadData()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // App header description
        let label = NSTextField(labelWithString: "The OpenFire radial menu will not appear when selecting text in the following apps:".localized)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 260, width: 320, height: 20)
        contentView.addSubview(label)
        
        // Add App Button (+)
        let addBtn = NSButton(frame: NSRect(x: 350, y: 257, width: 30, height: 24))
        addBtn.bezelStyle = .inline
        addBtn.isBordered = false
        addBtn.title = ""
        if let addIcon = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add App") {
            addBtn.image = addIcon.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        }
        addBtn.contentTintColor = .systemBlue
        addBtn.target = self
        addBtn.action = #selector(addAppClicked)
        contentView.addSubview(addBtn)
        
        // ScrollView + TableView
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 360, height: 230))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        col.title = "Bundle ID"
        col.width = 340
        tableView.addTableColumn(col)
        
        tableView.headerView = nil // Hide header
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = rowHeight
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }
    
    private func loadData() {
        excludedApps = UserDefaults.standard.stringArray(forKey: "ExcludedApps") ?? []
        tableView.reloadData()
    }
    
    // MARK: - NSTableView DataSource & Delegate
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return excludedApps.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row < 0 || row >= excludedApps.count { return nil }
        let bundleID = excludedApps[row]
        
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: rowHeight))
        
        // Attempt to get app name and icon
        var appName = bundleID
        var appIcon: NSImage? = nil
        if let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appName = Bundle(url: workspaceURL)?.infoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: workspaceURL)?.infoDictionary?["CFBundleName"] as? String
                ?? workspaceURL.deletingPathExtension().lastPathComponent
            
            appIcon = NSWorkspace.shared.icon(forFile: workspaceURL.path)
            appIcon?.size = NSSize(width: 24, height: 24)
        } else {
            // Generic icon fallback
            appIcon = NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericApplicationIcon)))
            appIcon?.size = NSSize(width: 24, height: 24)
        }
        
        // Icon Image
        let iconView = NSImageView(frame: NSRect(x: 10, y: 8, width: 24, height: 24))
        iconView.image = appIcon
        cell.addSubview(iconView)
        
        // App Name Label
        let nameLabel = NSTextField(labelWithString: appName)
        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        nameLabel.frame = NSRect(x: 44, y: 18, width: 230, height: 18)
        cell.addSubview(nameLabel)
        
        // Bundle ID Label
        let bundleLabel = NSTextField(labelWithString: bundleID)
        bundleLabel.font = NSFont.systemFont(ofSize: 10)
        bundleLabel.textColor = .tertiaryLabelColor
        bundleLabel.frame = NSRect(x: 44, y: 4, width: 230, height: 14)
        cell.addSubview(bundleLabel)
        
        // Delete Button
        let deleteBtn = NSButton(frame: NSRect(x: 300, y: 8, width: 24, height: 24))
        deleteBtn.bezelStyle = .inline
        deleteBtn.isBordered = false
        deleteBtn.title = ""
        if let delImg = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove") {
            deleteBtn.image = delImg.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        }
        deleteBtn.contentTintColor = .systemRed.withAlphaComponent(0.8)
        deleteBtn.target = self
        deleteBtn.action = #selector(removeAppClicked(_:))
        cell.addSubview(deleteBtn)
        
        return cell
    }
    
    @objc private func removeAppClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 && row < excludedApps.count else { return }
        
        excludedApps.remove(at: row)
        UserDefaults.standard.set(excludedApps, forKey: "ExcludedApps")
        
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .slideUp)
    }
    
    @objc private func addAppClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Please select the application to disable OpenFire in".localized
        
        panel.beginSheetModal(for: self.window!) { [weak self] response in
            if response == .OK {
                guard let self = self else { return }
                var addedCount = 0
                for url in panel.urls {
                    if let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
                        if !self.excludedApps.contains(bundleID) {
                            self.excludedApps.append(bundleID)
                            addedCount += 1
                        }
                    }
                }
                
                if addedCount > 0 {
                    UserDefaults.standard.set(self.excludedApps, forKey: "ExcludedApps")
                    self.tableView.reloadData()
                }
            }
        }
    }
    
    override func showWindow(_ sender: Any?) {
        loadData()
        super.showWindow(sender)
    }
}
