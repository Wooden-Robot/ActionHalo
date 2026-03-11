import Cocoa

/// Custom NSView embedded inside a menu item to provide an interactive plugin list
/// with click-to-toggle and drag-to-reorder functionality
final class PluginListMenuView: NSView, NSTableViewDelegate, NSTableViewDataSource {
    
    private let tableView = NSTableView()
    private var orderedPlugins: [Plugin] = []
    private let dragType = NSPasteboard.PasteboardType("com.openfire.plugin-row")
    private let rowHeight: CGFloat = 28
    private let viewWidth: CGFloat = 220
    private let buttonHeight: CGFloat = 36
    
    private var editorWindow: PluginEditorWindow?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        let scrollView = NSScrollView()
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("plugin"))
        col.width = viewWidth - 20
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = rowHeight
        tableView.registerForDraggedTypes([dragType])
        tableView.draggingDestinationFeedbackStyle = .gap
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
    
    /// Reload with current plugins
    func reloadPlugins() {
        orderedPlugins = getOrderedPlugins()
        
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
    
    private func getOrderedPlugins() -> [Plugin] {
        let savedOrder = UserDefaults.standard.stringArray(forKey: "pluginOrder") ?? []
        let allPlugins = PluginManager.shared.plugins
        
        if savedOrder.isEmpty {
            return allPlugins.sorted { $0.order < $1.order }
        }
        var ordered: [Plugin] = []
        for id in savedOrder {
            if let p = allPlugins.first(where: { $0.id == id }) { ordered.append(p) }
        }
        for p in allPlugins where !ordered.contains(where: { $0.id == p.id }) { ordered.append(p) }
        return ordered
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
        
        let editor = PluginEditorWindow(plugin: plugin)
        editor.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindow = editor
    }
    
    // MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        orderedPlugins.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let plugin = orderedPlugins[row]
        
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: rowHeight))
        
        // Position number
        let numLabel = NSTextField(labelWithString: "\(row + 1)")
        numLabel.frame = NSRect(x: 4, y: 5, width: 16, height: 18)
        numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        numLabel.textColor = .tertiaryLabelColor
        numLabel.alignment = .right
        cell.addSubview(numLabel)
        
        // Enabled indicator
        let indicator = NSTextField(labelWithString: plugin.isEnabled ? "●" : "○")
        indicator.frame = NSRect(x: 24, y: 5, width: 14, height: 18)
        indicator.font = NSFont.systemFont(ofSize: 10)
        indicator.textColor = plugin.isEnabled ? NSColor.systemBlue : .tertiaryLabelColor
        cell.addSubview(indicator)
        
        // Icon
        let iconView = NSImageView(frame: NSRect(x: 42, y: 3, width: 22, height: 22))
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
        let showDeleteButton = !PluginManager.coreDefaultPluginIDs.contains(plugin.id)
        
        // Name
        let nameField = NSTextField(labelWithString: plugin.name)
        // Shorter width to make room for buttons if delete button is shown
        let nameWidth = showDeleteButton ? viewWidth - 140 : viewWidth - 110
        nameField.frame = NSRect(x: 68, y: 5, width: nameWidth, height: 18)
        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.textColor = plugin.isEnabled ? .labelColor : .tertiaryLabelColor
        cell.addSubview(nameField)
        
        if showDeleteButton {
            // Delete Button (Trash)
            let deleteBtn = NSButton(frame: NSRect(x: viewWidth - 68, y: 2, width: 24, height: 24))
            deleteBtn.bezelStyle = .inline
            deleteBtn.isBordered = false
            deleteBtn.title = ""
            if let delImg = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete") {
                deleteBtn.image = delImg.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            }
            deleteBtn.contentTintColor = .systemRed.withAlphaComponent(0.8)
            deleteBtn.target = self
            deleteBtn.action = #selector(deletePluginClicked(_:))
            cell.addSubview(deleteBtn)
        }
        
        // Edit Button (Pencil)
        let editBtn = NSButton(frame: NSRect(x: viewWidth - 44, y: 2, width: 24, height: 24))
        editBtn.bezelStyle = .inline
        editBtn.isBordered = false
        editBtn.title = ""
        if let editImg = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit") {
            editBtn.image = editImg.withSymbolConfiguration(.init(pointSize: 15, weight: .bold)) // Thickened pencil
        }
        editBtn.target = self
        editBtn.action = #selector(editPluginClicked(_:))
        cell.addSubview(editBtn)
        
        // Drag handle hint
        let handle = NSTextField(labelWithString: "⋮⋮")
        handle.frame = NSRect(x: viewWidth - 20, y: 5, width: 16, height: 18)
        handle.font = NSFont.systemFont(ofSize: 10)
        handle.textColor = .quaternaryLabelColor
        cell.addSubview(handle)
        
        return cell
    }
    
    @objc private func deletePluginClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0 && row < orderedPlugins.count else { return }
        let plugin = orderedPlugins[row]
        
        let pathStr = plugin.directoryURL.path
        let isBuiltIn = pathStr.hasPrefix(Bundle.main.bundlePath) || pathStr.contains("/Resources/Plugins/")
        
        let userPluginsURL = PluginManager.shared.userPluginsURL
        let userOverrideURL = userPluginsURL.appendingPathComponent("\(plugin.id).openfireext")
        let hasUserOverride = FileManager.default.fileExists(atPath: userOverrideURL.path)
        
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
                NotificationCenter.default.post(name: PluginManager.pluginsReloadedNotification, object: nil)
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
        let mouseLocation = tableView.convert(info.draggingLocation, from: nil)
        
        // Calculate dynamic row based on actual mouse Y position allowing for easier top/bottom drops
        var dynamicRow = Int(mouseLocation.y / rowHeight)
        
        // Make the top and bottom targets massive
        if mouseLocation.y < rowHeight / 2 {
            dynamicRow = 0
        } else if mouseLocation.y > CGFloat(orderedPlugins.count) * rowHeight - (rowHeight / 2) {
            dynamicRow = orderedPlugins.count
        }
        
        // Clamp it
        dynamicRow = max(0, min(dynamicRow, orderedPlugins.count))
        
        if dropOperation != .above || row != dynamicRow {
            tableView.setDropRow(dynamicRow, dropOperation: .above)
        }
        
        return .move
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: dragType),
              let sourceRow = Int(rowStr) else { return false }
        
        let plugin = orderedPlugins.remove(at: sourceRow)
        let targetRow = sourceRow < row ? row - 1 : row
        orderedPlugins.insert(plugin, at: targetRow)
        
        tableView.moveRow(at: sourceRow, to: targetRow)
        
        // Save scroll position before reload to prevent jump-to-top
        let savedScrollPosition = tableView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        
        // Update position numbers
        tableView.reloadData()
        
        // Restore scroll position
        tableView.enclosingScrollView?.contentView.scroll(to: savedScrollPosition)
        tableView.enclosingScrollView?.reflectScrolledClipView(tableView.enclosingScrollView!.contentView)
        
        saveOrder()
        return true
    }
}
