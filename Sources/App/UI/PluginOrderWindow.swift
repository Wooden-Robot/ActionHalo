import Cocoa

/// Custom NSView embedded inside a menu item to provide an interactive plugin list
/// with click-to-toggle and drag-to-reorder functionality
final class PluginListMenuView: NSView, NSTableViewDelegate, NSTableViewDataSource {
    struct ReorderResult {
        let plugins: [Plugin]
        let targetRow: Int
    }
    
    private let tableView = NSTableView()
    private var orderedPlugins: [Plugin] = []
    private let dragType = NSPasteboard.PasteboardType("com.openfire.plugin-row")
    private let rowHeight: CGFloat = 28
    private let viewWidth: CGFloat = 300
    private let buttonHeight: CGFloat = 36
    private let iconLeadingX: CGFloat = 42
    private let nameLeadingX: CGFloat = 68
    private let actionButtonSize: CGFloat = 24
    private let actionButtonSpacing: CGFloat = 6
    private let dragHandleWidth: CGFloat = 16
    private let trailingPadding: CGFloat = 8
    
    private var editorWindow: PluginEditorWindow?
    private var trustStatuses: [String: Bool] = [:]
    private var trustStatusGeneration: UInt64 = 0
    
    /// Flag to suppress notification-triggered reload during drag reorder
    private var isReordering = false
    
    /// Throttle auto-scroll during drag to prevent instant jump to top/bottom
    private var lastAutoScrollTime: TimeInterval = 0
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    static func reorderedPlugins(_ plugins: [Plugin], sourceRow: Int, proposedRow: Int) -> ReorderResult? {
        guard plugins.indices.contains(sourceRow),
              proposedRow >= 0,
              proposedRow <= plugins.count else {
            return nil
        }

        var reordered = plugins
        let plugin = reordered.remove(at: sourceRow)
        let targetRow = sourceRow < proposedRow ? proposedRow - 1 : proposedRow

        guard targetRow >= 0, targetRow <= reordered.count else {
            return nil
        }

        reordered.insert(plugin, at: targetRow)
        return ReorderResult(plugins: reordered, targetRow: targetRow)
    }

    static func shouldAllowEditing(_ plugin: Plugin) -> Bool {
        !PluginManager.isReservedCorePluginIdentifier(plugin.id)
    }
    
    private func setupUI() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pluginsChanged),
            name: PluginManager.pluginsReloadedNotification,
            object: nil
        )

        let scrollView = NSScrollView()
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .legacy
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin"))
        col.width = viewWidth - 20
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = rowHeight
        tableView.registerForDraggedTypes([dragType])
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .none
        tableView.target = self
        tableView.action = #selector(rowClicked)
        
        scrollView.documentView = tableView
        addSubview(scrollView)
        
        let addBtn = NSButton(title: "┼ New Custom Plugin".localized, target: self, action: #selector(addPluginClicked))
        addBtn.bezelStyle = .recessed
        addBtn.showsBorderOnlyWhileMouseInside = true
        addBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        addBtn.frame = NSRect(x: 10, y: 0, width: viewWidth - 20, height: buttonHeight)
        addBtn.autoresizingMask = [.width, .maxYMargin]
        addSubview(addBtn)
    }
    
    @objc private func addPluginClicked() {
        let editor = PluginEditorWindow()
        editor.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow = editor
    }

    @objc private func pluginsChanged() {
        if Thread.isMainThread {
            reloadPlugins()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadPlugins()
            }
        }
    }
    
    /// Reload with current plugins
    func reloadPlugins() {
        // During drag reorder, skip reload entirely to preserve scroll position
        guard !isReordering else { return }
        
        orderedPlugins = getOrderedPlugins()
        refreshTrustStatuses()
        
        // Resize view to fit all plugins (max 10 visible) + Add button
        let visibleCount = min(orderedPlugins.count, 10)
        let listHeight = CGFloat(visibleCount) * (rowHeight + 1)
        let totalHeight = listHeight + buttonHeight
        
        frame = NSRect(x: 0, y: 0, width: viewWidth, height: totalHeight)
        
        // Update ScrollView frame
        if let sv = subviews.compactMap({ $0 as? NSScrollView }).first {
            sv.frame = NSRect(x: 0, y: buttonHeight, width: viewWidth, height: listHeight)
        }
        
        tableView.reloadData()
    }

    private func refreshTrustStatuses() {
        trustStatusGeneration &+= 1
        let generation = trustStatusGeneration
        let protectedPlugins = orderedPlugins.filter(\.requiresExecutionTrust)
        trustStatuses = [:]

        guard !protectedPlugins.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var statuses: [String: Bool] = [:]
            for plugin in protectedPlugins {
                statuses[plugin.id] = PluginManager.shared.isExecutionTrusted(for: plugin)
            }

            DispatchQueue.main.async {
                guard let self, self.trustStatusGeneration == generation else { return }
                self.trustStatuses = statuses
                self.tableView.reloadData()
            }
        }
    }
    
    private func getOrderedPlugins() -> [Plugin] {
        PluginManager.shared.orderedPluginsForDisplay()
    }
    
    private func saveOrder() {
        UserDefaults.standard.set(orderedPlugins.map { $0.id }, forKey: "pluginOrder")
        NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: nil)
    }
    
    // MARK: - Actions
    
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < orderedPlugins.count else { return }
        let plugin = orderedPlugins[row]
        PluginManager.shared.setPluginEnabled(plugin.id, enabled: !plugin.isEnabled)
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }
    
    @objc private func editPluginClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 && row < orderedPlugins.count else { return }
        let plugin = orderedPlugins[row]
        guard Self.shouldAllowEditing(plugin) else { return }
        
        let editor = PluginEditorWindow(plugin: plugin)
        editor.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow = editor
    }

    @objc private func showTrustStatus(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 && row < orderedPlugins.count else { return }
        let plugin = orderedPlugins[row]
        guard let isTrusted = trustStatuses[plugin.id] else {
            NSSound.beep()
            refreshTrustStatuses()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Plugin Trust".localized
        alert.informativeText = String(
            format: "Plugin '%@' uses protected actions.\n\nCurrent status: %@\nLocation: %@".localized,
            plugin.name,
            isTrusted ? "Trusted".localized : "Not Trusted".localized,
            plugin.directoryURL.path
        )
        alert.alertStyle = .informational

        if isTrusted {
            alert.addButton(withTitle: "Revoke Trust".localized)
            alert.addButton(withTitle: "OK".localized)
        } else {
            alert.addButton(withTitle: "OK".localized)
        }

        let response = alert.runModal()
        if isTrusted, response == .alertFirstButtonReturn {
            PluginManager.shared.setExecutionTrusted(false, for: plugin)
            trustStatuses[plugin.id] = false
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    private func styleTrustButton(_ button: NSButton, trusted: Bool?) {
        button.wantsLayer = true
        button.isBordered = false
        button.bezelStyle = .inline
        button.layer?.cornerRadius = 7
        button.layer?.masksToBounds = false

        let tint: NSColor
        if let trusted {
            tint = trusted ? .systemGreen : .systemOrange
        } else {
            tint = .tertiaryLabelColor
        }
        button.contentTintColor = tint
        button.layer?.backgroundColor = tint.withAlphaComponent(trusted == true ? 0.16 : 0.22).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = tint.withAlphaComponent(trusted == true ? 0.28 : 0.4).cgColor
        button.layer?.shadowColor = tint.cgColor
        button.layer?.shadowOpacity = trusted == true ? 0.18 : 0.28
        button.layer?.shadowRadius = trusted == true ? 4 : 6
        button.layer?.shadowOffset = .zero
    }
    
    // MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        orderedPlugins.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let plugin = orderedPlugins[row]
        
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: rowHeight))
        
        // Position number (tagged for in-place update during drag reorder)
        let numLabel = NSTextField(labelWithString: "\(row + 1)")
        numLabel.frame = NSRect(x: 4, y: 5, width: 16, height: 18)
        numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        numLabel.textColor = .tertiaryLabelColor
        numLabel.alignment = .right
        numLabel.tag = 999
        cell.addSubview(numLabel)
        
        // Enabled indicator
        let indicator = NSTextField(labelWithString: plugin.isEnabled ? "●" : "○")
        indicator.frame = NSRect(x: 24, y: 5, width: 14, height: 18)
        indicator.font = NSFont.systemFont(ofSize: 10)
        indicator.textColor = plugin.isEnabled ? NSColor.systemBlue : .tertiaryLabelColor
        cell.addSubview(indicator)
        
        // Icon
        let iconView = NSImageView(frame: NSRect(x: iconLeadingX, y: 3, width: 22, height: 22))
        let customIconPath = plugin.directoryURL.appendingPathComponent("icon.png")
        
        if FileManager.default.fileExists(atPath: customIconPath.path), let img = NSImage(contentsOf: customIconPath) {
            iconView.image = img
            if !plugin.isEnabled {
                iconView.alphaValue = 0.4
            }
        } else if let img = NSImage(systemSymbolName: plugin.iconName, accessibilityDescription: plugin.name) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
            iconView.contentTintColor = plugin.isEnabled ? .labelColor : .quaternaryLabelColor
        }
        cell.addSubview(iconView)
        let isCoreDefaultPlugin = PluginManager.isReservedCorePluginIdentifier(plugin.id)
        let showDeleteButton = !isCoreDefaultPlugin
        let showEditButton = Self.shouldAllowEditing(plugin)
        let showsTrustButton = plugin.requiresExecutionTrust
        let actionButtonCount =
            (showEditButton ? 1 : 0) +
            (showDeleteButton ? 1 : 0) +
            (showsTrustButton ? 1 : 0)
        let actionAreaWidth =
            CGFloat(actionButtonCount) * actionButtonSize +
            CGFloat(max(0, actionButtonCount - 1)) * actionButtonSpacing +
            CGFloat(actionButtonCount > 0 ? actionButtonSpacing : 0) +
            dragHandleWidth +
            trailingPadding
        
        // Name
        let nameField = NSTextField(labelWithString: plugin.name)
        let nameWidth = max(70, viewWidth - nameLeadingX - actionAreaWidth - 10)
        nameField.frame = NSRect(x: nameLeadingX, y: 5, width: nameWidth, height: 18)
        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.textColor = plugin.isEnabled ? .labelColor : .tertiaryLabelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.usesSingleLineMode = true
        nameField.toolTip = "\(plugin.name)\n\(plugin.id)"
        cell.addSubview(nameField)
        cell.toolTip = "\(plugin.name)\n\(plugin.id)"

        let handleX = viewWidth - trailingPadding - dragHandleWidth
        var actionX = handleX - actionButtonSpacing - actionButtonSize

        let editX: CGFloat?
        if showEditButton {
            editX = actionX
            actionX -= actionButtonSize + actionButtonSpacing
        } else {
            editX = nil
        }

        if showDeleteButton {
            // Delete Button (Trash)
            let deleteBtn = NSButton(frame: NSRect(x: actionX, y: 2, width: 24, height: 24))
            deleteBtn.bezelStyle = .inline
            deleteBtn.isBordered = false
            deleteBtn.title = ""
            if let delImg = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete") {
                deleteBtn.image = delImg.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            }
            deleteBtn.contentTintColor = .systemRed.withAlphaComponent(0.8)
            deleteBtn.toolTip = "Delete".localized
            deleteBtn.target = self
            deleteBtn.action = #selector(deletePluginClicked(_:))
            cell.addSubview(deleteBtn)
            actionX -= actionButtonSize + actionButtonSpacing
        }

        if showsTrustButton {
            let trustBtn = NSButton(frame: NSRect(x: actionX, y: 2, width: 24, height: 24))
            trustBtn.title = ""
            let trusted = trustStatuses[plugin.id]
            let symbolName: String
            if let trusted {
                symbolName = trusted ? "checkmark.shield" : "exclamationmark.shield"
            } else {
                symbolName = "ellipsis.circle"
            }
            if let trustImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Plugin Trust".localized) {
                trustBtn.image = trustImg.withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
            }
            styleTrustButton(trustBtn, trusted: trusted)
            trustBtn.target = self
            trustBtn.action = #selector(showTrustStatus(_:))
            if let trusted {
                trustBtn.toolTip = trusted
                    ? "Trusted protected-action plugin".localized
                    : "Plugin needs trust before running".localized
            } else {
                trustBtn.toolTip = "Checking plugin trust status".localized
            }
            cell.addSubview(trustBtn)
        }
        
        if let editX {
            // Edit Button (Pencil)
            let editBtn = NSButton(frame: NSRect(x: editX, y: 2, width: 24, height: 24))
            editBtn.bezelStyle = .inline
            editBtn.isBordered = false
            editBtn.title = ""
            if let editImg = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit") {
                editBtn.image = editImg.withSymbolConfiguration(.init(pointSize: 15, weight: .bold)) // Thickened pencil
            }
            editBtn.toolTip = "Edit".localized
            editBtn.target = self
            editBtn.action = #selector(editPluginClicked(_:))
            cell.addSubview(editBtn)
        }
        
        // Drag handle hint
        let handle = NSTextField(labelWithString: "⋮⋮")
        handle.frame = NSRect(x: handleX, y: 5, width: dragHandleWidth, height: 18)
        handle.font = NSFont.systemFont(ofSize: 10)
        handle.textColor = .quaternaryLabelColor
        cell.addSubview(handle)
        
        return cell
    }
    
    @objc private func deletePluginClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 && row < orderedPlugins.count else { return }
        let plugin = orderedPlugins[row]
        
        let isBuiltIn = PluginManager.isBuiltInPluginDirectory(plugin.directoryURL)
        let hasUserOverride = PluginManager.shared.userPluginURL(for: plugin.id) != nil
        
        // If it's a core default plugin, it can never be deleted
        if PluginManager.coreDefaultPluginIDs.contains(plugin.id) {
            let alert = NSAlert()
            alert.messageText = "Core Plugin Cannot Be Deleted".localized
            alert.informativeText = "This is a core system plugin and cannot be completely deleted. If you don't want to use it, please click the circle on the left to disable it.".localized
            alert.alertStyle = .informational
            // Make sure the window popup is ordered correctly by making our table view's window the key
            if let w = self.window {
                alert.beginSheetModal(for: w)
            } else {
                alert.runModal()
            }
            return
        }
        
        // Let PluginManager handle the actual file/soft deletion logic depending on whether it has an override
        let alert = NSAlert()
        alert.messageText = isBuiltIn && !hasUserOverride ? "Delete Built-in Plugin?".localized : (hasUserOverride && isBuiltIn ? "Restore Default?".localized : "Delete Plugin?".localized)
        alert.informativeText = isBuiltIn && !hasUserOverride ? "Are you sure you want to delete this built-in plugin? It will still exist but will be hidden from the list.".localized : (hasUserOverride && isBuiltIn ? "Are you sure you want to delete your modifications to this plugin? It will be restored to the built-in default state.".localized : "Are you sure you want to completely delete this plugin? This action is irreversible.".localized)
        alert.addButton(withTitle: isBuiltIn && hasUserOverride ? "Restore Default".localized : "Confirm Delete".localized)
        alert.addButton(withTitle: "Cancel".localized)
        
        let response = self.window != nil ? alert.runModal() : alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try PluginManager.shared.deletePlugin(plugin)
            } catch {
                let errAlert = NSAlert()
                errAlert.messageText = "Delete Failed".localized
                errAlert.informativeText = error.localizedDescription
                errAlert.runModal()
            }
        }
    }
    
    // MARK: - Drag & Drop
    
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: dragType)
        return item
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Ensure we always use .above (insert between rows, not onto a row)
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        // Auto-scroll one row at a time when dragging near the edges (throttled)
        // Uses direct NSClipView manipulation instead of scrollRowToVisible to avoid
        // triggering NSTableView layout updates that could cause the menu to close.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAutoScrollTime > 0.8, let clipView = tableView.enclosingScrollView?.contentView {
            let mouseY = tableView.convert(info.draggingLocation, from: nil).y
            let edgeZone: CGFloat = rowHeight
            let currentOrigin = clipView.bounds.origin
            let maxY = max(0, tableView.frame.height - clipView.bounds.height)
            
            if mouseY < tableView.visibleRect.minY + edgeZone, currentOrigin.y > 0 {
                // Scroll up by one row
                let newY = max(0, currentOrigin.y - rowHeight)
                clipView.setBoundsOrigin(NSPoint(x: 0, y: newY))
                lastAutoScrollTime = now
            } else if mouseY > tableView.visibleRect.maxY - edgeZone, currentOrigin.y < maxY {
                // Scroll down by one row
                let newY = min(maxY, currentOrigin.y + rowHeight)
                clipView.setBoundsOrigin(NSPoint(x: 0, y: newY))
                lastAutoScrollTime = now
            }
        }
        return .move
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: dragType),
              let sourceRow = Int(rowStr),
              let reorderResult = Self.reorderedPlugins(orderedPlugins, sourceRow: sourceRow, proposedRow: row) else {
            return false
        }
        
        orderedPlugins = reorderResult.plugins
        
        // Suppress notification-triggered reload during reorder
        isReordering = true
        
        tableView.moveRow(at: sourceRow, to: reorderResult.targetRow)
        
        // Remember which row was at the top of the visible area
        let firstVisibleRow = tableView.rows(in: tableView.visibleRect).location
        
        // Full reloadData to rebuild position numbers and keep scrollbar intact
        tableView.reloadData()
        
        saveOrder()
        isReordering = false
        
        // Restore scroll position ASYNCHRONOUSLY — reloadData triggers a
        // deferred layout pass that overrides any synchronous scroll restoration.
        // By dispatching to the next run loop iteration, we run AFTER that layout.
        DispatchQueue.main.async {
            if firstVisibleRow < self.orderedPlugins.count {
                tableView.scrollRowToVisible(firstVisibleRow)
            }
        }
        
        return true
    }
}
