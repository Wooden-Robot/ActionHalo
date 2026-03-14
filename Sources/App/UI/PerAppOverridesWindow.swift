import Cocoa

final class PerAppOverridesWindow: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {
    private struct Row {
        let pluginID: String
        let pluginName: String
        let appBundleID: String
        let appName: String
    }

    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private var rows: [Row] = []
    private var filteredRows: [Row] = []
    private let rowHeight: CGFloat = 44
    private static var appNameCache: [String: String] = [:]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Per-App Overrides".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePluginsReloaded),
            name: PluginManager.pluginsReloadedNotification,
            object: nil
        )
        loadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Review plugins disabled only in specific apps, then restore them from one place.".localized)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 320, width: 470, height: 32)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        contentView.addSubview(label)

        searchField.frame = NSRect(x: 20, y: 286, width: 480, height: 28)
        searchField.placeholderString = "Filter by plugin or app".localized
        searchField.delegate = self
        contentView.addSubview(searchField)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 480, height: 256))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("override"))
        column.width = 478
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.style = .plain

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func loadData() {
        let pluginNames = Dictionary(uniqueKeysWithValues: PluginManager.shared.plugins.map { ($0.id, $0.name) })
        rows = PluginManager.shared.allPerAppDisabledPluginOverrides().map { override in
            Row(
                pluginID: override.pluginID,
                pluginName: pluginNames[override.pluginID] ?? override.pluginID,
                appBundleID: override.appBundleID,
                appName: Self.displayName(forAppBundleID: override.appBundleID)
            )
        }
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredRows = rows
            tableView.reloadData()
            return
        }

        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        filteredRows = rows.filter { row in
            [
                row.pluginName,
                row.pluginID,
                row.appName,
                row.appBundleID
            ].contains { field in
                field.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(foldedQuery)
            }
        }
        tableView.reloadData()
    }

    private static func displayName(forAppBundleID bundleID: String) -> String {
        if let cached = appNameCache[bundleID] {
            return cached
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let resolvedName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            appNameCache[bundleID] = resolvedName
            return resolvedName
        }

        appNameCache[bundleID] = bundleID
        return bundleID
    }

    override func showWindow(_ sender: Any?) {
        loadData()
        super.showWindow(sender)
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        loadData()
    }

    @objc private func handlePluginsReloaded() {
        refreshIfVisible()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRows.isEmpty ? 1 : filteredRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if filteredRows.isEmpty {
            let emptyView = NSView(frame: NSRect(x: 0, y: 0, width: 478, height: rowHeight))
            let emptyState = rows.isEmpty ? "No per-app plugin overrides.".localized : "No matches for the current filter.".localized
            let label = NSTextField(labelWithString: emptyState)
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 12, width: 478, height: 18)
            emptyView.addSubview(label)
            return emptyView
        }

        let item = filteredRows[row]
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 478, height: rowHeight))

        let pluginLabel = NSTextField(labelWithString: item.pluginName)
        pluginLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pluginLabel.frame = NSRect(x: 14, y: 22, width: 220, height: 16)
        cell.addSubview(pluginLabel)

        let pluginIDLabel = NSTextField(labelWithString: item.pluginID)
        pluginIDLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pluginIDLabel.textColor = .tertiaryLabelColor
        pluginIDLabel.frame = NSRect(x: 14, y: 6, width: 220, height: 14)
        cell.addSubview(pluginIDLabel)

        let appLabel = NSTextField(labelWithString: item.appName)
        appLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        appLabel.alignment = .right
        appLabel.frame = NSRect(x: 240, y: 22, width: 140, height: 16)
        cell.addSubview(appLabel)

        let bundleLabel = NSTextField(labelWithString: item.appBundleID)
        bundleLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        bundleLabel.textColor = .tertiaryLabelColor
        bundleLabel.alignment = .right
        bundleLabel.frame = NSRect(x: 240, y: 6, width: 140, height: 14)
        cell.addSubview(bundleLabel)

        let restoreButton = NSButton(frame: NSRect(x: 396, y: 10, width: 70, height: 24))
        restoreButton.bezelStyle = .rounded
        restoreButton.title = "Restore".localized
        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked(_:))
        restoreButton.tag = row
        cell.addSubview(restoreButton)

        return cell
    }

    @objc private func restoreClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < filteredRows.count else { return }

        let item = filteredRows[row]
        PluginManager.shared.clearPerAppOverride(pluginID: item.pluginID, forAppBundleID: item.appBundleID)
        loadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}
